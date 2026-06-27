import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xterm/xterm.dart';

import '../local/agent_resolver.dart';
import '../local/cli.dart';
import '../local/local_bus.dart';
import '../local/platform.dart';
import '../terminal_theme.dart';
import '../terminal_mouse.dart';
import '../widgets.dart';

// TerminalSession owns a PTY + xterm Terminal model. The cockpit keeps a list of
// these (one per pickup/worktree) for multi-session tabs and can sendText into
// the active one (e.g. paste the materialized prompt).
class TerminalSession {
  static int _seq = 0;
  final String id = 'ts${_seq++}'; // stable per-run id (for remote addressing)
  final String workdir;
  final String command;
  final String title;
  String? name; // user-given label; overrides the derived title when set
  // --- AI-session binding (resume the same conversation after an app restart) -
  // agent is the explicit kind ('claude'/'codex'/'' for shell/raw) — set by the
  // launcher, not sniffed. preLaunch is the shell run before the agent (e.g.
  // 'clset 6'). For claude we mint a fixed [agentSessionId] (uuid) at first
  // launch and pass it via --session-id, then --resume it next time so the tab
  // reopens the exact same conversation. codex can't pre-assign an id, so it
  // resumes the cwd's most-recent rollout instead (see _resolvedCommand). resume
  // is true only when this session is being reopened from persistence.
  final String agent;
  final String preLaunch;
  // Mutable: claude gets a fixed id at construction; codex can't be given one at
  // launch, so it's captured from codex's rollout file after start (see
  // _maybeCaptureCodexId) and then persisted.
  String? agentSessionId;
  final bool resume;
  final Terminal terminal = Terminal(maxLines: 10000);
  // The selection/copy controller lives on the session (not the pane) so the
  // host can read the current selection — e.g. to forward it to another session.
  //
  // pointerInputs: none() stops the controller forwarding mouse clicks into the
  // PTY. A full-screen TUI (claude/codex) otherwise eats left/right clicks, so
  // GUI text selection never registers (the "发送选区" menu stays grey), the
  // right-click context menu never opens, and a press-without-release wedges the
  // TUI ("卡死"). With clicks kept GUI-side, drag = pure selection and right-tap
  // = our menu — and wheel scroll is unaffected (it goes through a separate path
  // that doesn't consult pointerInputs). Focus-on-click still works (onTapDown
  // fires regardless). Trade-off: clicks no longer reach the TUI (keyboard- and
  // wheel-driven, so fine for claude/codex; shells never had mouse mode anyway).
  final TerminalController controller =
      TerminalController(pointerInputs: const PointerInputs.none());
  Pty? _pty;
  bool _started = false;
  bool _disposed = false;
  // Resolved agent launch token (abs path / user override / bare name), set in
  // _startAsync before the PTY spawns. Null until resolved (non-agent sessions
  // leave it null and _resolvedCommand ignores it).
  String? _invocation;

  // remoteSink, when set, also receives this terminal's (utf8-decoded) PTY
  // output so a remote phone client can mirror it. Null when nobody's watching.
  void Function(String chunk)? remoteSink;

  // --- "agent finished a turn" detection (bell-only) ----------------------
  //
  // claude/codex ring the terminal bell (BEL \x07) exactly when they stop and
  // wait for you — finished a turn, or blocked on a permission/input prompt —
  // and NOT while working. So a bell, confirmed by output then going quiet, is
  // what we fire [onDone] on (→ a "会话完成" notification). There is no idle/
  // timeout heuristic: mid-turn pauses (between streamed chunks, tool calls,
  // thinking) don't bell, so they never notify. Only for isAgent sessions, and
  // only after the user has actually given the agent something to do (_sawInput)
  // so the initial idle prompt doesn't ping. Trade-off: an agent with the
  // terminal bell disabled won't notify.
  void Function(TerminalSession session)? onDone;
  // onPersist asks the host to re-save the session list — fired after a codex
  // session id is captured so a reopened tab can resume the exact conversation.
  void Function()? onPersist;
  Timer? _belTimer;
  bool _belArmed = false; // a bell rang; waiting for output to settle to confirm
  bool _sawInput = false; // user has typed/sent into this session at least once
  // _busy = this agent is mid-turn (we submitted input; no finishing bell yet).
  // Read via [busy], which ANDs isAgent so it's only ever meaningful for agent
  // sessions. Drives local-bus delivery: a busy agent's incoming peer message is
  // parked in its bus inbox for its PostToolUse/Stop hook to inject mid-turn,
  // instead of pasting (which would just queue behind the running turn). Set
  // when a turn starts (a submit \r reaches an agent), cleared on the finishing
  // bell (_fireDone).
  bool _busy = false;
  bool get busy => isAgent && _busy;
  static const Duration _belSettle =
      Duration(milliseconds: 1200); // quiet-after-bell → done

