import 'dart:convert';
import 'dart:io';

import 'package:app/local/agent_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

// Tests for the two pure "choose one candidate, else stay unknown" selection
// functions behind the codex 串味 fix in agent_transcript.dart:
//   - pickUniqueRolloutId: TerminalSession's _scanCodexRolloutId
//     (screens/terminal_pane.dart) hands it every rollout written since THIS
//     session launched, and it must refuse to guess when more than one
//     sibling session's rollout matches this cwd.
//   - pickNewestCodexRollout: resolveTranscriptPath's id-less fallback
//     (_newestCodexRollout) has no such launch-time floor, so it substitutes
//     mtime recency for the same ambiguity check (see its doc comment).
// Picking "the newest" under ambiguity is exactly what caused 串味 (one
// session capturing/reading ANOTHER session's transcript). No HOME isolation
// needed for either: unlike resolveTranscriptPath, both operate on an
// explicit file list rather than scanning $HOME.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rollout-pick-test-');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  File rollout(String name, {String? cwd, String? id}) {
    final f = File('${tmp.path}/rollout-$name.jsonl');
    final payload = <String, String>{'cwd': ?cwd, 'id': ?id};
    f.writeAsStringSync('${jsonEncode({'payload': payload})}\n');
    return f;
  }

  test('exactly one cwd match returns its id', () async {
    const wd = '/w/proj';
    final f = rollout('a', cwd: wd, id: 'id-a');
    final id = await pickUniqueRolloutId([f], wd);
    expect(id, 'id-a');
  });

  test('no cwd match returns null', () async {
    const wd = '/w/proj';
    final f = rollout('a', cwd: '/w/other', id: 'id-a');
    final id = await pickUniqueRolloutId([f], wd);
    expect(id, isNull);
  });

  // The 串味 fix: two sibling sessions launched around the same time both
  // wrote a rollout for this cwd. Neither mtime nor arbitrary ordering can
  // tell them apart, so the ambiguity must surface as "still unknown", not a
  // guess.
  test('two cwd matches in the same window return null, not a guess', () async {
    const wd = '/w/proj';
    final a = rollout('a', cwd: wd, id: 'id-a');
    final b = rollout('b', cwd: wd, id: 'id-b');
    final id = await pickUniqueRolloutId([a, b], wd);
    expect(
      id,
      isNull,
      reason: 'ambiguous candidates must not resolve to either one',
    );
  });

  test('an unparsable candidate is skipped, not fatal', () async {
    const wd = '/w/proj';
    final bad = File('${tmp.path}/rollout-bad.jsonl')
      ..writeAsStringSync('not json\n');
    final good = rollout('good', cwd: wd, id: 'id-good');
    final id = await pickUniqueRolloutId([bad, good], wd);
    expect(id, 'id-good');
  });

  // pickNewestCodexRollout is the analogous "choose one, else stay unknown"
  // rule for resolveTranscriptPath's id-less fallback (_newestCodexRollout).
  // That call site has no session-launch floor to bound candidates by (there's
  // no session to ask "when did you start" — that's the whole reason we're
  // guessing), so it substitutes mtime recency for the same purpose: only
  // rollouts modified within the last few minutes count as "could be an
  // active concurrent sibling"; older ones are settled history that's safe to
  // fall back to.
  group('pickNewestCodexRollout', () {
    final now = DateTime(2026, 1, 1, 12, 0, 0);

    test(
      'exactly one recent cwd match returns it, ignoring older history',
      () async {
        const wd = '/w/proj';
        final recentFile = rollout('recent', cwd: wd, id: 'id-recent');
        final oldFile = rollout('old', cwd: wd, id: 'id-old');
        final dated = [
          (now.subtract(const Duration(minutes: 1)), recentFile),
          (now.subtract(const Duration(hours: 2)), oldFile),
        ];
        final p = await pickNewestCodexRollout(dated, wd, now: now);
        expect(p, recentFile.path);
      },
    );

    // The 串味 fix, applied to the id-less fallback: two sibling sessions
    // both wrote a rollout for this cwd within the last few minutes. Neither
    // mtime nor arbitrary ordering can tell them apart — picking "the newer
    // of the two" is exactly the guess that caused 串味 last time.
    test('two recent cwd matches return null, not a guess', () async {
      const wd = '/w/proj';
      final a = rollout('a', cwd: wd, id: 'id-a');
      final b = rollout('b', cwd: wd, id: 'id-b');
      final dated = [
        (now.subtract(const Duration(minutes: 1)), a),
        (now.subtract(const Duration(minutes: 2)), b),
      ];
      final p = await pickNewestCodexRollout(dated, wd, now: now);
      expect(
        p,
        isNull,
        reason:
            'concurrent sibling candidates must not resolve to '
            'either one',
      );
    });

    test('no recent match falls back to the newest historical entry', () async {
      const wd = '/w/proj';
      final older = rollout('older', cwd: wd, id: 'id-older');
      final newerHistorical = rollout(
        'newer-historical',
        cwd: wd,
        id: 'id-newer-historical',
      );
      final dated = [
        (now.subtract(const Duration(hours: 3)), older),
        (now.subtract(const Duration(hours: 1)), newerHistorical),
      ];
      final p = await pickNewestCodexRollout(dated, wd, now: now);
      expect(
        p,
        newerHistorical.path,
        reason:
            'no concurrent activity right now -> the legacy '
            '--continue-restore fallback still applies',
      );
    });

    // Mixed case: a genuinely live session (recent) plus a pile of unrelated
    // historical rollouts for the same cwd from earlier sessions. The recent
    // tier alone must decide — history must not dilute or override it.
    test('one recent match plus several historical entries: the recent one '
        'wins', () async {
      const wd = '/w/proj';
      final recentFile = rollout('recent', cwd: wd, id: 'id-recent');
      final h1 = rollout('h1', cwd: wd, id: 'id-h1');
      final h2 = rollout('h2', cwd: wd, id: 'id-h2');
      final dated = [
        (now.subtract(const Duration(seconds: 30)), recentFile),
        (now.subtract(const Duration(hours: 1)), h1),
        (now.subtract(const Duration(hours: 2)), h2),
      ];
      final p = await pickNewestCodexRollout(dated, wd, now: now);
      expect(p, recentFile.path);
    });

    test('non-cwd-matching candidates are ignored in both tiers', () async {
      const wd = '/w/proj';
      final other = rollout('other', cwd: '/w/other', id: 'id-other');
      final dated = [(now.subtract(const Duration(minutes: 1)), other)];
      final p = await pickNewestCodexRollout(dated, wd, now: now);
      expect(p, isNull);
    });
  });
}
