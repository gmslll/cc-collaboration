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

  // _hiddenTabs holds the ids of sessions whose top-bar tab was closed via the
  // workspace "close view" (×). The session stays in [terms] — its PTY keeps
  // running and its pane stays mounted in the IndexedStack, so reopening it
  // (reopenTermView, from the project tree) returns to the exact live screen.
  // Purely a tab-strip concept: everything else (IndexedStack aliveness, the
  // docked terminalBody, the tree listing, activeTerm indices, the local bus,
  // remote mirroring) keeps using the unfiltered [terms]. Transient — a restart
  // restores every session as a visible tab again.
  final Set<String> _hiddenTabs = {};

  // hasVisibleTab is false only when every session's tab has been closed (all
  // hidden). The workspace gates its focused-chat deck on this so closing the
  // last tab falls back to the welcome screen instead of an empty tab strip.
  bool get hasVisibleTab => terms.any((s) => !_hiddenTabs.contains(s.id));

  // isTabHidden reports whether a session's tab is currently closed (the session
  // still runs in the background). The tree uses it to mark such sessions.
  bool isTabHidden(String id) => _hiddenTabs.contains(id);

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

  // onActiveTermChanged fires whenever the active session changes (switch / add /
  // close / restore) — the single chokepoint for "which session is in front".
  // The workspace uses it to re-arm voice TTS on the now-active session.
  void Function()? onActiveTermChanged;

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
    // _save() below persists it. codex can't pre-assign an id — it captures the
    // one it mints after launch (TerminalSession._maybeCaptureCodexId) and asks
    // us to persist it via onPersist.
    final sid = agent == 'claude' ? _genUuid() : null;
    setState(() {
      terms.add(
        TerminalSession(
          workdir,
          command,
          agent: agent,
          preLaunch: preLaunch,
          agentSessionId: sid,
        )
          ..onDone = _onSessionDone
          ..onPersist = persistTerms,
      );
      activeTerm = terms.length - 1;
    });
    onTermsChanged?.call();
    onTermAdded?.call();
    onActiveTermChanged?.call();
    unawaited(_save());
  }

  void closeTerm(int i) {
    _hiddenTabs.remove(terms[i].id);
    terms[i].dispose();
    setState(() {
      terms.removeAt(i);
      if (activeTerm >= terms.length) {
        activeTerm = terms.isEmpty ? 0 : terms.length - 1;
      }
    });
    onTermsChanged?.call();
    onActiveTermChanged?.call();
    unawaited(_save());
  }

  // closeTermView hides a session's top-bar tab WITHOUT ending it (the × on a
  // workspace tab). The PTY keeps running and the pane stays mounted in the
  // IndexedStack, so reopenTermView returns to the exact live screen. If the
  // closed tab was active, focus moves to the nearest still-visible tab (none →
  // the workspace falls back to the welcome screen via hasVisibleTab). [terms]
  // is unchanged, so no dispose and no _save.
  void closeTermView(int i) {
    if (i < 0 || i >= terms.length) return;
    setState(() {
      _hiddenTabs.add(terms[i].id);
      if (activeTerm == i) {
        final next = _nearestVisible(i);
        if (next != null) activeTerm = next;
      }
    });
    onActiveTermChanged?.call();
  }

  // reopenTermView un-hides a session's tab and makes it active — the project
  // tree calls this to bring a closed session's tab back.
  void reopenTermView(int i) {
    if (i < 0 || i >= terms.length) return;
    setState(() {
      _hiddenTabs.remove(terms[i].id);
      activeTerm = i;
    });
    onActiveTermChanged?.call();
  }

  // _nearestVisible returns the index of the closest non-hidden tab to [from]
  // (searching outward), or null when every tab is hidden.
  int? _nearestVisible(int from) {
    for (var d = 1; d < terms.length; d++) {
      final r = from + d;
      if (r < terms.length && !_hiddenTabs.contains(terms[r].id)) return r;
      final l = from - d;
      if (l >= 0 && !_hiddenTabs.contains(terms[l].id)) return l;
    }
    return null;
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
        )
          ..onDone = _onSessionDone
          ..onPersist = persistTerms;
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
      onActiveTermChanged?.call();
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

  // Monotonic suffix so two messages parked in the same microsecond still get
  // distinct, FIFO-ordered inbox filenames.
  int _busSeq = 0;

  // deliverLocalMessage routes one message to a target session. Returns null on
  // success, or a human-readable error (unknown/ambiguous target, self-send,
  // inbox write failure) that LocalBus writes back so `msg send` exits non-zero.
  //
  // Idle target → paste straight into its PTY (an immediate new turn). Busy
  // agent target → park in its bus inbox so its PostToolUse/Stop hook injects
  // the message mid-turn, instead of the paste queuing behind the whole running
  // turn. --no-submit fills and non-agent targets always paste (no hook to
  // drain an inbox, and a fill is meant to sit in the input box for review).
  String? deliverLocalMessage(LocalMsg m) {
    final (target, err) = _resolveTarget(m.to);
    if (target == null) return err; // err is non-null when target is null
    if (target.id == m.from) return '不能发给自己';
    if (m.submit && target.busy) {
      return _enqueueBusInbox(target, m);
    }
    target.pasteText(_composeDelivery(target, m), submit: m.submit);
    return null;
  }

  // _enqueueBusInbox drops a message into <busDir>/inbox/<targetId>/ for the
  // target's `cc-handoff bus-hook` to drain as additionalContext. Filename is a
  // microsecond timestamp + counter so the hook reads FIFO; atomic tmp+rename so
  // the hook never sees a half-written file (mirrors local_bus.dart's writes and
  // the Go-side internal/localbus reader). Returns null on success, else an
  // error string relayed back as the `msg send` .err receipt.
  String? _enqueueBusInbox(TerminalSession target, LocalMsg m) {
    try {
      final micros = DateTime.now().microsecondsSinceEpoch;
      final dir = Directory('${localBusDir()}/inbox/${target.id}')
        ..createSync(recursive: true);
      final path = '${dir.path}/$micros-${_busSeq++}.json';
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(jsonEncode({
        'from': m.from,
        'fromLabel': _fromLabel(m.from),
        'body': m.body,
      }));
      tmp.renameSync(path);
      return null;
    } catch (e) {
      return '投递到会话 inbox 失败: $e';
    }
  }

  // _fromLabel resolves a sender session id to its human label, falling back to
  // the raw id ('?' when empty). Shared by bus-inbox delivery and PTY paste.
  String _fromLabel(String fromId) =>
      sessionById(fromId)?.label ?? (fromId.isEmpty ? '?' : fromId);

  // _composeDelivery builds the text pasted into the target session. Humans (and
  // messages with no resolvable sender) get the original "[来自 label] body". An
  // AI agent recipient (TerminalSession.isAgent) additionally gets the sender id
  // in the tag plus a short reply cheat-sheet, so any tool (Claude/Codex) can
  // answer over the bus without reverse-engineering it. The hint is appended only
  // when the message is auto-submitted; on --no-submit it would otherwise linger
  // in the recipient's input.
  String _composeDelivery(TerminalSession target, LocalMsg m) {
    final fromLabel = _fromLabel(m.from);
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

  // _interjectToPeer is the submit:true variant: deliverLocalMessage routes it to
  // a busy agent's bus inbox (hook injects it mid-turn) or runs it immediately
  // when the target is idle — same routing as `cc-handoff msg send`.
  void _interjectToPeer(String fromId, String targetId, String text) =>
      deliverLocalMessage(LocalMsg(fromId, targetId, text, true));

  // hideClosedTabs (workspace only) routes the tab × to closeTermView (hide,
  // keep the session running) and filters hidden tabs out of the strip. Off by
  // default so the inbox cockpit keeps ×=closeTerm (kill) — it has no tree to
  // reopen a hidden session from.
  Widget terminalDeck({
    VoidCallback? onCollapse,
    VoidCallback? onNewShell,
    bool hideClosedTabs = false,
  }) =>
      TerminalDeck(
    terms: terms,
    active: activeTerm,
    hiddenIds: hideClosedTabs ? _hiddenTabs : null,
    onSwitch: (i) {
      setState(() => activeTerm = i);
      onActiveTermChanged?.call();
    },
    onClose: hideClosedTabs ? closeTermView : closeTerm,
    onCollapse: onCollapse,
    onNewShell: onNewShell,
    groupsFor: sendGroupsFor,
    onSendToPeer: _sendToPeer,
    onInterjectToPeer: _interjectToPeer,
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
            onInterjectToPeer: _interjectToPeer,
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
  // hiddenIds: sessions whose tab is closed ("close view") — kept in [terms]
  // (alive in the IndexedStack) but dropped from the tab strip. Null = nothing
  // hidden (inbox cockpit).
  final Set<String>? hiddenIds;
  final ValueChanged<int> onSwitch;
  final ValueChanged<int> onClose;
  final VoidCallback? onCollapse;
  // onNewShell: open a plain interactive shell tab; null hides the + button.
  final VoidCallback? onNewShell;
  // Local point-to-point forwarding wiring (see TerminalHost); null/absent
  // hides the "发送到终端" context-menu entries.
  final ({List<SendTarget> same, List<SendTarget> others}) Function(
    String selfId,
  )?
  groupsFor;
  final void Function(String fromId, String targetId, String text)?
  onSendToPeer;
  // onInterjectToPeer(fromId, targetId, text): submit:true forwarding (interject
  // into a busy peer's turn via its hook, or run when idle); null hides it.
  final void Function(String fromId, String targetId, String text)?
  onInterjectToPeer;
  // onSendToOnline(text): forward a selection to the cross-user picker; null
  // hides the "发送到在线用户" entry.
  final void Function(String text)? onSendToOnline;
  const TerminalDeck({
    super.key,
    required this.terms,
    required this.active,
    this.hiddenIds,
    required this.onSwitch,
    required this.onClose,
    this.onCollapse,
    this.onNewShell,
    this.groupsFor,
    this.onSendToPeer,
    this.onInterjectToPeer,
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
          hiddenIds: hiddenIds,
          onSwitch: onSwitch,
          onClose: onClose,
          trailing: (onNewShell == null && onCollapse == null)
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onNewShell != null)
                      IconButton(
                        icon: const Icon(Icons.add_rounded, size: 18),
                        tooltip: '新建终端（普通 shell）',
                        visualDensity: VisualDensity.compact,
                        onPressed: onNewShell,
                      ),
                    if (onCollapse != null)
                      IconButton(
                        icon: const Icon(Icons.chevron_right_rounded, size: 16),
                        tooltip: '收起终端',
                        visualDensity: VisualDensity.compact,
                        onPressed: onCollapse,
                      ),
                  ],
                ),
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
                  onInterjectToPeer: onInterjectToPeer,
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
  // hiddenIds: ids of sessions whose tab was closed ("close view") — filtered
  // out of the strip but kept in [terms]. Null/empty = show every tab.
  final Set<String>? hiddenIds;
  final ValueChanged<int> onSwitch;
  final ValueChanged<int> onClose;
  final Widget? leading;
  final Widget? trailing;
  const TerminalTabBar({
    super.key,
    required this.terms,
    required this.active,
    this.hiddenIds,
    required this.onSwitch,
    required this.onClose,
    this.leading,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final idx = terms.isEmpty ? 0 : active.clamp(0, terms.length - 1);
    // Tabs whose view was closed (hiddenIds) stay in [terms] (alive) but drop
    // out of the strip; keep each kept tab's REAL index so onSwitch/onClose and
    // the active underline stay aligned with the host's terms/activeTerm.
    final visible = <({int i, TerminalSession s})>[];
    for (var i = 0; i < terms.length; i++) {
      if (hiddenIds?.contains(terms[i].id) ?? false) continue;
      visible.add((i: i, s: terms[i]));
    }
    return Container(
      color: CcColors.panel,
      height: 38,
      child: Row(
        children: [
          ?leading,
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: visible.length,
              itemBuilder: (_, k) {
                final i = visible[k].i;
                final term = visible[k].s;
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
                          term.label,
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
