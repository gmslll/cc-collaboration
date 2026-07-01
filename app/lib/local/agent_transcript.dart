import 'dart:convert';
import 'dart:io';

// Shared on-disk agent transcript access: locate a claude/codex session's JSONL
// log and render its recent assistant output as plain text. Both the voice
// reader (reads new replies to speak) and the local-bus `msg read --transcript`
// channel (reads a peer session's structured output instead of screen-scraping)
// use this — TUI agents still write the full structured conversation to disk, so
// reading the log beats stripping ANSI off the rendered screen.
//
// Pure functions over (agentKind, agentSessionId, workdir) — no UI/session types
// — so `app/lib/local` stays free of `screens/` imports.

// resolveTranscriptPath returns the agent's current session-log file, or null.
// claude: prefer the exact minted id (glob in case the cwd-encoded dir name
// differs from our guess), else the cwd's newest log (covers `--continue` /
// legacy sessions with no minted id). codex: newest rollout whose cwd matches.
Future<String?> resolveTranscriptPath({
  required String agentKind,
  required String? agentSessionId,
  required String workdir,
}) async {
  final home = Platform.environment['HOME'] ?? '';
  if (home.isEmpty) return null;
  if (agentKind == 'codex') return _newestCodexRollout(home, workdir);
  final id = agentSessionId;
  if (id != null && id.isNotEmpty) {
    final projects = Directory('$home/.claude/projects');
    if (await projects.exists()) {
      await for (final d in projects.list(followLinks: false)) {
        if (d is Directory) {
          final f = File('${d.path}/$id.jsonl');
          if (await f.exists()) return f.path;
        }
      }
    }
    // We know this session's EXACT id but its log isn't on disk yet — a dormant
    // lazy tab whose agent hasn't started, or a just-launched one before its
    // first write. Return null (caller retries; the id-glob above is uncached)
    // rather than falling back to the cwd's newest log: every tab in one project
    // shares that dir, so the fallback would hand back a SIBLING session's
    // transcript and bleed its content into this session's preview/usage/read
    // (串味). The glob already scans every project dir, so a mismatched cwd-encoded
    // dir name is covered — a miss here means the log genuinely doesn't exist yet.
    return null;
  }
  // No minted id (legacy --continue / pre-upgrade restore carries none): the
  // newest log in this cwd is the only available guess.
  return _newestClaudeInCwd(home, workdir);
}

// _newestClaudeInCwd: claude encodes the cwd as the project dir name with '/' and
// '.' replaced by '-' (e.g. /a/github.com/b -> -a-github-com-b).
Future<String?> _newestClaudeInCwd(String home, String workdir) async {
  final enc = workdir.replaceAll(RegExp(r'[/.]'), '-');
  final dir = Directory('$home/.claude/projects/$enc');
  if (!await dir.exists()) return null;
  String? best;
  DateTime? bestMod;
  await for (final e in dir.list(followLinks: false)) {
    if (e is! File || !e.path.endsWith('.jsonl')) continue;
    final mod = (await e.stat()).modified;
    if (bestMod == null || mod.isAfter(bestMod)) {
      best = e.path;
      bestMod = mod;
    }
  }
  return best;
}

// _newestCodexRollout: codex has no pre-assignable id, so match by cwd. Sort
// newest-first and read only each file's first line until one matches — the
// common case (active session = newest rollout) costs one JSON parse.
Future<String?> _newestCodexRollout(String home, String workdir) async {
  final root = Directory('$home/.codex/sessions');
  if (!await root.exists()) return null;
  final files = <(DateTime, String)>[];
  await for (final e in root.list(recursive: true, followLinks: false)) {
    if (e is File && e.path.endsWith('.jsonl') && e.path.contains('rollout-')) {
      files.add(((await e.stat()).modified, e.path));
    }
  }
  files.sort((a, b) => b.$1.compareTo(a.$1));
  for (final (_, path) in files) {
    try {
      final first = await File(path)
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      if ((jsonDecode(first) as Map)['payload']?['cwd'] == workdir) return path;
    } catch (_) {
      continue;
    }
  }
  return null;
}

// _tailCap bounds how many bytes we read off the END of the log so a multi-MB
// transcript stays cheap — we only want recent output anyway.
const int _tailCap = 512 * 1024;

// renderTranscriptTail reads the tail of [path] and renders the recent assistant
// output as plain text: claude `message.content` text blocks verbatim, `tool_use`
// blocks as `[tool: <name>]` markers (thinking + tool results skipped); codex
// `agent_message` payloads. The last [lines] rendered lines are returned, mirroring
// the screen read's `--lines` semantics. Bad/partial lines are skipped, not fatal.
Future<String> renderTranscriptTail(
  String path, {
  required int lines,
  required String agentKind,
}) async {
  final f = File(path);
  final len = await f.length();
  final start = len > _tailCap ? len - _tailCap : 0;
  final raf = await f.open();
  String chunk;
  try {
    await raf.setPosition(start);
    chunk = utf8.decode(await raf.read(len - start), allowMalformed: true);
  } finally {
    await raf.close();
  }
  // Drop a partial first line if we started mid-file.
  if (start > 0) {
    final nl = chunk.indexOf('\n');
    chunk = nl >= 0 ? chunk.substring(nl + 1) : '';
  }

  final rendered = <String>[];
  for (final line in const LineSplitter().convert(chunk)) {
    if (line.trim().isEmpty) continue;
    Map<String, dynamic> o;
    try {
      o = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    if (agentKind == 'codex') {
      final p = o['payload'];
      if (o['type'] == 'event_msg' &&
          p is Map &&
          p['type'] == 'agent_message' &&
          p['message'] is String) {
        rendered.add((p['message'] as String).trimRight());
      }
    } else {
      final msg = o['message'];
      final content = msg is Map ? msg['content'] : null;
      if (o['type'] == 'assistant' && content is List) {
        for (final b in content) {
          if (b is! Map) continue;
          if (b['type'] == 'text' && b['text'] is String) {
            rendered.add((b['text'] as String).trimRight());
          } else if (b['type'] == 'tool_use' && b['name'] is String) {
            rendered.add('[tool: ${b['name']}]');
          }
        }
      }
    }
  }

  // Flatten to individual lines before tailing: a rendered block (an assistant
  // text block) can itself be multi-line, so join+split makes [lines] count
  // actual lines — matching the screen read's --lines semantics — not blocks.
  final ls = rendered.join('\n').split('\n');
  return ls.length <= lines ? ls.join('\n') : ls.sublist(ls.length - lines).join('\n');
}
