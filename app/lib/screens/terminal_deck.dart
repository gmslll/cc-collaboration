import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../theme.dart';
import 'terminal_pane.dart';

// TerminalHost owns the terminal-session list + active index + lifecycle, shared
// by the inbox cockpit and the workspace cockpit (both add sessions on pickup /
// agent launch). Mix into a State and render terminalDeck().
//
// Override [persistKey] to persist the open sessions (workdir + command) to disk
// and restore them next launch via restoreTerms() — used by the workspace
// cockpit so agent sessions reopen automatically.
mixin TerminalHost<T extends StatefulWidget> on State<T> {
  final List<TerminalSession> terms = [];
  int activeTerm = 0;

  String? get persistKey => null;

  void addTerm(String workdir, String command) {
    setState(() {
      terms.add(TerminalSession(workdir, command));
      activeTerm = terms.length - 1;
    });
    unawaited(_save());
  }

  void closeTerm(int i) {
    terms[i].dispose();
    setState(() {
      terms.removeAt(i);
      if (activeTerm >= terms.length) {
        activeTerm = terms.isEmpty ? 0 : terms.length - 1;
      }
    });
    unawaited(_save());
  }

  void disposeTerms() {
    for (final s in terms) {
      s.dispose();
    }
  }

  // restoreTerms reopens persisted sessions (skipping any whose worktree dir is
  // gone). Call from the host's initState. No-op unless persistKey is set.
  Future<void> restoreTerms() async {
    final key = persistKey;
    if (key == null) return;
    try {
      final f = File(await _persistPath(key));
      if (!await f.exists()) return;
      final data = jsonDecode(await f.readAsString());
      if (data is! List) return;
      final restored = <TerminalSession>[];
      for (final e in data) {
        if (e is! Map) continue;
        final wd = (e['workdir'] ?? '').toString();
        final cmd = (e['command'] ?? '').toString();
        if (wd.isEmpty || cmd.isEmpty || !Directory(wd).existsSync()) continue;
        final ts = TerminalSession(wd, cmd);
        final nm = (e['name'] ?? '').toString();
        if (nm.isNotEmpty) ts.name = nm;
        restored.add(ts);
      }
      if (restored.isEmpty || !mounted) return;
      setState(() {
        terms.addAll(restored);
        activeTerm = 0;
      });
    } catch (_) {}
  }

  Future<String> _persistPath(String key) async =>
      '${(await getApplicationSupportDirectory()).path}/$key.json';

  // persistTerms re-saves the session list (e.g. after a rename). No-op unless
  // persistKey is set.
  void persistTerms() => unawaited(_save());

  Future<void> _save() async {
    final key = persistKey;
    if (key == null) return;
    try {
      final f = File(await _persistPath(key));
      await f.writeAsString(jsonEncode(terms
          .map((s) => {
                'workdir': s.workdir,
                'command': s.command,
                if (s.name?.isNotEmpty ?? false) 'name': s.name,
              })
          .toList()));
    } catch (_) {}
  }

  // sendToTerminal is the "发送到终端" wiring for HandoffDetailView — null when
  // there's no active session (so the button hides).
  void Function(String)? get sendToTerminal =>
      terms.isEmpty ? null : (t) => terms[activeTerm].sendText(t);

  Widget terminalDeck({VoidCallback? onCollapse}) => TerminalDeck(
        terms: terms,
        active: activeTerm,
        onSwitch: (i) => setState(() => activeTerm = i),
        onClose: closeTerm,
        onCollapse: onCollapse,
      );

  // terminalBody is just the active terminal (no tab bar) — for hosts that put
  // the session list elsewhere (the workspace tree shows sessions under their
  // project). All sessions stay alive via IndexedStack.
  Widget terminalBody() {
    if (terms.isEmpty) return const SizedBox.shrink();
    final idx = activeTerm.clamp(0, terms.length - 1);
    return ColoredBox(
      color: CcColors.bg,
      child: IndexedStack(
        index: idx,
        children: terms
            .map((s) => TerminalPane(key: ValueKey(s), session: s))
            .toList(),
      ),
    );
  }
}

// TerminalDeck renders a row of session tabs + the active terminal. The host
// owns the session list + active index (so both the inbox cockpit and the
// workspace cockpit can add sessions on pickup / agent launch).
class TerminalDeck extends StatelessWidget {
  final List<TerminalSession> terms;
  final int active;
  final ValueChanged<int> onSwitch;
  final ValueChanged<int> onClose;
  final VoidCallback? onCollapse;
  const TerminalDeck({
    super.key,
    required this.terms,
    required this.active,
    required this.onSwitch,
    required this.onClose,
    this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    if (terms.isEmpty) return const SizedBox.shrink();
    final idx = active.clamp(0, terms.length - 1);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        color: CcColors.panel,
        height: 38,
        child: Row(children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: terms.length,
              itemBuilder: (_, i) {
            final isActive = i == idx;
            return InkWell(
              onTap: () => onSwitch(i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  border: Border(
                      bottom: BorderSide(
                          color: isActive ? CcColors.accent : Colors.transparent,
                          width: 2)),
                ),
                child: Row(children: [
                  Icon(Icons.terminal,
                      size: 14,
                      color: isActive ? CcColors.accent : CcColors.muted),
                  const SizedBox(width: 6),
                  Text(terms[i].label,
                      style: TextStyle(
                          fontSize: 12,
                          color: isActive ? CcColors.text : CcColors.muted)),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => onClose(i),
                    child:
                        const Icon(Icons.close, size: 14, color: CcColors.muted),
                  ),
                ]),
              ),
            );
              },
            ),
          ),
          if (onCollapse != null)
            IconButton(
                icon: const Icon(Icons.chevron_right, size: 16),
                tooltip: '收起终端',
                onPressed: onCollapse),
        ]),
      ),
      Expanded(
        child: ColoredBox(
          color: CcColors.bg,
          child: IndexedStack(
            index: idx,
            children: terms
                .map((s) => TerminalPane(key: ValueKey(s), session: s))
                .toList(),
          ),
        ),
      ),
    ]);
  }
}
