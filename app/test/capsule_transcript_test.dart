import 'dart:convert';
import 'dart:io';

import 'package:app/local/agent_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

// renderTranscriptFull takes an explicit path, so most of these run without a
// throwaway HOME. captureCapsuleTranscript resolves under $HOME, so that group
// self-skips unless HOME is isolated (see transcript_resolve_test.dart):
//   HOME=$(mktemp -d) flutter test test/capsule_transcript_test.dart
void main() {
  String jline(Object o) => '${jsonEncode(o)}\n';

  test('claude full render: labels both sides, keeps tool markers, drops '
      'thinking + tool_result noise', () async {
    final dir = Directory.systemTemp.createTempSync('cap_cl_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/log.jsonl');
    f.writeAsStringSync(
      jline({
        'type': 'user',
        'message': {'role': 'user', 'content': '请帮我修复登录 bug'},
      }) +
          jline({
            'type': 'assistant',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'thinking', 'thinking': 'SECRET-REASONING'},
                {'type': 'text', 'text': '好的,我来看看'},
                {'type': 'tool_use', 'name': 'Read', 'input': {}},
              ],
            },
          }) +
          // A tool_result echo comes back as a user-role message; it must NOT
          // render as a user turn.
          jline({
            'type': 'user',
            'message': {
              'content': [
                {'type': 'tool_result', 'content': 'RAW-FILE-BYTES'},
              ],
            },
          }),
    );

    final out = await renderTranscriptFull(f.path, agentKind: 'claude');
    expect(out, contains('## 用户'));
    expect(out, contains('请帮我修复登录 bug'));
    expect(out, contains('## 助手'));
    expect(out, contains('好的,我来看看'));
    expect(out, contains('[tool: Read]'));
    expect(out, isNot(contains('SECRET-REASONING')),
        reason: 'thinking blocks must not leak into the neutral seed');
    expect(out, isNot(contains('RAW-FILE-BYTES')),
        reason: 'tool_result echoes must not render as user turns');
  });

  test('codex full render: agent_message + user_message + response_item message',
      () async {
    final dir = Directory.systemTemp.createTempSync('cap_cx_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/rollout-x.jsonl');
    f.writeAsStringSync(
      // session_meta header line — not a turn, must be skipped.
      jline({
        'type': 'session_meta',
        'payload': {'id': 'x', 'cwd': '/w'},
      }) +
          jline({
            'type': 'event_msg',
            'payload': {'type': 'user_message', 'message': '继续下一个'},
          }) +
          jline({
            'type': 'event_msg',
            'payload': {'type': 'agent_message', 'message': '我修好了'},
          }) +
          jline({
            'type': 'response_item',
            'payload': {
              'type': 'message',
              'role': 'user',
              'content': [
                {'type': 'input_text', 'text': '第三条消息'},
              ],
            },
          }),
    );

    final out = await renderTranscriptFull(f.path, agentKind: 'codex');
    expect(out, contains('## 用户'));
    expect(out, contains('继续下一个'));
    expect(out, contains('## 助手'));
    expect(out, contains('我修好了'));
    expect(out, contains('第三条消息'));
    expect(out, isNot(contains('session_meta')));
  });

  test('renderTranscriptFull maxChars keeps the most recent turns', () async {
    final dir = Directory.systemTemp.createTempSync('cap_cap_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/log.jsonl');
    f.writeAsStringSync(
      jline({
        'type': 'assistant',
        'message': {
          'content': [
            {'type': 'text', 'text': 'OLD-TURN'},
          ],
        },
      }) +
          jline({
            'type': 'assistant',
            'message': {
              'content': [
                {'type': 'text', 'text': 'NEW-TURN'},
              ],
            },
          }),
    );
    final out = await renderTranscriptFull(f.path, agentKind: 'claude', maxChars: 20);
    expect(out, contains('NEW-TURN'));
    expect(out, isNot(contains('OLD-TURN')));
    expect(out, startsWith('…(前文略)…'));
  });

  // --- capture (needs an isolated HOME) ------------------------------------
  final home = Platform.environment['HOME'] ?? '';
  final isolated = home.startsWith('/tmp') ||
      home.startsWith('/private/') ||
      home.startsWith('/var/folders/');

  test('captureCapsuleTranscript copies the raw log + writes the neutral text',
      () async {
    if (!isolated) return;
    const wd = '/w/cap-proj';
    final enc = wd.replaceAll(RegExp(r'[/.]'), '-');
    final projDir = Directory('$home/.claude/projects/$enc')
      ..createSync(recursive: true);
    const id = 'capsule0-1111-2222-3333-444444444444';
    final srcLog = File('${projDir.path}/$id.jsonl');
    final srcBytes = jline({
      'type': 'user',
      'message': {'content': '打个胶囊'},
    }) +
        jline({
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'text', 'text': '收到'},
            ],
          },
        });
    srcLog.writeAsStringSync(srcBytes);

    final dest = Directory.systemTemp.createTempSync('cap_dest_');
    addTearDown(() => dest.deleteSync(recursive: true));

    final res = await captureCapsuleTranscript(
      agentKind: 'claude',
      agentSessionId: id,
      workdir: wd,
      destDir: dest.path,
    );
    expect(res, isNotNull);
    // Raw log copied byte-for-byte (same-tool native --resume relies on it).
    final copied = File('${dest.path}/transcript.jsonl');
    expect(copied.existsSync(), isTrue);
    expect(copied.readAsStringSync(), srcBytes);
    // Neutral render present and readable.
    final txt = File('${dest.path}/transcript.txt');
    expect(txt.existsSync(), isTrue);
    final body = txt.readAsStringSync();
    expect(body, contains('打个胶囊'));
    expect(body, contains('收到'));
  });

  test('captureCapsuleTranscript returns null when the log is not on disk yet',
      () async {
    if (!isolated) return;
    final dest = Directory.systemTemp.createTempSync('cap_null_');
    addTearDown(() => dest.deleteSync(recursive: true));
    final res = await captureCapsuleTranscript(
      agentKind: 'claude',
      agentSessionId: 'dormant0-0000-0000-0000-000000000000',
      workdir: '/w/nonexistent-proj',
      destDir: dest.path,
    );
    expect(res, isNull,
        reason: 'a dormant/unflushed session yields no transcript to capture');
  });

  // --- importCapsuleTranscriptForResume (native --resume, isolated HOME) ----

  test('import: claude writes to the cwd project dir under the origin id',
      () async {
    if (!isolated) return;
    const wd = '/w/resume-proj';
    const id = 'origin00-1111-2222-3333-444444444444';
    final resumeId = await importCapsuleTranscriptForResume(
      agentKind: 'claude',
      bytes: utf8.encode('{"type":"user"}\n'),
      workdir: wd,
      originId: id,
      now: DateTime(2026, 7, 6),
    );
    expect(resumeId, id);
    final enc = wd.replaceAll(RegExp(r'[/.]'), '-');
    final f = File('$home/.claude/projects/$enc/$id.jsonl');
    expect(f.existsSync(), isTrue);
    expect(f.readAsStringSync(), '{"type":"user"}\n');
  });

  test('import: claude with no origin id returns null (→ seed fallback)',
      () async {
    if (!isolated) return;
    final r = await importCapsuleTranscriptForResume(
      agentKind: 'claude',
      bytes: const [1, 2],
      workdir: '/w/x',
      originId: '',
      now: DateTime(2026, 7, 6),
    );
    expect(r, isNull);
  });

  test('import: codex reads the id from session_meta + writes a dated bucket',
      () async {
    if (!isolated) return;
    final rollout = jline({
          'type': 'session_meta',
          'payload': {'id': 'codex-abc', 'cwd': '/w'},
        }) +
        jline({
          'type': 'event_msg',
          'payload': {'type': 'agent_message', 'message': 'hi'},
        });
    final resumeId = await importCapsuleTranscriptForResume(
      agentKind: 'codex',
      bytes: utf8.encode(rollout),
      workdir: '/w/whatever',
      originId: '', // codex ignores the caller id; it reads session_meta
      now: DateTime(2026, 7, 6),
    );
    expect(resumeId, 'codex-abc');
    expect(
      File('$home/.codex/sessions/2026/07/06/rollout-imported-codex-abc.jsonl')
          .existsSync(),
      isTrue,
    );
  });

  test('import: codex with no session_meta id returns null', () async {
    if (!isolated) return;
    final r = await importCapsuleTranscriptForResume(
      agentKind: 'codex',
      bytes: utf8.encode('not json\n'),
      workdir: '/w',
      originId: '',
      now: DateTime(2026, 7, 6),
    );
    expect(r, isNull);
  });
}
