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

import '../local/cli.dart';
import '../local/local_bus.dart';
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
  final String? agentSessionId;
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
  Timer? _belTimer;
  bool _belArmed = false; // a bell rang; waiting for output to settle to confirm
  bool _sawInput = false; // user has typed/sent into this session at least once
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
    if (agent == 'claude') {
      if (!resume) {
        return agentSessionId == null
            ? '${prefix}claude'
            : '${prefix}claude --session-id $agentSessionId';
      }
      // Reopen: resume the exact id; fall back to most-recent if we never minted
      // one (e.g. a pre-upgrade persisted session).
      return agentSessionId == null
          ? '${prefix}claude --continue'
          : '${prefix}claude --resume $agentSessionId';
    }
    // codex: bare on first launch, newest-in-cwd on reopen.
    return resume ? '${prefix}codex resume --last' : '${prefix}codex';
  }

  void start() {
    if (_started) return;
    _started = true;
    final shell = Platform.environment['SHELL'] ?? '/bin/sh';
    // Empty command = a plain interactive login shell (typeable + scrollable);
    // otherwise run the (resolved) agent command and let the shell exit with it.
    final cmd = _resolvedCommand();
    final args = cmd.isEmpty ? const ['-i', '-l'] : ['-i', '-c', cmd];
    final pty = Pty.start(
      shell,
      arguments: args,
      // Declare a real terminal type so full-screen TUIs (claude/codex) enable
      // mouse reporting → wheel scroll reaches them. A Finder-launched .app may
      // otherwise have no TERM. flutter_pty merges this over Platform.environment.
      // The CC_* vars wire this session into the local message bus: the agent
      // inside calls `"$CC_HANDOFF_BIN" msg send <peer> …` (or bare `cc-handoff`
      // — its dir is prepended to PATH) to reach a sibling session.
      environment: _sessionEnv(),
      workingDirectory: workdir,
      rows: terminal.viewHeight,
      columns: terminal.viewWidth,
    );
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
    pty.exitCode.then(
      (code) => terminal.write('\r\n\x1b[90m[已退出: $code]\x1b[0m\r\n'),
    );
    terminal.onOutput = (data) {
      _sawInput = true; // local keystrokes count as "the user gave it work"
      pty.write(const Utf8Encoder().convert(data));
    };
    // A phone mirroring this session (remoteSink set) owns the PTY size; don't
    // let local (Mac window) resizes fight it — last-writer-wins between the
    // wide Mac and the narrow phone is what garbles the mirror.
    terminal.onResize = (w, h, pw, ph) {
      if (remoteSink == null) pty.resize(h, w);
    };
  }

  int? get pid => _pty?.pid;

  // _sessionEnv builds the PTY environment: the terminal type (so TUIs report
  // mouse) plus the local-bus wiring (CC_SESSION_ID/NAME for identity, CC_BUS_DIR
  // + CC_HANDOFF_BIN for the `msg` CLI). The cc-handoff dir is prepended to PATH
  // so a bundled (non-system) binary is still callable by bare name.
  Map<String, String> _sessionEnv() {
    final bin = Cli.binPath();
    final env = <String, String>{
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
    if (!_sawInput) return;
    onDone?.call(this);
  }

  // pasteText injects [s] as one bracketed-paste block (ESC[200~ … ESC[201~) so
  // a full-screen TUI inserts it atomically — no per-newline submit, no control-
  // char interpretation — even mid-stream. Use this (not sendText) for any
  // programmatically delivered message; sendText stays raw for keystrokes.
  void pasteText(String s, {bool submit = false}) {
    sendText('\x1b[200~$s\x1b[201~');
    if (submit) sendText('\r');
  }

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
  // session's input. Null hides the menu entries.
  final void Function(String fromId, String targetId, String text)?
  onSendToPeer;
  // onSendToOnline(text): hand the selection to the host's "发送到在线用户" flow
  // (pick a remote user + their session). Null hides that menu entry.
  final void Function(String text)? onSendToOnline;
  const TerminalPane({
    super.key,
    required this.session,
    this.same = const [],
    this.others = const [],
    this.onSendToPeer,
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

  // _sendSelectionTo forwards the current selection into peer session [targetId]
  // (the host injects it as input). No-op without a selection.
  void _sendSelectionTo(String targetId) {
    final sel = _controller.selection;
    final cb = widget.onSendToPeer;
    if (sel == null || cb == null) return;
    cb(widget.session.id, targetId, _terminal.buffer.getText(sel));
    _controller.clearSelection();
    String? label;
    for (final t in [...widget.same, ...widget.others]) {
      if (t.id == targetId) {
        label = t.label;
        break;
      }
    }
    snack(context, label != null ? '已发送到 $label' : '已发送');
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
    final canSend =
        widget.onSendToPeer != null &&
        (widget.same.isNotEmpty || widget.others.isNotEmpty);
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