  // Rolling buffer of recent raw PTY output so a phone connecting mid-session
  // can replay it and see the current screen / scrollback instead of a blank
  // terminal until the next redraw. Kept always (even with no watcher) and
  // bounded by char count; whole chunks go in/out to avoid splitting an escape
  // sequence mid-stream.
  final Queue<String> _backlog = Queue<String>();
  int _backlogLen = 0;
  static const int _backlogCap = 256 * 1024;

  // Trailing-whitespace matcher for renderSnapshot; compiled once, not per call.
  static final RegExp _trailingBlank = RegExp(r'\s+$');

  void _appendBacklog(String chunk) {
    _backlog.add(chunk);
    _backlogLen += chunk.length;
    while (_backlogLen > _backlogCap && _backlog.length > 1) {
      _backlogLen -= _backlog.removeFirst().length;
    }
  }

  String get backlog => _backlog.join();

  TerminalSession(
    this.workdir,
    this.command, {
    this.agent = '',
    this.preLaunch = '',
    this.agentSessionId,
    this.resume = false,
  }) : title = workdir.split('/').where((s) => s.isNotEmpty).isNotEmpty
           ? workdir.split('/').lastWhere((s) => s.isNotEmpty)
           : workdir {
    // Fix xterm 4.0.0's broken wheel reporting so scroll reaches full-screen
    // agent TUIs (claude/codex), which scroll fine in real terminals.
    terminal.mouseHandler = const WheelMouseHandler();
  }

  // label is what the UI shows: the user-given name, else the derived title.
  String get label => (name != null && name!.isNotEmpty) ? name! : title;

  // asTarget is this session as a send-menu target (id + label).
  SendTarget get asTarget => (id: id, label: label);

  // isAgent reports whether this session runs an AI agent TUI (claude/codex),
  // sniffed from the launch command — the same convention used in
  // workspace_page.dart and remote_host.dart. The local bus reads it to decide
  // whether to attach a reply cheat-sheet to a delivered message.
  bool get isAgent => command.contains('claude') || command.contains('codex');

  // agentKind is the authoritative agent name ('claude'/'codex') for labels and
  // notifications: the explicit field when the launcher set it, else the legacy
  // command sniff (pickup / pre-upgrade sessions that carry no agent field).
  String get agentKind =>
      agent.isNotEmpty ? agent : (command.contains('codex') ? 'codex' : 'claude');

  // selectedText is the current selection's text, or null when nothing is
  // selected. The host reads it to forward a selection to another session.
  String? get selectedText {
    final sel = controller.selection;
    if (sel == null) return null;
    final t = terminal.buffer.getText(sel);
    return t.isEmpty ? null : t;
  }

  // renderSnapshot returns the last [lines] lines of this session's terminal as
  // plain text — the rendered screen + scrollback with ANSI stripped, which is
  // what `cc-handoff msg read` hands a sibling session. We render the whole
  // xterm buffer (getText with no range; bounded by maxLines=10000) and tail it
  // so a full-screen TUI (claude/codex) reads as the visible screen rather than
  // a stream of redraw escape codes. [lines] <= 0 returns the whole buffer.
  String renderSnapshot(int lines) {
    // Drop trailing blank lines (a TUI's idle bottom rows) for a tidy snapshot.
    final all = terminal.buffer.getText().replaceFirst(_trailingBlank, '');
    if (lines <= 0) return all;
    final ls = all.split('\n');
    return ls.length <= lines ? all : ls.sublist(ls.length - lines).join('\n');
  }

  // historyText is the session's buffer (scrollback + screen) as plain text with
  // CRLF endings — for replaying READABLE history to a phone whose width differs
  // from this terminal's. The raw byte backlog bakes in THIS width's layout and
  // renders mis-wrapped at another width; this strips ANSI/colour so the phone's
  // terminal re-wraps each line at its own width. getText joins rows with '\n';
  // a terminal needs '\r\n' to also return to column 0, so normalise.
  String historyText() {
    final all = terminal.buffer.getText().replaceFirst(_trailingBlank, '');
    return all.split(RegExp(r'\r?\n')).join('\r\n');
  }

