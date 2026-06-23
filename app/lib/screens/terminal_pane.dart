import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

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

  TerminalSession(this.workdir, this.command)
    : title = workdir.split('/').where((s) => s.isNotEmpty).isNotEmpty
          ? workdir.split('/').lastWhere((s) => s.isNotEmpty)
          : workdir;

  // label is what the UI shows: the user-given name, else the derived title.
  String get label => (name != null && name!.isNotEmpty) ? name! : title;

  void start() {
    if (_started) return;
    _started = true;
    final shell = Platform.environment['SHELL'] ?? '/bin/sh';
    final pty = Pty.start(
      shell,
      arguments: ['-i', '-c', command],
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
          remoteSink?.call(chunk);
        });
    pty.exitCode.then(
      (code) => terminal.write('\r\n\x1b[90m[已退出: $code]\x1b[0m\r\n'),
    );
    terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
    terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
  }

  void sendText(String s) => _pty?.write(const Utf8Encoder().convert(s));

  // resizeFromRemote lets a connected phone size the PTY to its viewport.
  void resizeFromRemote(int rows, int cols) {
    if (rows > 0 && cols > 0) _pty?.resize(rows, cols);
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
  @override
  void initState() {
    super.initState();
    widget.session.start();
  }

  @override
  Widget build(BuildContext context) {
    return TerminalView(
      widget.session.terminal,
      theme: _ccTerminalTheme,
      textStyle: const TerminalStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
      backgroundOpacity: 1,
      padding: const EdgeInsets.all(10),
    );
  }
}

// Terminal palette aligned with the app: indigo cursor, our bg/fg, and semantic
// red/green/amber ANSI hues (VS Code-derived) so agent TUIs look cohesive.
const _ccTerminalTheme = TerminalTheme(
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
