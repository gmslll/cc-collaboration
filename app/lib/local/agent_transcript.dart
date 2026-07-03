import 'dart:convert';
import 'dart:io';

import 'path_utils.dart';

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
// Both kinds share the same shape: prefer the exact minted/captured id (a
// precise match, never a guess), else the cwd's newest log — a fallback used
// only when there's no id to pin to (claude: legacy `--continue` restore;
// codex: an id capture that hasn't landed yet). Never degrade an id lookup
// into a cwd/mtime guess: see the 串味 note below on why that bled sibling
// sessions' transcripts into each other.
Future<String?> resolveTranscriptPath({
  required String agentKind,
  required String? agentSessionId,
  required String workdir,
}) async {
  final home = Platform.environment['HOME'] ?? '';
  if (home.isEmpty) return null;
  if (agentKind == 'codex') {
    final id = agentSessionId;
    if (id != null && id.isNotEmpty) return _codexRolloutById(home, id);
    return _newestCodexRollout(home, workdir);
  }
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

// _newestCodexRollout: no id to pin to (see resolveTranscriptPath), so this is
// a best-effort guess by cwd. Sort newest-first and read only each file's
// first line until one matches — the common case (active session = newest
// rollout) costs one JSON parse. Only used when agentSessionId is empty.
Future<String?> _newestCodexRollout(String home, String workdir) async {
  final root = Directory('$home/.codex/sessions');
  if (!await root.exists()) return null;
  final files = <(DateTime, File)>[];
  await for (final e in root.list(recursive: true, followLinks: false)) {
    if (e is File && e.path.endsWith('.jsonl') && e.path.contains('rollout-')) {
      files.add(((await e.stat()).modified, e));
    }
  }
  files.sort((a, b) => b.$1.compareTo(a.$1));
  for (final (_, f) in files) {
    final meta = await readRolloutMeta(f);
    if (cwdMatches(meta?['cwd']?.toString(), workdir)) return f.path;
  }
  return null;
}

// _codexRolloutById scans every rollout under [home]/.codex/sessions for the
// one whose payload carries the EXACT [id] — the codex analogue of the claude
// branch's filename match above. No cwd/mtime guessing: an id we already
// captured pins to one specific file, or none if that log isn't on disk yet.
Future<String?> _codexRolloutById(String home, String id) async {
  final root = Directory('$home/.codex/sessions');
  if (!await root.exists()) return null;
  await for (final e in root.list(recursive: true, followLinks: false)) {
    if (e is File && e.path.endsWith('.jsonl') && e.path.contains('rollout-')) {
      final meta = await readRolloutMeta(e);
      if (meta?['id']?.toString() == id) return e.path;
    }
  }
  return null;
}

// readRolloutMeta reads a codex rollout's session_meta payload (its first
// JSONL line), or null if the file is missing/unparsable/empty. Shared by
// every codex rollout lookup here and by TerminalSession's id-capture (lsof
// hit / directory scan) in terminal_pane.dart, so there is exactly one parser
// for this format.
Future<Map?> readRolloutMeta(File f) async {
  try {
    final firstLine = await f
        .openRead()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .first;
    final m = jsonDecode(firstLine);
    if (m is! Map) return null;
    final payload = m['payload'];
    return payload is Map ? payload : null;
  } catch (_) {
    return null;
  }
}

// cwdMatches compares a rollout's recorded cwd to a session's workdir,
// tolerating path-separator/`.`/`..` differences and symlinked paths (so
// /tmp vs /private/tmp, common on macOS, still matches).
bool cwdMatches(String? cwd, String workdir) {
  if (cwd == null || cwd.isEmpty) return false;
  if (pathEquals(cwd, workdir)) return true;
  try {
    return Directory(cwd).resolveSymbolicLinksSync() ==
        Directory(workdir).resolveSymbolicLinksSync();
  } catch (_) {
    return false;
  }
}

// pickUniqueRolloutId scans [files] for rollouts whose payload cwd matches
// [workdir] and carries a non-empty id, returning that id ONLY if exactly one
// file matches. Zero matches -> null (nothing found yet); more than one ->
// also null, deliberately: when several candidate files match within the same
// narrow window (e.g. sibling codex sessions launched in the same cwd within
// seconds of each other), there is no principled way to pick the "right" one,
// and guessing (e.g. newest-wins) is exactly what let one session capture and
// persist ANOTHER session's id — 串味. Callers that poll (see
// TerminalSession._captureAgentId) just retry; ambiguity within one window is
// usually gone by the next.
Future<String?> pickUniqueRolloutId(List<File> files, String workdir) async {
  final matches = <String>[];
  for (final f in files) {
    final meta = await readRolloutMeta(f);
    if (meta == null) continue;
    if (!cwdMatches(meta['cwd']?.toString(), workdir)) continue;
    final id = meta['id']?.toString();
    if (id == null || id.isEmpty) continue;
    matches.add(id);
  }
  return matches.length == 1 ? matches.first : null;
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