  // historyAnsi is historyText with COLOUR: it walks the buffer's cells and
  // re-emits them as a logical-line stream with inline SGR escapes, so a phone
  // re-wraps it at its own width AND keeps fg/bg/bold/etc. Soft-wrapped rows
  // carry no line break (isWrapped) so the phone re-flows them. Encoding per
  // xterm core/cell.dart (CellColor packs type<<25 | 0xRRGGBB-or-index; CellAttr
  // bit flags). Absolute-positioned TUI chrome flattens, same as historyText.
  String historyAnsi() {
    String colorSgr(int c, bool fg) {
      final v = c & CellColor.valueMask;
      switch (c & CellColor.typeMask) {
        case CellColor.named:
          return '${v < 8 ? (fg ? 30 : 40) + v : (fg ? 90 : 100) + (v - 8)}';
        case CellColor.palette:
          return '${fg ? 38 : 48};5;$v';
        case CellColor.rgb:
          return '${fg ? 38 : 48};2;${(v >> 16) & 0xff};${(v >> 8) & 0xff};${v & 0xff}';
        default: // normal → default fg/bg
          return fg ? '39' : '49';
      }
    }

    String sgr(int fg, int bg, int at) {
      final p = <String>['0']; // reset, then re-apply the full style — robust
      if ((at & CellAttr.bold) != 0) p.add('1');
      if ((at & CellAttr.faint) != 0) p.add('2');
      if ((at & CellAttr.italic) != 0) p.add('3');
      if ((at & CellAttr.underline) != 0) p.add('4');
      if ((at & CellAttr.blink) != 0) p.add('5');
      if ((at & CellAttr.inverse) != 0) p.add('7');
      if ((at & CellAttr.invisible) != 0) p.add('8');
      if ((at & CellAttr.strikethrough) != 0) p.add('9');
      p.add(colorSgr(fg, true));
      p.add(colorSgr(bg, false));
      return '\x1b[${p.join(';')}m';
    }

    final buf = terminal.buffer;
    var last = buf.height - 1;
    while (last >= 0 && buf.lines[last].getTrimmedLength() == 0) {
      last--; // drop trailing blank lines (idle TUI bottom rows)
    }
    final out = StringBuffer();
    int? pf, pb, pa; // last-emitted fg/bg/attrs, to only emit SGR on change
    for (var y = 0; y <= last; y++) {
      final line = buf.lines[y];
      if (y != 0 && !line.isWrapped) out.write('\r\n');
      final len = line.getTrimmedLength();
      for (var x = 0; x < len; x++) {
        if (line.getWidth(x) == 0) continue; // wide-char continuation cell
        final fg = line.getForeground(x);
        final bg = line.getBackground(x);
        final at = line.getAttributes(x);
        if (fg != pf || bg != pb || at != pa) {
          out.write(sgr(fg, bg, at));
          pf = fg;
          pb = bg;
          pa = at;
        }
        final cp = line.getCodePoint(x);
        out.writeCharCode(cp == 0 ? 0x20 : cp);
      }
    }
    out.write('\x1b[0m');
    return out.toString();
  }

  // _resolvedCommand is the shell command actually run for this session. For a
  // plain shell / arbitrary command it's [command] unchanged. For an agent it's
  // rebuilt from agent + preLaunch + session binding so a reopened tab resumes
  // its prior conversation: claude binds a fixed --session-id on first launch
  // and --resume's it thereafter; codex has no pre-assignable id so it resumes
  // the cwd's most-recent rollout (--last). preLaunch (if any) is prepended.
  String _resolvedCommand() {
    if (agent != 'claude' && agent != 'codex') return command;
    final pre = preLaunch.trim();
    final prefix = pre.isEmpty ? '' : '$pre && ';
    // The agent invocation: a resolved absolute path / user override (set in
    // _startAsync via AgentResolver), else the bare agent name as a last resort.
    final inv = (_invocation != null && _invocation!.isNotEmpty)
        ? _invocation!
        : agent;
    if (agent == 'claude') {
      if (!resume) {
        return agentSessionId == null
            ? '$prefix$inv'
            : '$prefix$inv --session-id $agentSessionId';
      }
      // Reopen: resume the exact id; fall back to most-recent if we never minted
      // one (e.g. a pre-upgrade persisted session).
      return agentSessionId == null
          ? '$prefix$inv --continue'
          : '$prefix$inv --resume $agentSessionId';
    }
    // codex can't be given a session id at launch; we capture the one it mints
    // (see _maybeCaptureCodexId) and resume that EXACT session on reopen, falling
    // back to the cwd's most-recent rollout if we never captured one.
    if (!resume) return '$prefix$inv';
    return agentSessionId == null
        ? '$prefix$inv resume --last'
        : '$prefix$inv resume ${agentSessionId!}';
  }

