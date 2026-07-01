import 'dart:io';

import 'package:app/local/agent_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

// resolveTranscriptPath reads ~/.claude/projects under $HOME, so these tests
// build a fake tree there and MUST run under a throwaway HOME so they never write
// into a real profile:  HOME=$(mktemp -d) flutter test test/transcript_resolve_test.dart
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
}
