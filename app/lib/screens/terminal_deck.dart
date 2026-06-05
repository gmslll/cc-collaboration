import 'package:flutter/material.dart';

import '../theme.dart';
import 'terminal_pane.dart';

// TerminalHost owns the terminal-session list + active index + lifecycle, shared
// by the inbox cockpit and the workspace cockpit (both add sessions on pickup /
// agent launch). Mix into a State and render terminalDeck().
mixin TerminalHost<T extends StatefulWidget> on State<T> {
  final List<TerminalSession> terms = [];
  int activeTerm = 0;

  void addTerm(String workdir, String command) {
    setState(() {
      terms.add(TerminalSession(workdir, command));
      activeTerm = terms.length - 1;
    });
  }

  void closeTerm(int i) {
    terms[i].dispose();
    setState(() {
      terms.removeAt(i);
      if (activeTerm >= terms.length) {
        activeTerm = terms.isEmpty ? 0 : terms.length - 1;
      }
    });
  }

  void disposeTerms() {
    for (final s in terms) {
      s.dispose();
    }
  }

  // sendToTerminal is the "发送到终端" wiring for HandoffDetailView — null when
  // there's no active session (so the button hides).
  void Function(String)? get sendToTerminal =>
      terms.isEmpty ? null : (t) => terms[activeTerm].sendText(t);

  Widget terminalDeck() => TerminalDeck(
        terms: terms,
        active: activeTerm,
        onSwitch: (i) => setState(() => activeTerm = i),
        onClose: closeTerm,
      );
}

// TerminalDeck renders a row of session tabs + the active terminal. The host
// owns the session list + active index (so both the inbox cockpit and the
// workspace cockpit can add sessions on pickup / agent launch).
class TerminalDeck extends StatelessWidget {
  final List<TerminalSession> terms;
  final int active;
  final ValueChanged<int> onSwitch;
  final ValueChanged<int> onClose;
  const TerminalDeck({
    super.key,
    required this.terms,
    required this.active,
    required this.onSwitch,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    if (terms.isEmpty) return const SizedBox.shrink();
    final idx = active.clamp(0, terms.length - 1);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        color: CcColors.panel,
        height: 38,
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
                  Text(terms[i].title,
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