  void start() {
    if (_started) return;
    _started = true;
    unawaited(_startAsync());
  }

  Future<void> _startAsync() async {
    // Resolve how to launch the agent (user override / discovered absolute path /
    // bare name) BEFORE spawning, so a claude/codex that isn't on the GUI's PATH
    // still starts. Cheap and cached after the first session (see AgentResolver).
    if (agent == 'claude' || agent == 'codex') {
      _invocation = await AgentResolver.resolve(agent);
    }
    if (_disposed) return; // closed during the async resolve
    // Empty command = a plain interactive shell (typeable + scrollable);
    // otherwise run the (resolved) agent command and let the shell exit with it.
    final cmd = _resolvedCommand();
    final String shell;
    final List<String> args;
    if (Platform.isWindows) {
      // Windows has no /bin/sh and no SHELL; use the command processor. A bare
      // cmd.exe gives an interactive prompt; `/c <cmd>` runs the agent and exits
      // with it. (POSIX `-i -l` flags would make cmd.exe error out.)
      shell = Platform.environment['COMSPEC'] ?? 'cmd.exe';
      args = cmd.isEmpty ? const [] : ['/c', cmd];
    } else {
      shell = Platform.environment['SHELL'] ?? '/bin/sh';
      args = cmd.isEmpty ? const ['-i', '-l'] : ['-i', '-c', cmd];
    }
    // Resolve the working directory: expand a leading ~ and fall back to the home
    // dir if it doesn't exist, so a stale or Unix-style path can't make the spawn
    // throw (Pty.start hands workingDirectory straight to the OS).
    var wd = expandHome(workdir);
    if (wd.isEmpty || !Directory(wd).existsSync()) wd = homeDir();

    final Pty pty;
    try {
      pty = Pty.start(
        shell,
        arguments: args,
        // Declare a real terminal type so full-screen TUIs (claude/codex) enable
        // mouse reporting → wheel scroll reaches them. The CC_* vars wire this
        // session into the local message bus: the agent inside calls
        // `"$CC_HANDOFF_BIN" msg send <peer> …` (or bare `cc-handoff` — its dir is
        // prepended to PATH) to reach a sibling session. NOTE: flutter_pty forwards
        // only a fixed env allowlist plus this map — NOT the full parent env — so
        // _sessionEnv() seeds the full environment on Windows itself (without it
        // cmd.exe has no SystemRoot and the terminal spawns blank).
        environment: _sessionEnv(),
        workingDirectory: wd,
        rows: terminal.viewHeight,
        columns: terminal.viewWidth,
      );
    } catch (e) {
      // A spawn failure used to leave a silent blank terminal — surface it.
      terminal.write('\r\n\x1b[31m[启动失败] 无法启动 $shell:\r\n$e\x1b[0m\r\n');
      return;
    }
    _pty = pty;
    pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
          terminal.write(chunk);
          _appendBacklog(chunk);
          remoteSink?.call(chunk);
          if (isAgent) _markActivity(chunk);
        });
    pty.exitCode.then((code) {
      // Non-zero exits in red so a process that dies on startup isn't mistaken
      // for an empty terminal.
      terminal.write('\r\n\x1b[${code == 0 ? '90' : '31'}m[已退出: $code]\x1b[0m\r\n');
      // 127 = command not found: the agent binary couldn't be launched. Point
      // the user at the per-agent override so they can fix it.
      if (code == 127 && (agent == 'claude' || agent == 'codex')) {
        terminal.write('\x1b[33m未找到 $agent。可在「账号 · config.toml」设置 '
            '${agent}_command(绝对路径或启动命令)后重开。\x1b[0m\r\n');
      }
    });
    terminal.onOutput = (data) {
      _sawInput = true; // local keystrokes count as "the user gave it work"
      // A local Enter into an agent starts a turn → mark busy so a peer message
      // arriving now routes to the bus inbox (hook injection) not a paste queue.
      if (isAgent && data.contains('\r')) _busy = true;
      pty.write(const Utf8Encoder().convert(data));
    };
    // A phone mirroring this session (remoteSink set) owns the PTY size; don't
    // let local (Mac window) resizes fight it — last-writer-wins between the
    // wide Mac and the narrow phone is what garbles the mirror.
    terminal.onResize = (w, h, pw, ph) {
      if (remoteSink == null) pty.resize(h, w);
    };
    _maybeCaptureCodexId();
  }

  // --- codex session-id capture -------------------------------------------
  //
  // codex (unlike claude) can't be told a session id at launch, but it writes a
  // rollout file $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl whose
  // first line (session_meta) carries {id, cwd}. After a FRESH codex launch we
  // poll for the rollout written since launch whose cwd matches this session's
  // workdir, capture its uuid into agentSessionId, and ask the host to persist —
  // so a reopened tab resumes that EXACT conversation (`codex resume <uuid>`)
  // instead of the fragile `codex resume --last`. Best-effort: on miss the
  // session simply keeps the --last behaviour.
  bool _codexCaptureStarted = false;

  void _maybeCaptureCodexId() {
    if (_codexCaptureStarted) return;
    if (agent != 'codex' || resume || agentSessionId != null) return;
    _codexCaptureStarted = true;
    unawaited(_captureCodexId(DateTime.now()));
  }

  Future<void> _captureCodexId(DateTime since) async {
    final home = Platform.environment['CODEX_HOME'] ?? '${homeDir()}/.codex';
    final sessions = Directory('$home/sessions');
    for (var attempt = 0; attempt < 30; attempt++) {
      await Future.delayed(const Duration(milliseconds: 600));
      if (_disposed) return;
      final id = await _findCodexRollout(sessions, since);
      if (id != null) {
        agentSessionId = id;
        onPersist?.call();
        return;
      }
    }
  }

  // _findCodexRollout returns the codex session id of the newest rollout under
  // [sessions] written at/after [since] whose cwd matches this session, or null.
  // Only today's (and a 6h-earlier, for the midnight boundary) date bucket is
  // scanned, so cost is bounded no matter how many old sessions exist.
  Future<String?> _findCodexRollout(Directory sessions, DateTime since) async {
    String bucket(DateTime d) =>
        '${sessions.path}/${d.year.toString().padLeft(4, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/'
        '${d.day.toString().padLeft(2, '0')}';
    final dirs = <String>{
      bucket(since),
      bucket(since.subtract(const Duration(hours: 6))),
    };
    final files = <File>[];
    for (final p in dirs) {
      final d = Directory(p);
      if (!await d.exists()) continue;
      try {
        await for (final e in d.list(followLinks: false)) {
          if (e is File &&
              e.path.contains('rollout-') &&
              e.path.endsWith('.jsonl')) {
            files.add(e);
          }
        }
      } catch (_) {}
    }
    files.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    final floor = since.subtract(const Duration(seconds: 5));
    for (final f in files) {
      if (f.statSync().modified.isBefore(floor)) break;
      final id = await _rolloutId(f);
      if (id != null) return id;
    }
    return null;
  }

  // _rolloutId reads a rollout file's session_meta (first line) and returns its
  // id iff its cwd matches this session's workdir.
  Future<String?> _rolloutId(File f) async {
    try {
      final firstLine = await f
          .openRead()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .first;
      final m = jsonDecode(firstLine);
      if (m is! Map) return null;
      final payload = m['payload'];
      if (payload is! Map) return null;
      if (payload['cwd']?.toString() != workdir) return null;
      final id = payload['id']?.toString();
      return (id != null && id.isNotEmpty) ? id : null;
    } catch (_) {
      return null;
    }
  }

  int? get pid => _pty?.pid;

  // _sessionEnv builds the PTY environment: the terminal type (so TUIs report
  // mouse) plus the local-bus wiring (CC_SESSION_ID/NAME for identity, CC_BUS_DIR
  // + CC_HANDOFF_BIN for the `msg` CLI). The cc-handoff dir is prepended to PATH
  // so a bundled (non-system) binary is still callable by bare name.
  //
  // flutter_pty 0.4.2 does NOT forward the full parent environment — it copies
  // only a fixed POSIX allowlist (HOME/PATH/USER/LOGNAME/DISPLAY/LC_TYPE) plus
  // whatever we pass here. That's enough for /bin/sh on macOS, but cmd.exe can't
  // even start without SystemRoot (and needs ComSpec/PATHEXT/TEMP/…), so on
  // Windows we must seed the full Platform.environment ourselves — otherwise the
  // terminal spawns blank. macOS keeps the lean map (don't change what works).
  Map<String, String> _sessionEnv() {
    final bin = Cli.binPath();
    final env = <String, String>{
      if (Platform.isWindows) ...Platform.environment,
      'TERM': 'xterm-256color',
      'COLORTERM': 'truecolor',
      'CC_SESSION_ID': id,
      'CC_SESSION_NAME': label,
      'CC_BUS_DIR': localBusDir(),
      'CC_HANDOFF_BIN': bin,
    };
    if (bin.contains(Platform.pathSeparator)) {
      final binDir = File(bin).parent.path;
      final sep = Platform.isWindows ? ';' : ':';
      final base = Platform.environment['PATH'] ?? '';
      env['PATH'] = base.isEmpty ? binDir : '$binDir$sep$base';
    }
    return env;
  }

  void sendText(String s) {
    _sawInput = true; // remote keys / delivered messages also arm the detector
    // A lone CR submitting to an agent starts a turn (remote Enter, or the
    // submit \r pasteText sends after a delivered message) → mark busy.
    if (isAgent && s == '\r') _busy = true;
    _pty?.write(const Utf8Encoder().convert(s));
  }

  // _markActivity feeds the turn detector one output chunk. A BEL arms it; while
  // armed, every chunk (re)starts the settle timer so _fireDone runs only once
  // output goes quiet AFTER the bell — the final redraw doesn't fire it early,
  // and a bell whose work then resumes keeps pushing the timer out. Output with
  // no bell since the last fire does nothing: no idle/timeout path, so a mid-turn
  // pause never reads as "done".
  void _markActivity(String chunk) {
    if (!_belArmed && chunk.contains('\x07')) _belArmed = true;
    if (!_belArmed) return;
    _belTimer?.cancel();
    _belTimer = Timer(_belSettle, _fireDone);
  }

  // _fireDone announces a finished turn. It only runs while armed by a bell;
  // it skips turns the user never kicked off (_sawInput) — e.g. the initial idle
  // prompt — and disarms so the next turn needs a fresh bell.
  void _fireDone() {
    _belArmed = false;
    _busy = false; // bell settled → agent is idle/waiting again
    if (!_sawInput) return;
    onDone?.call(this);
  }

  // pasteText injects [s] as one bracketed-paste block (ESC[200~ … ESC[201~) so
  // a full-screen TUI inserts it atomically — no per-newline submit, no control-
  // char interpretation — even mid-stream. Use this (not sendText) for any
  // programmatically delivered message; sendText stays raw for keystrokes.
  void pasteText(String s, {bool submit = false}) {
    sendText('\x1b[200~$s\x1b[201~');
    if (!submit) return;
    // Send Enter after a short delay (a \r in the same instant as ESC[201~ lands
    // before the TUI has committed the paste and gets swallowed → text sits in
    // the input box unsent). The delay alone is a guess, so [_ensureSubmitted] is
    // the backstop: it verifies the box actually cleared and re-sends Enter if not.
    Future.delayed(_submitDelay, () {
      if (_disposed) return;
      final before = renderSnapshot(_submitCheckLines);
      sendText('\r');
      _ensureSubmitted(before, 0);
    });
  }

  // _ensureSubmitted is the auto-submit backstop. [before] is the bottom input
  // region snapshotted with our text sitting in it, right before the \r. Shortly
  // after, we snapshot again: if it's UNCHANGED the \r was swallowed (text still
  // parked unsent) → resend Enter, up to [_submitRetries] times. Any change
  // (input cleared, message echoed back, agent started) means it submitted →
  // stop checking. Comparing before/after (not text-matching our message) avoids
  // a false hit from the just-submitted message echoing near the bottom; a stray
  // resend (if it had already submitted) is a harmless Enter on an empty prompt.
  void _ensureSubmitted(String before, int attempt) {
    if (attempt >= _submitRetries) return;
    Future.delayed(_submitCheckDelay, () {
      if (_disposed) return;
      if (renderSnapshot(_submitCheckLines) != before) return; // cleared → sent
      sendText('\r'); // unchanged → \r was swallowed → resend
      _ensureSubmitted(before, attempt + 1);
    });
  }

  // Auto-submit timing/backstop knobs. _submitDelay: human-scale gap after the
  // paste before the first Enter. The backstop re-checks after _submitCheckDelay,
  // up to _submitRetries times, over the bottom _submitCheckLines lines (the
  // input-box region). Only gates programmatic delivery, never typing.
  static const Duration _submitDelay = Duration(milliseconds: 300);
  static const Duration _submitCheckDelay = Duration(milliseconds: 350);
  static const int _submitRetries = 2;
  static const int _submitCheckLines = 8;

  // resizeFromRemote lets a connected phone size the PTY to its viewport.
  void resizeFromRemote(int rows, int cols) {
    if (rows > 0 && cols > 0) _pty?.resize(rows, cols);
  }

  // restoreLocalSize: the last phone detached — resize the PTY back to the
  // desktop's own viewport so the Mac returns to full width. Call right after
  // clearing remoteSink (which hands size authority back to local resizes).
  // terminal.viewWidth/Height track the Mac's xterm fit (decoupled from the
  // PTY), so they hold the desktop's current size even after the phone shrank it.
  void restoreLocalSize() {
    final r = terminal.viewHeight, c = terminal.viewWidth;
    if (r > 0 && c > 0) _pty?.resize(r, c);
  }

  void dispose() {
    _disposed = true; // stops the codex id-capture poll
    _belTimer?.cancel();
    controller.dispose();
    _pty?.kill();
  }
}

