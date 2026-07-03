import 'dart:convert';
import 'dart:io';

import 'package:app/local/agent_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

// resolveTranscriptPath reads ~/.claude/projects and ~/.codex/sessions under
// $HOME, so these tests build a fake tree there and MUST run under a
// throwaway HOME so they never write into a real profile:
//   HOME=$(mktemp -d) flutter test test/transcript_resolve_test.dart
// They self-skip otherwise.
void main() {
  final home = Platform.environment['HOME'] ?? '';
  final isolated = home.startsWith('/tmp') ||
      home.startsWith('/private/') ||
      home.startsWith('/var/folders/');

  Directory projectDir(String workdir) {
    final enc = workdir.replaceAll(RegExp(r'[/.]'), '-');
    return Directory('$home/.claude/projects/$enc')..createSync(recursive: true);
  }

  test('minted id whose log exists resolves to that exact log', () async {
    if (!isolated) return;
    const wd = '/w/proj-a';
    final dir = projectDir(wd);
    const id = 'aaaaaaaa-1111-2222-3333-444444444444';
    final f = File('${dir.path}/$id.jsonl')..writeAsStringSync('{}\n');
    final p = await resolveTranscriptPath(
        agentKind: 'claude', agentSessionId: id, workdir: wd);
    expect(p, f.path);
  });

  // The 串味 fix: a dormant session knows its exact id but hasn't written its log
  // yet. It must NOT fall back to a sibling session's log in the same project dir.
  test('minted id with no log yet returns null, not a sibling log (串味)', () async {
    if (!isolated) return;
    const wd = '/w/proj-b';
    final dir = projectDir(wd);
    // A different (running) session's log sits in the same cwd-encoded dir.
    File('${dir.path}/sibling-9999-0000-0000-000000000000.jsonl')
        .writeAsStringSync('{}\n');
    final p = await resolveTranscriptPath(
        agentKind: 'claude',
        agentSessionId: 'dormant-0000-0000-0000-000000000000',
        workdir: wd);
    expect(p, isNull,
        reason: 'a dormant session must not read a sibling transcript');
  });

  // Legacy --continue / pre-upgrade restore carries no minted id: the newest log
  // in the cwd is the only guess, so the fallback must still apply there.
  test('no minted id falls back to the cwd newest log (legacy --continue)',
      () async {
    if (!isolated) return;
    const wd = '/w/proj-c';
    final dir = projectDir(wd);
    final f = File('${dir.path}/legacy-1234-5678-9abc-def012345678.jsonl')
      ..writeAsStringSync('{}\n');
    final p = await resolveTranscriptPath(
        agentKind: 'claude', agentSessionId: null, workdir: wd);
    expect(p, f.path);
  });

  // --- codex ---------------------------------------------------------------
  // Unlike claude, codex has no filename-encoded id: the id only lives inside
  // the rollout's first JSONL line, so resolving by id means reading payloads
  // rather than matching a filename.

  Directory codexBucketDir() {
    final d = Directory('$home/.codex/sessions/2026/01/01')
      ..createSync(recursive: true);
    return d;
  }

  File writeRollout(Directory dir, String name, {String? cwd, String? id}) {
    final f = File('${dir.path}/rollout-$name.jsonl');
    final payload = <String, String>{
      if (cwd != null) 'cwd': cwd,
      if (id != null) 'id': id,
    };
    f.writeAsStringSync('${jsonEncode({'payload': payload})}\n');
    return f;
  }

  test('codex: known id resolves to the exact rollout carrying that id',
      () async {
    if (!isolated) return;
    const wd = '/w/codex-a';
    final dir = codexBucketDir();
    const id = 'cccccccc-1111-2222-3333-444444444444';
    final f = writeRollout(dir, 'a', cwd: wd, id: id);
    final p = await resolveTranscriptPath(
        agentKind: 'codex', agentSessionId: id, workdir: wd);
    expect(p, f.path);
  });

  // The 串味 fix: a sibling codex session shares the same cwd-matched
  // directory tree. A known id must NOT fall back to "newest cwd match" —
  // it must resolve to that exact file or nothing.
  test('codex: known id with no matching rollout returns null, not a sibling '
      'rollout (串味)', () async {
    if (!isolated) return;
    const wd = '/w/codex-b';
    final dir = codexBucketDir();
    // A different (sibling) session's rollout, same cwd, different id.
    writeRollout(dir, 'sibling',
        cwd: wd, id: 'sibling-9999-0000-0000-000000000000');
    final p = await resolveTranscriptPath(
        agentKind: 'codex',
        agentSessionId: 'dormant-0000-0000-0000-000000000000',
        workdir: wd);
    expect(p, isNull,
        reason: 'a dormant session must not read a sibling rollout');
  });

  // No captured id (capture hasn't landed yet): the newest cwd-matching
  // rollout is the only available guess, so the fallback must still apply.
  test('codex: no captured id falls back to the cwd newest rollout',
      () async {
    if (!isolated) return;
    const wd = '/w/codex-c';
    final dir = codexBucketDir();
    final f = writeRollout(dir, 'legacy',
        cwd: wd, id: 'legacy-1234-5678-9abc-def012345678');
    final p = await resolveTranscriptPath(
        agentKind: 'codex', agentSessionId: null, workdir: wd);
    expect(p, f.path);
  });
}
