import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../local/cli.dart';
import '../local/local_bus.dart';
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
  final Terminal terminal = Terminal(maxLines: 10000);
  // The selection/copy controller lives on the session (not the pane) so the
  // host can read the current selection — e.g. to forward it to another
  // session from the tree's "发送选区到…" menu, which a full-screen TUI can't
  // intercept the way it grabs an in-terminal right-click.
  final TerminalController controller = TerminalController();
  Pty? _pty;
  bool _started = false;

  // remoteSink, when set, also receives this terminal's (utf8-decoded) PTY
  // output so a remote phone client can mirror it. Null when nobody's watching.
  void Function(String chunk)? remoteSink;

  // Rolling buffer of recent raw PTY output so a phone connecting mid-session
  // can replay it and see the current screen / scrollback instead of a blank
  // terminal until the next redraw. Kept always (even with no watcher) and
  // bounded by char count; whole chunks go in/out to avoid splitting an escape
  // sequence mid-stream.
  final Queue<String> _backlog = Queue<String>();
  int _backlogLen = 0;
  static const int _backlogCap = 256 * 1024;

  void _appendBacklog(String chunk) {
    _backlog.add(chunk);
    _backlogLen += chunk.length;
    while (_backlogLen > _backlogCap && _backlog.length > 1) {
      _backlogLen -= _backlog.removeFirst().length;
    }
  }

  String get backlog => _backlog.join();

  TerminalSession(this.workdir, this.command)
    : title = workdir.split('/').where((s) => s.isNotEmpty).isNotEmpty
          ? workdir.split('/').lastWhere((s) => s.isNotEmpty)
          : workdir {
    // Fix xterm 4.0.0's broken wheel reporting so scroll reaches full-screen
    // agent TUIs (claude/codex), which scroll fine in real terminals.
    terminal.mouseHandler = const WheelMouseHandler();
  }

  // label is what the UI shows: the user-given name, else the derived title.
  String get label => (name != null && name!.isNotEmpty) ? name! : title;

  // selectedText is the current selection's text, or null when nothing is
  // selected. The host reads it to forward a selection to another session.
  String? get selectedText {
    final sel = controller.selection;
    if (sel == null) return null;
    final t = terminal.buffer.getText(sel);
    return t.isEmpty ? null : t;
  }

  void start() {
    if (_started) return;
    _started = true;
    final shell = Platform.environment['SHELL'] ?? '/bin/sh';
    // Empty command = a plain interactive login shell (typeable + scrollable);
    // otherwise run the agent command and let the shell exit when it does.
    final args = command.isEmpty ? const ['-i', '-l'] : ['-i', '-c', command];
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
        });
    pty.exitCode.then(
      (code) => terminal.write('\r\n\x1b[90m[已退出: $code]\x1b[0m\r\n'),
    );
    terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
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

  void sendText(String s) => _pty?.write(const Utf8Encoder().convert(s));

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
    controller.dispose();
    _pty?.kill();
  }
}

// TerminalPane renders one session and starts it on first build.
class TerminalPane extends StatefulWidget {
  final TerminalSession session;
  // Other live sessions this terminal can forward its selection to (the local
  // point-to-point "发送到终端" menu). Empty hides the menu entries.
  final List<TerminalSession> peers;
  // onSendToPeer(fromId, targetId, text): route the selection into a sibling
  // session's input. Null hides the menu entries.
  final void Function(String fromId, String targetId, String text)?
  onSendToPeer;
  const TerminalPane({
    super.key,
    required this.session,
    this.peers = const [],
    this.onSendToPeer,
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

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) _terminal.paste(text);
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
  void _sendSelectionTo(String targetId, String peerLabel) {
    final sel = _controller.selection;
    final cb = widget.onSendToPeer;
    if (sel == null || cb == null) return;
    cb(widget.session.id, targetId, _terminal.buffer.getText(sel));
    _controller.clearSelection();
    snack(context, '已发送到 $peerLabel');
  }

  void _showMenu(Offset globalPos) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final hasSelection = _controller.selection != null;
    showMenu<void>(
      context: context,
      position: RelativeRect.fromRect(
        globalPos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          enabled: hasSelection,
          onTap: _copy,
          child: const Text('复制'),
        ),
        PopupMenuItem(onTap: _paste, child: const Text('粘贴')),
        PopupMenuItem(onTap: _selectAll, child: const Text('全选')),
        // 发送到终端: one entry per other live session — forwards the selection
        // into that session's input so a sibling agent can read it.
        if (widget.onSendToPeer != null && widget.peers.isNotEmpty) ...[
          const PopupMenuDivider(),
          for (final p in widget.peers)
            PopupMenuItem(
              enabled: hasSelection,
              onTap: () => _sendSelectionTo(p.id, p.label),
              child: Text('发送选区 → ${p.label}'),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return TerminalView(
      _terminal,
      controller: _controller,
      onSecondaryTapDown: (details, _) => _showMenu(details.globalPosition),
      theme: ccTerminalTheme,
      textStyle: const TerminalStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
      backgroundOpacity: 1,
      padding: const EdgeInsets.all(10),
    );
  }
}

// Terminal palette aligned with the app: indigo cursor, our bg/fg, and semantic
// red/green/amber ANSI hues (VS Code-derived) so agent TUIs look cohesive.
const ccTerminalTheme = TerminalTheme(
  cursor: Color(0xFF818CF8),
  selection: Color(0x55818CF8),
  foreground: Color(0xFFE6EAF2),
  background: Color(0xFF0A0E1A),
  black: Color(0xFF1E2536),
  red: Color(0xFFF87171),
  green: Color(0xFF34D399),
  yellow: Color(0xFFFBBF24),
  blue: Color(0xFF60A5FA),
  magenta: Color(0xFFC084FC),
  cyan: Color(0xFF22D3EE),
  white: Color(0xFFE5E5E5),
  brightBlack: Color(0xFF5E6A82),
  brightRed: Color(0xFFFCA5A5),
  brightGreen: Color(0xFF6EE7B7),
  brightYellow: Color(0xFFFDE68A),
  brightBlue: Color(0xFF93C5FD),
  brightMagenta: Color(0xFFD8B4FE),
  brightCyan: Color(0xFF67E8F9),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: Color(0xFF31FF26),
  searchHitForeground: Color(0xFF000000),
);
