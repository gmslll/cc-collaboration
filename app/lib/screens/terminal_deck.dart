import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../local/local_bus.dart';
import '../notifications.dart';
import '../theme.dart';
import '../widgets.dart';
import 'terminal_pane.dart';

// agentDoneNotice is the shared "会话完成" copy so the desktop banner and the
// phone push read identically. Returns (title, body); the agent name comes from
// TerminalSession.agentKind (authoritative field, sniff fallback).
(String, String) agentDoneNotice(TerminalSession s) {
  return ('AI 会话完成', '${s.agentKind} · ${s.label} 已就绪，等待输入');
}

// _genUuid returns a random RFC-4122 v4 UUID. Used to mint a fixed session id
// for a freshly launched claude tab (`claude --session-id <uuid>`) so the same
// conversation can be `--resume`d after an app restart. No package dependency —
// 16 secure-random bytes with the version/variant nibbles set.
String _genUuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 1
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

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

  // onAgentDone fires when an agent session finishes a turn (see
  // TerminalSession.onDone). The mixin already pops the desktop banner; a host
  // that can reach further (the workspace, via RemoteHost) sets this to also
  // push the notification to a connected phone.
  void Function(TerminalSession session)? onAgentDone;

  // onSendToOnline forwards a terminal selection to the cross-user
  // "发送到在线用户" picker (a remote user + their session). The workspace sets
  // it; hosts that leave it null hide the menu entry. Threaded into both
  // terminalDeck() and terminalBody().
  void Function(String text)? onSendToOnline;

  // _onSessionDone is wired onto every session's onDone: show the local desktop
  // banner, then let the host fan it out (phone push) via onAgentDone.
  void _onSessionDone(TerminalSession s) {
    final (title, body) = agentDoneNotice(s);
    Notifications.show(title, body);
    onAgentDone?.call(s);
  }

  void addTerm(
    String workdir,
    String command, {
    String agent = '',
    String preLaunch = '',
  }) {
    // Mint a fixed session id for claude up front so it launches with
    // --session-id and can be --resume'd on the next app start. The immediate
    // _save() below persists it. codex can't pre-assign an id (resumes --last).
    final sid = agent == 'claude' ? _genUuid() : null;
    setState(() {
      terms.add(
        TerminalSession(
          workdir,
          command,
          agent: agent,
          preLaunch: preLaunch,
          agentSessionId: sid,
        )..onDone = _onSessionDone,
      );
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

  // Matches a legacy persisted command ("claude"/"codex" or "pre && claude") so
  // restoreTerms can recover agent + preLaunch. Compiled once, not per entry.
  static final RegExp _legacyAgentCmd = RegExp(r'^(?:(.+) && )?(claude|codex)$');

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
      var upgraded = false; // a legacy entry was recovered → rewrite the file
      for (final e in data) {
        if (e is! Map) continue;
        final wd = (e['workdir'] ?? '').toString();
        final cmd = (e['command'] ?? '').toString();
        if (wd.isEmpty || cmd.isEmpty || !Directory(wd).existsSync()) continue;
        var agent = (e['agent'] ?? '').toString();
        var preLaunch = (e['preLaunch'] ?? '').toString();
        final sid = (e['sessionId'] ?? '').toString();
        // Back-compat: pre-upgrade entries from _launch have no 'agent' field and
        // baked preLaunch into command as "pre && claude"/"pre && codex" (or a
        // bare "claude"/"codex"). Recover the agent + prefix only for that exact
        // shape so the tab still resumes (most-recent, since no stored id). Any
        // other command — e.g. a pickup's prompt-injection — keeps agent '' and
        // runs verbatim, exactly as before. (preLaunch is necessarily empty here:
        // it's only ever persisted alongside an 'agent', so a legacy entry has
        // neither.)
        if (agent.isEmpty) {
          final m = _legacyAgentCmd.firstMatch(cmd.trim());
          if (m != null) {
            agent = m.group(2)!;
            preLaunch = m.group(1) ?? '';
            upgraded = true;
          }
        }
        final ts = TerminalSession(
          wd,
          cmd,
          agent: agent,
          preLaunch: preLaunch,
          agentSessionId: sid.isEmpty ? null : sid,
          resume: true,
        )..onDone = _onSessionDone;
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
      // Only rewrite when a legacy entry was actually recovered — steady-state
      // restarts (all entries already structured) skip the redundant write.
      if (upgraded) unawaited(_save());
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
                  // AI-session binding (see TerminalSession) — lets a reopened
                  // tab --resume its exact conversation next launch.
                  if (s.agent.isNotEmpty) 'agent': s.agent,
                  if (s.preLaunch.isNotEmpty) 'preLaunch': s.preLaunch,
                  if (s.agentSessionId != null) 'sessionId': s.agentSessionId,
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

  // sessionById is the shared addressing primitive — find a session by its
  // stable id, or null. Used by local-bus delivery and the tree's send menu.
  TerminalSession? sessionById(String id) {
    for (final s in terms) {
      if (s.id == id) return s;
    }
    return null;
  }

  // peersExcluding returns the other live sessions (forwarding targets for
  // [selfId]). Used to build the context-menu list and `msg list`.
  List<TerminalSession> peersExcluding(String selfId) =>
      terms.where((s) => s.id != selfId).toList();

  // sendGroupsFor splits the forwarding targets for [selfId] into "same" and
  // "others" for the grouped send menu. Default: everything in one group (the
  // inbox cockpit has no project tree). The workspace cockpit overrides it to
  // put same-project sessions first and other-project sessions under 其他会话.
  ({List<SendTarget> same, List<SendTarget> others}) sendGroupsFor(
    String selfId,
  ) => (same: [for (final s in peersExcluding(selfId)) s.asTarget], others: const []);

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

  // _resolveTarget maps a local-bus address (id or label) to a live session.
  // Returns (session, null) on success or (null, error) for an empty, unknown,
  // or ambiguous target. Shared by message delivery and snapshot reads so both
  // resolve addresses identically. Exact id first, else a unique label match.
  (TerminalSession?, String?) _resolveTarget(String to) {
    final t = to.trim();
    if (t.isEmpty) return (null, '缺少目标会话');
    var target = sessionById(t);
    if (target == null) {
      final byLabel = terms.where((s) => s.label == t).toList();
      if (byLabel.length > 1) {
        return (null, '目标名「$t」对应多个会话,请改用其 id(如 ${byLabel.first.id})');
      }
      if (byLabel.length == 1) target = byLabel.first;
    }
    if (target == null) return (null, '找不到目标会话「$t」');
    return (target, null);
  }

  // deliverLocalMessage routes one message into a target session's PTY. Returns
  // null on success, or a human-readable error (unknown/ambiguous target,
  // self-send) that LocalBus writes back so `msg send` exits non-zero.
  String? deliverLocalMessage(LocalMsg m) {
    final (target, err) = _resolveTarget(m.to);
    if (target == null) return err; // err is non-null when target is null
    if (target.id == m.from) return '不能发给自己';
    target.pasteText(_composeDelivery(target, m), submit: m.submit);
    return null;
  }

  // _composeDelivery builds the text pasted into the target session. Humans (and
  // messages with no resolvable sender) get the original "[来自 label] body". An
  // AI agent recipient (TerminalSession.isAgent) additionally gets the sender id
  // in the tag plus a short reply cheat-sheet, so any tool (Claude/Codex) can
  // answer over the bus without reverse-engineering it. The hint is appended only
  // when the message is auto-submitted; on --no-submit it would otherwise linger
  // in the recipient's input.
  String _composeDelivery(TerminalSession target, LocalMsg m) {
    final fromLabel = sessionById(m.from)?.label ?? (m.from.isEmpty ? '?' : m.from);
    if (m.from.isEmpty || !target.isAgent) {
      return '[来自 $fromLabel] ${m.body}';
    }
    final head = '[来自 $fromLabel · ${m.from}] ${m.body}';
    if (!m.submit) return head;
    return '$head\n'
        '↩ 回我: cc-handoff msg send ${m.from} "<内容>"\n'
        '  其它: msg list 看会话 / msg read ${m.from} 看对方屏幕';
  }

  // readSnapshot renders a target session's recent screen (last [lines] lines,
  // plain text) into [out] for a `kind:"read"` request from `cc-handoff msg
  // read`. Returns null on success or a resolution error (same contract as
  // deliverLocalMessage). Self-read is allowed — reading your own scrollback is
  // harmless, unlike messaging yourself.
  String? readSnapshot(String to, int lines, StringSink out) {
    final (target, err) = _resolveTarget(to);
    if (target == null) return err;
    out.write(target.renderSnapshot(lines));
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
    groupsFor: sendGroupsFor,
    onSendToPeer: _sendToPeer,
    onSendToOnline: onSendToOnline,
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
        children: terms.map((s) {
          final g = sendGroupsFor(s.id);
          return TerminalPane(
            key: ValueKey(s),
            session: s,
            same: g.same,
            others: g.others,
            onSendToPeer: _sendToPeer,
            onSendToOnline: onSendToOnline,
          );
        }).toList(),
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
  final ({List<SendTarget> same, List<SendTarget> others}) Function(
    String selfId,
  )?
  groupsFor;
  final void Function(String fromId, String targetId, String text)?
  onSendToPeer;
  // onSendToOnline(text): forward a selection to the cross-user picker; null
  // hides the "发送到在线用户" entry.
  final void Function(String text)? onSendToOnline;
  const TerminalDeck({
    super.key,
    required this.terms,
    required this.active,
    required this.onSwitch,
    required this.onClose,
    this.onCollapse,
    this.groupsFor,
    this.onSendToPeer,
    this.onSendToOnline,
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
              children: terms.map((s) {
                final g = groupsFor?.call(s.id);
                return TerminalPane(
                  key: ValueKey(s),
                  session: s,
                  same: g?.same ?? const [],
                  others: g?.others ?? const [],
                  onSendToPeer: onSendToPeer,
                  onSendToOnline: onSendToOnline,
                );
              }).toList(),
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
