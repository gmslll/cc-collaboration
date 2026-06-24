import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../local/local_bus.dart';
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

  // onTermsChanged fires after the session list changes (add/close/rename/
  // restore) so a remote host can re-broadcast the session list to phones.
  void Function()? onTermsChanged;

  // onTermAdded fires only when a NEW session is spawned via addTerm (not on
  // restore) — the workspace uses it to surface the bottom terminal panel so a
  // freshly launched agent is visible even if the bottom was showing Git.
  void Function()? onTermAdded;

  void addTerm(String workdir, String command) {
    setState(() {
      terms.add(TerminalSession(workdir, command));
      activeTerm = terms.length - 1;
    });
    onTermsChanged?.call();
    onTermAdded?.call();
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
    onTermsChanged?.call();
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
      onTermsChanged?.call();
    } catch (_) {}
  }

  Future<String> _persistPath(String key) async =>
      '${(await getApplicationSupportDirectory()).path}/$key.json';

  // persistTerms re-saves the session list (e.g. after a rename). No-op unless
  // persistKey is set.
  void persistTerms() {
    onTermsChanged?.call();
    unawaited(_save());
  }

  Future<void> _save() async {
    final key = persistKey;
    if (key == null) return;
    try {
      final f = File(await _persistPath(key));
      await f.writeAsString(
        jsonEncode(
          terms
              .map(
                (s) => {
                  'workdir': s.workdir,
                  'command': s.command,
                  if (s.name?.isNotEmpty ?? false) 'name': s.name,
                },
              )
              .toList(),
        ),
      );
    } catch (_) {}
  }

  // sendToTerminal is the "发送到终端" wiring for HandoffDetailView — null when
  // there's no active session (so the button hides).
  void Function(String)? get sendToTerminal =>
      terms.isEmpty ? null : (t) => terms[activeTerm].sendText(t);

  // --- local point-to-point bus: session A → session B ---------------------
  //
  // The single entry point both the right-click "发送到终端" menu and the
  // `cc-handoff msg` CLI (via LocalBus) funnel through. All it does is resolve a
  // target and sendText into its PTY — but it owns the addressing rules so the
  // UI and the agent path stay consistent.

  // peersExcluding returns the other live sessions (forwarding targets for
  // [selfId]). Used to build the context-menu list and `msg list`.
  List<TerminalSession> peersExcluding(String selfId) =>
      terms.where((s) => s.id != selfId).toList();

  // localBusRegistry is the sessions.json payload LocalBus publishes so the CLI
  // can resolve a target by id or name.
  List<Map<String, dynamic>> localBusRegistry() => [
    for (final s in terms)
      {
        'id': s.id,
        'label': s.label,
        if (s.name?.isNotEmpty ?? false) 'name': s.name,
        'workdir': s.workdir,
        if (s.pid != null) 'pid': s.pid,
      },
  ];

  // deliverLocalMessage routes one message into a target session's PTY. Returns
  // null on success, or a human-readable error (unknown/ambiguous target,
  // self-send) that LocalBus writes back so `msg send` exits non-zero. Target
  // resolution: exact id first, else a unique label match.
  String? deliverLocalMessage(LocalMsg m) {
    final to = m.to.trim();
    if (to.isEmpty) return '缺少目标会话';
    TerminalSession? target;
    final byId = terms.where((s) => s.id == to);
    if (byId.isNotEmpty) {
      target = byId.first;
    } else {
      final byLabel = terms.where((s) => s.label == to).toList();
      if (byLabel.length > 1) {
        return '目标名「$to」对应多个会话,请改用其 id(如 ${byLabel.first.id})';
      }
      if (byLabel.length == 1) target = byLabel.first;
    }
    if (target == null) return '找不到目标会话「$to」';
    if (target.id == m.from) return '不能发给自己';
    final fromLabel = terms.where((s) => s.id == m.from).map((s) => s.label);
    final tag = fromLabel.isNotEmpty
        ? fromLabel.first
        : (m.from.isEmpty ? '?' : m.from);
    final body = '[来自 $tag] ${m.body}';
    // Deliver as one bracketed-paste block (ESC[200~ … ESC[201~) so the
    // receiving TUI inserts it atomically — no per-newline submit, no control-
    // char interpretation — even if it's mid-stream or the body is multi-line.
    // A separate CR submits the whole block only when requested.
    target.sendText('\x1b[200~$body\x1b[201~');
    if (m.submit) target.sendText('\r');
    return null;
  }

  // _sendToPeer is the menu callback: human forwards fill the target's input
  // (submit:false) so you can review before the receiving agent runs it.
  void _sendToPeer(String fromId, String targetId, String text) =>
      deliverLocalMessage(LocalMsg(fromId, targetId, text, false));

  Widget terminalDeck({VoidCallback? onCollapse}) => TerminalDeck(
    terms: terms,
    active: activeTerm,
    onSwitch: (i) => setState(() => activeTerm = i),
    onClose: closeTerm,
    onCollapse: onCollapse,
    peersFor: peersExcluding,
    onSendToPeer: _sendToPeer,
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
            .map(
              (s) => TerminalPane(
                key: ValueKey(s),
                session: s,
                peers: peersExcluding(s.id),
                onSendToPeer: _sendToPeer,
              ),
            )
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
  // Local point-to-point forwarding wiring (see TerminalHost); null/absent
  // hides the "发送到终端" context-menu entries.
  final List<TerminalSession> Function(String selfId)? peersFor;
  final void Function(String fromId, String targetId, String text)?
  onSendToPeer;
  const TerminalDeck({
    super.key,
    required this.terms,
    required this.active,
    required this.onSwitch,
    required this.onClose,
    this.onCollapse,
    this.peersFor,
    this.onSendToPeer,
  });

  @override
  Widget build(BuildContext context) {
    if (terms.isEmpty) return const SizedBox.shrink();
    final idx = active.clamp(0, terms.length - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TerminalTabBar(
          terms: terms,
          active: active,
          onSwitch: onSwitch,
          onClose: onClose,
          trailing: onCollapse != null
              ? IconButton(
                  icon: const Icon(Icons.chevron_right_rounded, size: 16),
                  tooltip: '收起终端',
                  onPressed: onCollapse,
                )
              : null,
        ),
        Expanded(
          child: ColoredBox(
            color: CcColors.bg,
            child: IndexedStack(
              index: idx,
              children: terms
                  .map(
                    (s) => TerminalPane(
                      key: ValueKey(s),
                      session: s,
                      peers: peersFor?.call(s.id) ?? const [],
                      onSendToPeer: onSendToPeer,
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
      ],
    );
  }
}

// TerminalTabBar is the horizontal session-tab strip (one tab per terminal,
// active underlined, × to close). Reused by TerminalDeck (inbox) and the
// workspace cockpit's top bar. Optional [leading]/[trailing] for chrome.
class TerminalTabBar extends StatelessWidget {
  final List<TerminalSession> terms;
  final int active;
  final ValueChanged<int> onSwitch;
  final ValueChanged<int> onClose;
  final Widget? leading;
  final Widget? trailing;
  const TerminalTabBar({
    super.key,
    required this.terms,
    required this.active,
    required this.onSwitch,
    required this.onClose,
    this.leading,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final idx = terms.isEmpty ? 0 : active.clamp(0, terms.length - 1);
    return Container(
      color: CcColors.panel,
      height: 38,
      child: Row(
        children: [
          ?leading,
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
                          color: isActive
                              ? CcColors.accent
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.terminal_rounded,
                          size: 14,
                          color: isActive ? CcColors.accent : CcColors.muted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          terms[i].label,
                          style: TextStyle(
                            fontSize: 12,
                            color: isActive ? CcColors.text : CcColors.muted,
                          ),
                        ),
                        const SizedBox(width: 6),
                        InkWell(
                          onTap: () => onClose(i),
                          child: const Icon(
                            Icons.close_rounded,
                            size: 14,
                            color: CcColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
