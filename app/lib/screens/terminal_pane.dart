import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

// TerminalPane runs an agent (or shell) command in a PTY and renders it with
// xterm.dart. The command is the `agent_cmd` from `cc-handoff pickup --json`
// (e.g. `cd '<worktree>' && claude`), run via $SHELL -i -c so rc files load.
class TerminalPane extends StatefulWidget {
  final String workdir;
  final String command;
  const TerminalPane({super.key, required this.workdir, required this.command});

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  final terminal = Terminal(maxLines: 10000);
  Pty? _pty;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    final shell = Platform.environment['SHELL'] ?? '/bin/sh';
    final pty = Pty.start(
      shell,
      arguments: ['-i', '-c', widget.command],
      workingDirectory: widget.workdir,
      rows: terminal.viewHeight,
      columns: terminal.viewWidth,
    );
    _pty = pty;

    pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(terminal.write);
    pty.exitCode.then((code) {
      if (mounted) terminal.write('\r\n\x1b[90m[进程已退出: $code]\x1b[0m\r\n');
    });

    terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
    terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
  }

  @override
  void dispose() {
    _pty?.kill();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TerminalView(
      terminal,
      backgroundOpacity: 1,
      padding: const EdgeInsets.all(8),
    );
  }
}
