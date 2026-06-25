import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';

import '../screens/terminal_pane.dart';
import 'stt.dart';

// VoiceService is the desktop two-way voice bridge for the AI terminals:
//   • TTS — read an agent's just-finished reply aloud. The text comes from the
//     agent's own session log (clean prose), NOT the TUI screen (escape codes).
//   • STT — speech → text (via the shared web-safe [SpeechInput]), injected into
//     the active terminal's input.
//
// TTS is desktop-only (it tails ~/.claude or ~/.codex logs via dart:io); the
// phone reuses [SpeechInput] directly for voice input. The workspace owns one
// instance and gates TTS on its own toggle. Locating the agent log reuses the
// session id we mint for claude (TerminalSession.agentSessionId) — see the
// session-restore feature — so we read exactly the right .jsonl.
class VoiceService {
  final FlutterTts _tts = FlutterTts();
  final SpeechInput _input = SpeechInput();

  // Per-session reading cursor into the agent log: the resolved log path and the
  // byte offset already spoken, keyed by TerminalSession.id. (path also doubles
  // as the resolve cache — see _resolveLogPath.)
  final Map<String, ({String path, int offset})> _cursor = {};

  // Trailing code/whitespace matchers for _clean; compiled once.
  static final RegExp _fenced = RegExp(r'```[\s\S]*?```');
  static final RegExp _ws = RegExp(r'\s+');
  static const int _speakCap = 800; // don't narrate essays; cap per turn

  // Mirrors SpeechInput.onListeningChange so callers keep using the service.
  set onListeningChange(void Function(bool listening)? f) =>
      _input.onListeningChange = f;

  Future<void> init() async {
    await _tts.setLanguage('zh-CN');
    await _tts.awaitSpeakCompletion(true);
    await _input.init();
  }

  // --- TTS: read the agent's reply -----------------------------------------

  // armBaseline marks "start reading from here" for [s]: future turns are read,
  // existing history is not. Call when TTS is enabled or the active tab changes.
  Future<void> armBaseline(TerminalSession s) async {
    final path = await _resolveLogPath(s);
    _cursor[s.id] = (
      path: path ?? '',
      offset: path == null ? 0 : await _lengthOf(path),
    );
  }

  // speakReplyFor reads the new assistant prose written to [s]'s log since the
  // last read and speaks it (interrupting any current utterance). No-op when the
  // log can't be located (e.g. a claude session with no minted id) or there's no
  // new text.
  Future<void> speakReplyFor(TerminalSession s) async {
    final path = await _resolveLogPath(s);
    if (path == null) return;
    final cur = _cursor[s.id];
    // start=0 on first resolve, or when codex rolled a new file under us.
    var start = cur?.path == path ? cur!.offset : 0;
    final len = await _lengthOf(path);
    if (len <= start) {
      _cursor[s.id] = (path: path, offset: len);
      return;
    }
    final raf = await File(path).open();
    String chunk;
    try {
      await raf.setPosition(start);
      chunk = utf8.decode(await raf.read(len - start), allowMalformed: true);
    } finally {
      await raf.close();
    }
    // Only consume up to the last complete line; a partial trailing line (log
    // still being written) is left for next time.
    final nl = chunk.lastIndexOf('\n');
    if (nl < 0) {
      _cursor[s.id] = (path: path, offset: start); // no full line yet; retry
      return;
    }
    final consumed = chunk.substring(0, nl + 1);
    _cursor[s.id] = (path: path, offset: start + utf8.encode(consumed).length);
    final text = _extract(s.agentKind, consumed);
    if (text == null || text.isEmpty) return;
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> stopSpeaking() => _tts.stop();

  // _extract pulls the assistant's spoken prose out of a span of agent-log lines:
  // claude → message.content[] text blocks (skip thinking/tool_use); codex →
  // event_msg/agent_message payloads. Code blocks are stripped (we don't narrate
  // code) and the result is capped.
  String? _extract(String agent, String lines) {
    final out = StringBuffer();
    for (final line in const LineSplitter().convert(lines)) {
      if (line.trim().isEmpty) continue;
      Map<String, dynamic> o;
      try {
        o = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (agent == 'codex') {
        final p = o['payload'];
        if (o['type'] == 'event_msg' &&
            p is Map &&
            p['type'] == 'agent_message' &&
            p['message'] is String) {
          out.write(p['message']);
          out.write('\n');
        }
      } else {
        // claude (default)
        final msg = o['message'];
        final content = msg is Map ? msg['content'] : null;
        if (o['type'] == 'assistant' && content is List) {
          for (final b in content) {
            if (b is Map && b['type'] == 'text' && b['text'] is String) {
              out.write(b['text']);
              out.write('\n');
            }
          }
        }
      }
    }
    return _clean(out.toString());
  }

  String? _clean(String s) {
    var t = s.replaceAll(_fenced, ' '); // drop fenced code blocks
    t = t.replaceAll('`', '');
    t = t.replaceAll(_ws, ' ').trim();
    if (t.isEmpty) return null;
    return t.length > _speakCap ? '${t.substring(0, _speakCap)}…' : t;
  }

  Future<int> _lengthOf(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return 0;
    }
  }

  // _resolveLogPath returns the agent's current session-log file, or null. The
  // resolved path is reused while it still exists (claude is deterministic by
  // uuid; codex's rollout is stable within a run), so we only scan once.
  Future<String?> _resolveLogPath(TerminalSession s) async {
    final cached = _cursor[s.id]?.path;
    if (cached != null && cached.isNotEmpty && await File(cached).exists()) {
      return cached;
    }
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return null;
    if (s.agentKind == 'codex') return _newestCodexRollout(home, s.workdir);
    final id = s.agentSessionId;
    if (id == null || id.isEmpty) return null; // can't locate without the uuid
    final projects = Directory('$home/.claude/projects');
    if (!await projects.exists()) return null;
    await for (final d in projects.list(followLinks: false)) {
      if (d is Directory) {
        final f = File('${d.path}/$id.jsonl');
        if (await f.exists()) return f.path;
      }
    }
    return null;
  }

  // _newestCodexRollout finds the most-recent rollout whose session_meta.cwd
  // matches [workdir] (codex has no pre-assignable id, so we match by cwd). We
  // sort candidates newest-first by mtime and read only each file's first line
  // until one matches — so the common case (the active session is the newest
  // rollout) costs a single JSON parse, not one per historical rollout.
  Future<String?> _newestCodexRollout(String home, String workdir) async {
    final root = Directory('$home/.codex/sessions');
    if (!await root.exists()) return null;
    final files = <(DateTime, String)>[];
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is File &&
          e.path.endsWith('.jsonl') &&
          e.path.contains('rollout-')) {
        files.add(((await e.stat()).modified, e.path));
      }
    }
    files.sort((a, b) => b.$1.compareTo(a.$1)); // newest first
    for (final (_, path) in files) {
      try {
        final first = await File(path)
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
        if ((jsonDecode(first) as Map)['payload']?['cwd'] == workdir) {
          return path;
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  // --- STT: voice → text (delegated to the shared SpeechInput) ---------------

  Future<bool> startListening({
    required void Function(String text) onFinal,
    void Function(String text)? onPartial,
  }) => _input.start(onFinal: onFinal, onPartial: onPartial);

  Future<void> stopListening() => _input.stop();

  void dispose() {
    _input.dispose();
    _tts.stop();
  }
}
