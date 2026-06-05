import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

// TerminalSession owns a PTY + xterm Terminal model. The cockpit keeps a list of
// these (one per pickup/worktree) for multi-session tabs and can sendText into
// the active one (e.g. paste the materialized prompt).
class TerminalSession {
  final String workdir;
  final String command;
  final String title;
  final Terminal terminal = Terminal(maxLines: 10000);
  Pty? _pty;
  bool _started = false;

  TerminalSession(this.workdir, this.command)
      : title = workdir.split('/').where((s) => s.isNotEmpty).isNotEmpty
            ? workdir.split('/').lastWhere((s) => s.isNotEmpty)
            : workdir;

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
        .listen(terminal.write);
    pty.exitCode
        .then((code) => terminal.write('\r\n\x1b[90m[已退出: $code]\x1b[0m\r\n'));
    terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
    terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
  }

  void sendText(String s) => _pty?.write(const Utf8Encoder().convert(s));

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
      backgroundOpacity: 1,
      padding: const EdgeInsets.all(8),
    );
  }
}
