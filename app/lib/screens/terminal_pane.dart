import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

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
      environment: const {'TERM': 'xterm-256color', 'COLORTERM': 'truecolor'},
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

  void sendText(String s) => _pty?.write(const Utf8Encoder().convert(s));

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

  void dispose() => _pty?.kill();
}

// TerminalPane renders one session and starts it on first build.
class TerminalPane extends StatefulWidget {
  final TerminalSession session;
  const TerminalPane({super.key, required this.session});

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  // Owned controller so we can read the selection for the copy menu (xterm's
  // default copy/paste keyboard shortcuts also operate on it).
  final TerminalController _controller = TerminalController();

  Terminal get _terminal => widget.session.terminal;

  @override
  void initState() {
    super.initState();
    widget.session.start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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

  void _showMenu(Offset globalPos) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu<void>(
      context: context,
      position: RelativeRect.fromRect(
        globalPos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          enabled: _controller.selection != null,
          onTap: _copy,
          child: const Text('复制'),
        ),
        PopupMenuItem(onTap: _paste, child: const Text('粘贴')),
        PopupMenuItem(onTap: _selectAll, child: const Text('全选')),
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