// TerminalPane renders one session and starts it on first build.
class TerminalPane extends StatefulWidget {
  final TerminalSession session;
  // Forwarding targets for the in-terminal "发送到会话" menu, grouped: [same]
  // (same project) inline, [others] (other projects) under a 其他会话 submenu.
  // Both empty hides the entries.
  final List<SendTarget> same;
  final List<SendTarget> others;
  // onSendToPeer(fromId, targetId, text): route the selection into a sibling
  // session's input box (fill, no submit). Null hides the menu entries.
  final void Function(String fromId, String targetId, String text)?
  onSendToPeer;
  // onInterjectToPeer(fromId, targetId, text): same targets as onSendToPeer but
  // submit:true — interjects into a busy peer's running turn (via its bus hook),
  // or runs the selection immediately when the peer is idle. Null hides it.
  final void Function(String fromId, String targetId, String text)?
  onInterjectToPeer;
  // onSendToOnline(text): hand the selection to the host's "发送到在线用户" flow
  // (pick a remote user + their session). Null hides that menu entry.
  final void Function(String text)? onSendToOnline;
  const TerminalPane({
    super.key,
    required this.session,
    this.same = const [],
    this.others = const [],
    this.onSendToPeer,
    this.onInterjectToPeer,
    this.onSendToOnline,
  });

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  // The selection/copy controller now lives on the session (so the host can
  // read the current selection to forward it); the pane just references it. Its
  // lifecycle is the session's, so the pane doesn't dispose it.
  TerminalController get _controller => widget.session.controller;

