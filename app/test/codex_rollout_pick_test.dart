import 'dart:convert';
import 'dart:io';

import 'package:app/local/agent_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

// pickUniqueRolloutId is the pure "choose one candidate, else stay unknown"
// selection at the heart of the codex id-capture fix: TerminalSession's
// _scanCodexRolloutId (screens/terminal_pane.dart) hands it every rollout
// written since this session launched, and it must refuse to guess when more
// than one sibling session's rollout matches this cwd — picking "the newest"
// there is exactly what caused 串味 (one session capturing and persisting
// ANOTHER session's id). No HOME isolation needed: unlike resolveTranscriptPath,
// this operates on an explicit file list rather than scanning $HOME.
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
    final payload = <String, String>{
      if (cwd != null) 'cwd': cwd,
      if (id != null) 'id': id,
    };
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
  test('two cwd matches in the same window return null, not a guess',
      () async {
    const wd = '/w/proj';
    final a = rollout('a', cwd: wd, id: 'id-a');
    final b = rollout('b', cwd: wd, id: 'id-b');
    final id = await pickUniqueRolloutId([a, b], wd);
    expect(id, isNull,
        reason: 'ambiguous candidates must not resolve to either one');
  });

  test('an unparsable candidate is skipped, not fatal', () async {
    const wd = '/w/proj';
    final bad = File('${tmp.path}/rollout-bad.jsonl')
      ..writeAsStringSync('not json\n');
    final good = rollout('good', cwd: wd, id: 'id-good');
    final id = await pickUniqueRolloutId([bad, good], wd);
    expect(id, 'id-good');
  });
}