  Terminal get _terminal => widget.session.terminal;

  @override
  void initState() {
    super.initState();
    widget.session.start();
  }

  void _copy() {
    final sel = _controller.selection;
    if (sel == null) return;
    Clipboard.setData(ClipboardData(text: _terminal.buffer.getText(sel)));
    _controller.clearSelection();
    snack(context, '已复制');
  }

  // _paste is the single paste entry (right-click 粘贴 and Cmd/Ctrl+V, both
  // routed here). Text wins; if the clipboard holds no text but an image (e.g. a
  // screenshot), it's written to a temp PNG and the file path is pasted instead
  // — claude/codex read the image from that path. Flutter's Clipboard is
  // text-only, so the image goes through `pasteboard`.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _terminal.paste(text);
      _controller.clearSelection();
      return;
    }
    await _pasteImage();
  }

  // _pasteImage drops a clipboard image to a temp PNG and pastes its path so the
  // agent can read it. No-op when the clipboard has no image.
  Future<void> _pasteImage() async {
    Uint8List? bytes;
    try {
      bytes = await Pasteboard.image;
    } catch (_) {}
    if (bytes == null || bytes.isEmpty) return;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/cc-paste');
      await dir.create(recursive: true);
      final path =
          '${dir.path}/img-${DateTime.now().millisecondsSinceEpoch}.png';
      await File(path).writeAsBytes(bytes, flush: true);
      _terminal.paste(path);
      if (mounted) snack(context, '已粘贴图片路径(回车让 agent 读取)');
    } catch (_) {
      if (mounted) snack(context, '粘贴图片失败');
    }
  }

  // Mirrors xterm's SelectAllTextIntent so the menu item matches Cmd/Ctrl+A.
  void _selectAll() {
    final b = _terminal.buffer;
    _controller.setSelection(
      b.createAnchor(0, b.height - _terminal.viewHeight),
      b.createAnchor(_terminal.viewWidth, b.height - 1),
      mode: SelectionMode.line,
    );
  }

  // _sendSelectionTo fills the current selection into peer [targetId]'s input
  // (no submit). _interjectSelectionTo routes it submit:true instead, so a busy
  // peer's running turn gets it via its bus hook (or it runs immediately when
  // the peer is idle). Both no-op without a selection or the matching callback.
  void _sendSelectionTo(String targetId) =>
      _forwardSelectionTo(targetId, widget.onSendToPeer, '已发送');
  void _interjectSelectionTo(String targetId) =>
      _forwardSelectionTo(targetId, widget.onInterjectToPeer, '已插话');

  void _forwardSelectionTo(
    String targetId,
    void Function(String fromId, String targetId, String text)? cb,
    String done,
  ) {
    final sel = _controller.selection;
    if (sel == null || cb == null) return;
    cb(widget.session.id, targetId, _terminal.buffer.getText(sel));
    _controller.clearSelection();
    final label = _peerLabel(targetId);
    snack(context, label != null ? '$done到 $label' : done);
  }

  // _peerLabel resolves a forwarding target id to its display label, or null.
  String? _peerLabel(String targetId) {
    for (final t in [...widget.same, ...widget.others]) {
      if (t.id == targetId) return t.label;
    }
    return null;
  }

  // _sendSelectionToOnline hands the current selection to the host's
  // "发送到在线用户" picker (a remote user + their session). No-op without one.
  void _sendSelectionToOnline() {
    final sel = _controller.selection;
    final cb = widget.onSendToOnline;
    if (sel == null || cb == null) return;
    cb(_terminal.buffer.getText(sel));
    _controller.clearSelection();
  }

  Future<void> _showMenu(Offset globalPos) async {
    final hasSelection = _controller.selection != null;
    final hasTargets = widget.same.isNotEmpty || widget.others.isNotEmpty;
    final canSend = widget.onSendToPeer != null && hasTargets;
    final canInterject = widget.onInterjectToPeer != null && hasTargets;
    // Send targets only when there's a selection to send (else just the editing
    // rows). 复制/粘贴/全选 sit above the send section via extraTop; 发送到在线
    // 用户 sits below via extraBottom (also selection-gated).
    final v = await showGroupedSendMenu(
      context,
      globalPos,
      same: hasSelection && canSend ? widget.same : const [],
      others: hasSelection && canSend ? widget.others : const [],
      extraTop: [
        ccMenuItem(
          value: 'copy',
          icon: Icons.content_copy_rounded,
          label: '复制',
          enabled: hasSelection,
        ),
        ccMenuItem(
          value: 'paste',
          icon: Icons.content_paste_rounded,
          label: '粘贴',
        ),
        ccMenuItem(
          value: 'selectAll',
          icon: Icons.select_all_rounded,
          label: '全选',
        ),
      ],
      extraBottom: [
        if (hasSelection && canInterject)
          ccMenuItem(
            value: 'interject',
            icon: Icons.bolt_rounded,
            label: '插话到会话…',
          ),
        if (hasSelection && widget.onSendToOnline != null)
          ccMenuItem(
            value: 'online',
            icon: Icons.cloud_upload_rounded,
            label: '发送到在线用户…',
          ),
      ],
    );
    if (v == null || !mounted) return;
    switch (v) {
      case 'copy':
        _copy();
      case 'paste':
        _paste();
      case 'selectAll':
        _selectAll();
      case 'online':
        _sendSelectionToOnline();
      case 'interject':
        // Flutter showMenu has no submenu: reopen a target picker, then route
        // the selection submit:true so a busy peer gets it mid-turn via its hook.
        final pick = await showPeerPicker(
          context,
          globalPos,
          [...widget.same, ...widget.others],
          'interject',
          icon: Icons.bolt_rounded,
          label: (t) => '插话到「${t.label}」',
        );
        if (pick != null && mounted && pick.startsWith('interject:')) {
          _interjectSelectionTo(pick.substring('interject:'.length));
        }
      default:
        if (v.startsWith('send:')) _sendSelectionTo(v.substring('send:'.length));
    }
  }

  // _onKeyEvent intercepts the paste shortcut (Cmd+V on macOS, Ctrl+V elsewhere —
  // matching xterm's defaultTerminalShortcuts) so paste routes through our
  // image-aware _paste() instead of xterm's text-only handler. Returning handled
  // short-circuits xterm's shortcut manager (see TerminalView._handleKeyEvent);
  // every other key falls through unchanged.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final pasteMod = Platform.isMacOS
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;
    if (pasteMod && event.logicalKey == LogicalKeyboardKey.keyV) {
      unawaited(_paste());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return TerminalView(
      _terminal,
      controller: _controller,
      // All platforms use xterm's IME TextInput path so input-method (Chinese
      // etc.) composition reaches the terminal — not just raw ASCII keys. The
      // connection is made to attach reliably on Windows by the open-on-focus
      // patch in third_party/xterm/.../custom_text_edit.dart.
      onSecondaryTapDown: (details, _) => _showMenu(details.globalPosition),
      onKeyEvent: _onKeyEvent,
      theme: ccTerminalTheme,
      textStyle: const TerminalStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
      backgroundOpacity: 1,
      padding: const EdgeInsets.all(10),
    );
  }
}

// ccTerminalTheme moved to ../terminal_theme.dart (xterm-only) so the web client
// can reuse it without pulling terminal_pane.dart's flutter_pty/dart:io deps.
