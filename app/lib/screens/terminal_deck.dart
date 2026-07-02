import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../local/agent_transcript.dart';
import '../local/agent_usage.dart';
import '../local/hook_activity.dart';
import '../local/local_bus.dart';
import '../local/prefs.dart';
import '../local/session_overview.dart';
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

  // onAgentBusyChanged fires when an agent session's busy state flips (turn
  // start / finish). A host with a session-overview projection (the workspace)
  // sets it to republish the snapshot so "思考中"/"待 review" stay live.
  void Function(TerminalSession session)? onAgentBusyChanged;

  // onSendToOnline forwards a terminal selection to the cross-user
  // "发送到在线用户" picker (a remote user + their session). The workspace sets
  // it; hosts that leave it null hide the menu entry. Threaded into both
  // terminalDeck() and terminalBody().
  void Function(String text)? onSendToOnline;

  // onActiveTermChanged fires whenever the active session changes (switch / add /
  // close / restore) — the single chokepoint for "which session is in front".
  // The workspace uses it to re-arm voice TTS on the now-active session.
  void Function()? onActiveTermChanged;

  // _activeChanged is the internal chokepoint behind onActiveTermChanged: it
  // refreshes the now-front session's token usage (so the overlay chip is current
  // the instant you switch to it — not frozen at its last turn boundary), then
  // fans out to the host hook (voice TTS re-arm).
  void _activeChanged() {
    if (activeTerm >= 0 && activeTerm < terms.length) {
      // The front session spawns its PTY now (idempotent). This is what starts a
      // deferred/lazy session the moment it's opened — via reopenTermView, a tab
      // switch, or restore focusing the active tab; already-started sessions no-op.
      final s = terms[activeTerm];
      s.deferred = false;
      s.start();
      unawaited(s.refreshUsage());
    }
    onActiveTermChanged?.call();
  }

  // _onSessionDone is wired onto every session's onDone: show the local desktop
  // banner, then let the host fan it out (phone push) via onAgentDone.
  void _onSessionDone(TerminalSession s) {
    final (title, body) = agentDoneNotice(s);
    Notifications.show(title, body);
    onAgentDone?.call(s);
  }

  // _onSessionBusyChanged fans a session's busy transition out to the host so it
  // can refresh the overview projection (no local banner — just a state change).
  void _onSessionBusyChanged(TerminalSession s) => onAgentBusyChanged?.call(s);

  void addTerm(
    String workdir,
    String command, {
    String agent = '',
    String preLaunch = '',
    bool supervisor = false,
    String? agentSessionId,
    bool resume = false,
  }) {
    // Mint a fixed session id for claude up front so it launches with
    // --session-id and can be --resume'd on the next app start. The immediate
    // _save() below persists it. codex can't pre-assign an id — it captures the
    // one it mints after launch (TerminalSession._maybeCaptureCodexId) and asks
    // us to persist it via onPersist. [agentSessionId]/[resume] let a caller
    // (the 待办 "打开/恢复会话" respawn path) instead bind a specific,
    // already-known transcript UUID up front — same `--resume`/`resume <id>`
    // mechanism restoreTerms() uses, just triggered by a fresh session instead
    // of an app restart.
    final sid = agentSessionId ?? (agent == 'claude' ? _genUuid() : null);
    final session =
        TerminalSession(
          workdir,
          command,
          agent: agent,
          preLaunch: preLaunch,
          supervisor: supervisor,
          agentSessionId: sid,
          resume: resume,
        )
          ..onDone = _onSessionDone
          ..onBusyChanged = _onSessionBusyChanged
          ..onPersist = persistTerms;
    if (supervisor) session.name = '总管';
    setState(() {
      terms.add(session);
      activeTerm = terms.length - 1;
    });
    // Launch the PTY now — NOT lazily when a TerminalPane first builds. A session
    // created remotely (from the phone) while the desktop's terminal deck isn't
    // currently rendered (panel collapsed / another view) would otherwise never
    // start its agent until the desktop UI changed and built the pane, leaving the
    // phone mirroring an empty terminal. start() is idempotent, so the pane's own
    // initState start() stays a no-op.
    session.start();
    onTermsChanged?.call();
    onTermAdded?.call();
    _activeChanged();
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
    _activeChanged();
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
    _activeChanged();
    unawaited(_save()); // persist hidden state so it stays lazy across restart
  }

  // reopenTermView un-hides a session's tab and makes it active — the project
  // tree calls this to bring a closed session's tab back.
  void reopenTermView(int i) {
    if (i < 0 || i >= terms.length) return;
    setState(() {
      _hiddenTabs.remove(terms[i].id);
      activeTerm = i;
    });
    _activeChanged();
    unawaited(_save()); // persist un-hide so it eager-starts next restart
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

  // closeOtherTerms/closeTermsToLeft/closeTermsToRight back the terminal tab's
  // right-click "关闭其他/左侧/右侧" — a real close (kills the PTY) for every
  // matched session, unlike the single-tab × which may only hide the view
  // (closeTermView) in hosts wired with hideClosedTabs. Routed through
  // _closeTermsWhere so a bulk close re-anchors activeTerm on the previously
  // active session's *new* index rather than reusing closeTerm's simple
  // length-clamp, which only accounts for removals at-or-after the active tab
  // (a bulk close can also drop tabs strictly before it).
  void closeOtherTerms(int keep) {
    if (keep < 0 || keep >= terms.length) return;
    _closeTermsWhere((i) => i != keep);
  }

  void closeTermsToLeft(int index) {
    if (index <= 0 || index >= terms.length) return;
    _closeTermsWhere((i) => i < index);
  }

  void closeTermsToRight(int index) {
    if (index < 0 || index >= terms.length - 1) return;
    _closeTermsWhere((i) => i > index);
  }

  void _closeTermsWhere(bool Function(int index) shouldClose) {
    final activeSession = activeTerm >= 0 && activeTerm < terms.length
        ? terms[activeTerm]
        : null;
    final toClose = [
      for (var i = 0; i < terms.length; i++)
        if (shouldClose(i)) terms[i],
    ];
    if (toClose.isEmpty) return;
    for (final s in toClose) {
      _hiddenTabs.remove(s.id);
      s.dispose();
    }
    setState(() {
      terms.removeWhere(toClose.contains);
      if (terms.isEmpty) {
        activeTerm = 0;
      } else if (activeSession != null && !toClose.contains(activeSession)) {
        activeTerm = terms.indexOf(activeSession);
      } else {
        activeTerm = activeTerm.clamp(0, terms.length - 1);
      }
    });
    onTermsChanged?.call();
    _activeChanged();
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
      final hiddenIds = <String>[]; // restore these as closed-to-tree (lazy) tabs
      String? activeId; // persisted-active session id (focus it if still visible)
      var upgraded = false; // a legacy entry was recovered → rewrite the file
      for (final e in data) {
        if (e is! Map) continue;
        final wd = (e['workdir'] ?? '').toString();
        final cmd = (e['command'] ?? '').toString();
        if (wd.isEmpty || cmd.isEmpty || !Directory(wd).existsSync()) continue;
        var agent = (e['agent'] ?? '').toString();
        var preLaunch = (e['preLaunch'] ?? '').toString();
        final supervisor = e['supervisor'] == true;
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
        // Restore the saved stable id (so a phone holding it still resolves after
        // this restart); reserve it so a freshly minted id can't collide.
        final savedId = (e['id'] ?? '').toString();
        if (savedId.isNotEmpty) TerminalSession.reserveId(savedId);
        final ts = TerminalSession(
          wd,
          cmd,
          id: savedId.isEmpty ? null : savedId,
          agent: agent,
          preLaunch: preLaunch,
          supervisor: supervisor,
          agentSessionId: sid.isEmpty ? null : sid,
          resume: true,
        )
          ..onDone = _onSessionDone
          ..onBusyChanged = _onSessionBusyChanged
          ..onPersist = persistTerms;
        final nm = (e['name'] ?? '').toString();
        if (nm.isNotEmpty) ts.name = nm;
        if (nm.isEmpty && supervisor) ts.name = '总管';
        // A tab that was closed to the tree comes back hidden AND deferred: it
        // shows in the tree but its PTY spawns only when the user reopens it.
        if (e['hidden'] == true) {
          ts.deferred = true;
          hiddenIds.add(ts.id);
        }
        if (e['active'] == true) activeId = ts.id;
        restored.add(ts);
      }
      if (restored.isEmpty || !mounted) return;
      setState(() {
        terms.addAll(restored);
        _hiddenTabs.addAll(hiddenIds);
        activeTerm = _initialActiveIndex(activeId);
      });
      onTermsChanged?.call();
      _activeChanged();
      // Only rewrite when a legacy entry was actually recovered — steady-state
      // restarts (all entries already structured) skip the redundant write.
      if (upgraded) unawaited(_save());
    } catch (_) {}
  }

  // _initialActiveIndex picks the tab to focus on restore: the persisted-active
  // session if it's present AND visible, else the first non-hidden session (a
  // hidden tab must never be the active/front tab), else 0. Call after terms +
  // _hiddenTabs are populated.
  int _initialActiveIndex(String? activeId) {
    if (activeId != null) {
      final i = terms.indexWhere((s) => s.id == activeId);
      if (i >= 0 && !isTabHidden(terms[i].id)) return i;
    }
    final firstVisible = terms.indexWhere((s) => !isTabHidden(s.id));
    return firstVisible >= 0 ? firstVisible : 0;
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
          [
            for (final (i, s) in terms.indexed)
              {
                'id': s.id, // stable remote-addressing id (survives restart)
                'workdir': s.workdir,
                'command': s.command,
                if (s.name?.isNotEmpty ?? false) 'name': s.name,
                // AI-session binding (see TerminalSession) — lets a reopened
                // tab --resume its exact conversation next launch.
                if (s.agent.isNotEmpty) 'agent': s.agent,
                if (s.preLaunch.isNotEmpty) 'preLaunch': s.preLaunch,
                if (s.supervisor) 'supervisor': true,
                if (s.agentSessionId != null) 'sessionId': s.agentSessionId,
                // Tab visibility + focus, so restore eager-starts only the visible
                // tabs and re-focuses the right one (hidden tabs stay lazy).
                if (isTabHidden(s.id)) 'hidden': true,
                if (i == activeTerm) 'active': true,
              },
          ],
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
        if (s.agentKind.isNotEmpty) 'agent': s.agentKind,
        if (s.supervisor) 'supervisor': true,
        'status': _busStatusName(s),
        'statusDetail': _busStatusDetail(s),
        if (s.usage.value != null) 'usage': s.usage.value!.shortLabel(),
        if (s.overviewPreview?.isNotEmpty ?? false) 'preview': s.overviewPreview,
      },
  ];

  String _busStatusName(TerminalSession s) {
    if (!s.isAgent) return 'shell';
    if (s.needsReview) return 'needsReview';
    final a = _busLatestHookActivity(s);
    if (s.busy) return _busBusyStatus(a).name;
    if (a == null) return 'waitingInput';
    if (a.event == 'PermissionRequest') return 'waitingPermission';
    if (a.event == 'PostToolUse' && a.exitCode != null && a.exitCode != 0) {
      return 'toolFailed';
    }
    if (a.event == 'Stop' || a.event == 'SubagentStop') return 'waitingInput';
    return 'idle';
  }

  String _busStatusDetail(TerminalSession s) {
    if (!s.isAgent) return s.workdir;
    if (s.needsReview) return '已完成，等待查看';
    final a = _busLatestHookActivity(s);
    if (a == null) return s.busy ? '正在处理' : '等待输入';
    final tool = a.toolName.isEmpty ? a.event : '${a.event} ${a.toolName}';
    if (a.event == 'PermissionRequest') {
      return a.toolName.isEmpty ? '等待权限确认' : '等待权限：${a.toolName}';
    }
    if (a.exitCode != null && a.exitCode != 0) {
      return '$tool 失败 exit ${a.exitCode}';
    }
    if (s.busy) return '正在处理：$tool';
    return '空闲：$tool';
  }

  HookActivity? _busLatestHookActivity(TerminalSession s) {
    final recent = localBusHookActivities(s.id, limit: 8);
    for (final a in recent) {
      if (a.event != 'SessionStart') return a;
    }
    return null;
  }

  SessionStatus _busBusyStatus(HookActivity? a) {
    if (a == null) return SessionStatus.working;
    if (a.event == 'PreToolUse') return SessionStatus.runningTool;
    if (a.event == 'PostToolUse') {
      if (a.exitCode != null && a.exitCode != 0) {
        return SessionStatus.toolFailed;
      }
      return SessionStatus.toolDone;
    }
    if (a.event == 'PermissionRequest') return SessionStatus.waitingPermission;
    if (a.event == 'SubagentStart' || a.event == 'SubagentStop') {
      return SessionStatus.subagent;
    }
    if (a.event == 'PreCompact' || a.event == 'PostCompact') {
      return SessionStatus.compacting;
    }
    return SessionStatus.working;
  }

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
  // Idle target with a clean input row → paste straight into its PTY (an immediate
  // new turn). Busy agent OR one whose input row is dirty (the user has typed
  // unsubmitted keystrokes) → park in its bus inbox so its PostToolUse/Stop hook
  // injects the message as its own clean turn — instead of queuing behind a running
  // turn, or racing the paste against what the user is typing (which drops one of
  // them). --no-submit fills and non-agent targets always paste (no hook to drain
  // an inbox, and a fill is meant to sit in the input box for review).
  String? deliverLocalMessage(LocalMsg m) {
    final (target, err) = _resolveTarget(m.to);
    if (target == null) return err; // err is non-null when target is null
    if (target.id == m.from) return '不能发给自己';
    // Not-ready target — no live, input-accepting PTY: a dormant/deferred/never-
    // mounted tab (no PTY at all → a straight paste vanishes), OR one still booting
    // in its ~1s launch window (paste+Enter races the boot → lost/mangled). Wake it
    // (start if needed) and QUEUE the message; the target's boot-ready watch flushes
    // it with paste+submit the moment the agent settles — so dispatch auto-runs a
    // turn regardless of tab visibility/focus/boot state, no manual Enter. Checked
    // FIRST: a not-ready session is never meaningfully busy/inputDirty, so this
    // can't shadow those. A ready target falls through to the paste/inbox routing.
    if (!target.ready) {
      target.wakeAndDeliver(_composeDelivery(target, m), submit: m.submit);
      return null;
    }
    if (m.submit && (target.busy || target.inputDirty)) {
      return _enqueueBusInbox(target, m);
    }
    target.pasteText(_composeDelivery(target, m), submit: m.submit);
    return null;
  }

  // killLocalSession serves a kind:"kill" request (`cc-handoff msg kill`): it
  // resolves [to] and closes that session's tab exactly like clicking its ×
  // (closeTerm) — kills the PTY and drops it from [terms]. Refused for
  // self-kill (the caller's own PTY is what's running the command that would
  // be killed) and for a supervisor target (the session coordinating the
  // others over the bus must stay a deliberate, in-App close, not something
  // any peer can trigger remotely). Returns null on success or a Chinese
  // error → <id>.err.
  String? killLocalSession(String from, String to) {
    final (target, err) = _resolveTarget(to);
    if (target == null) return err;
    if (target.id == from) return '不能关闭自己';
    if (target.supervisor) return '不能通过总线关闭总管会话「${target.label}」';
    final i = terms.indexOf(target);
    if (i < 0) return '找不到目标会话「$to」';
    closeTerm(i);
    return null;
  }

  // _enqueueBusInbox drops a message into <busDir>/inbox/<targetId>/ for the
  // target's `cc-handoff bus-hook` to drain as additionalContext. Filename is a
  // microsecond timestamp + counter so the hook reads FIFO; atomic tmp+rename so
  // the hook never sees a half-written file (mirrors local_bus.dart's writes and
  // the Go-side internal/localbus reader). Also arms the bounded escalate
  // fallback (_scheduleEscalate) so a target that goes fully idle and never
  // fires another hook doesn't strand the message forever (the "parked
  // messages" bug — see _scheduleEscalate). Returns null on success, else an
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
      _scheduleEscalate(target, path, m);
      return null;
    } catch (e) {
      return '投递到会话 inbox 失败: $e';
    }
  }

  // _escalateTimeout bounds how long a parked message waits for the target's
  // own hook to drain it before this session force-delivers it instead.
  // Chosen well under `msg send`'s default 5s --timeout (so the CLI caller
  // gets its "ok" receipt long before this fires — parking already counts as
  // delivered from the caller's perspective, same as before this existed) but
  // generous enough that a normal PostToolUse/Stop firing shortly after park
  // always wins the race — escalation is the bounded fallback, not the common
  // path.
  static const Duration _escalateTimeout = Duration(seconds: 3);

  // _scheduleEscalate arms a bounded wait-then-force-deliver for one parked
  // bus message (fixes the "parked forever" bug: a target that finishes its
  // current turn and then sits fully idle never fires another hook, so
  // nothing was ever draining the message — see the local-bus-optimization
  // writeup). A Timer, not a blocking wait, so it never stalls the sender's
  // own turn. If the target's own hook drains [path] first, the file is
  // simply gone when the timer fires — file existence IS the ack, no separate
  // protocol needed.
  void _scheduleEscalate(TerminalSession target, String path, LocalMsg m) {
    Timer(_escalateTimeout, () => unawaited(_escalateBusInbox(target, path, m)));
  }

  // _escalateBusInbox force-delivers one parked message if the target's own
  // hook hasn't drained it within _escalateTimeout. Races the hook under the
  // shared inbox lock (acquireInboxDrainLock, same lock file the Go hook's
  // AcquireDrainLock claims) so the two paths can never both deliver the same
  // message. Ignores target.busy/inputDirty on purpose — by now the sender has
  // already waited several seconds for the target's own hook with no result,
  // so a forced paste beats leaving the message parked indefinitely.
  Future<void> _escalateBusInbox(
    TerminalSession target,
    String path,
    LocalMsg m,
  ) async {
    if (!File(path).existsSync()) return; // hook already drained it
    final locked = await acquireInboxDrainLock(target.id);
    if (!locked) return; // hook is actively draining this inbox right now
    try {
      if (!File(path).existsSync()) return; // drained between the two checks
      target.pasteText(_composeDelivery(target, m), submit: true);
      try {
        File(path).deleteSync();
      } catch (_) {}
    } finally {
      await releaseInboxDrainLock(target.id);
    }
  }

  // debugEscalateBusInboxNow runs the check-lock-paste-delete sequence a
  // scheduled escalate Timer would normally run only after _escalateTimeout,
  // immediately — so tests can exercise the drained-in-window vs
  // nobody-drained paths without a real multi-second wait. Test-only, mirrors
  // TerminalSession.debugMarkBootSettled.
  @visibleForTesting
  Future<void> debugEscalateBusInboxNow(
    TerminalSession target,
    String path,
    LocalMsg m,
  ) =>
      _escalateBusInbox(target, path, m);

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

  // readOutput is the bus-facing read entry (LocalBus.readOutput): it owns the
  // screen-vs-transcript policy — the per-call `--transcript` flag OR the app's
  // `ws.read_transcript` toggle — so the bus stays plumbing, then delegates to
  // readTranscript / readSnapshot.
  Future<String?> readOutput(String to, int lines, bool transcript, StringSink out) {
    if (transcript || Prefs.getBool('ws.read_transcript')) {
      return readTranscript(to, lines, out);
    }
    return Future.value(readSnapshot(to, lines, out));
  }

  // readTranscript is the structured alternative to readSnapshot: it renders the
  // target's recent agent output from its on-disk transcript JSONL (assistant
  // text + `[tool: …]` markers) instead of scraping the rendered screen, so the
  // reader gets semantic content unaffected by TUI folding/wrapping/scroll. Used
  // by the `msg read` channel when `--transcript` or the App toggle is on. Async
  // (reads a file); same error contract as readSnapshot.
  Future<String?> readTranscript(String to, int lines, StringSink out) async {
    final (target, err) = _resolveTarget(to);
    if (target == null) return err;
    if (!target.isAgent) return '会话「${target.label}」不是 agent,没有 transcript';
    final path = await resolveTranscriptPath(
      agentKind: target.agentKind,
      agentSessionId: target.agentSessionId,
      workdir: target.workdir,
    );
    if (path == null) {
      return '找不到「${target.label}」的 transcript(未捕获 session id 或日志不存在)';
    }
    try {
      out.write(
        await renderTranscriptTail(path, lines: lines, agentKind: target.agentKind),
      );
      return null;
    } catch (e) {
      return '读取 transcript 失败: $e';
    }
  }

  // readUsage is the bus-facing entry for a `kind:"usage"` request from
  // `cc-handoff msg usage`: it resolves the target session, recomputes its
  // token/cost usage from the on-disk transcript, and writes the JSON snapshot
  // into [out]. Same resolution + error contract as readTranscript. Self-read is
  // fine. Returns null on success or a Chinese error → <id>.err.
  Future<String?> readUsage(String to, StringSink out) async {
    final (target, err) = _resolveTarget(to);
    if (target == null) return err;
    if (!target.isAgent) return '会话「${target.label}」不是 agent,没有用量';
    final SessionUsage? u;
    try {
      u = await target.refreshUsage();
    } catch (e) {
      return '读取用量失败: $e';
    }
    if (u == null) {
      return '找不到「${target.label}」的 transcript(未捕获 session id 或日志不存在)';
    }
    out.write(jsonEncode(u.toJson()));
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
      _activeChanged();
    },
    onClose: hideClosedTabs ? closeTermView : closeTerm,
    onCloseOthers: closeOtherTerms,
    onCloseLeft: closeTermsToLeft,
    onCloseRight: closeTermsToRight,
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
  // onCloseOthers/onCloseLeft/onCloseRight power the tab's right-click menu
  // bulk actions; null hides the corresponding row (falls back to disabled).
  final ValueChanged<int>? onCloseOthers;
  final ValueChanged<int>? onCloseLeft;
  final ValueChanged<int>? onCloseRight;
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
    this.onCloseOthers,
    this.onCloseLeft,
    this.onCloseRight,
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
          onCloseOthers: onCloseOthers,
          onCloseLeft: onCloseLeft,
          onCloseRight: onCloseRight,
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
  // onCloseOthers/onCloseLeft/onCloseRight power the right-click tab menu's
  // bulk-close rows; null hides (disables) the corresponding row.
  final ValueChanged<int>? onCloseOthers;
  final ValueChanged<int>? onCloseLeft;
  final ValueChanged<int>? onCloseRight;
  final Widget? leading;
  final Widget? trailing;
  const TerminalTabBar({
    super.key,
    required this.terms,
    required this.active,
    this.hiddenIds,
    required this.onSwitch,
    required this.onClose,
    this.onCloseOthers,
    this.onCloseLeft,
    this.onCloseRight,
    this.leading,
    this.trailing,
  });

  // 右键菜单项：跟 workspace_page.dart 里文件标签页的 _editorFileTabMenuItems 同一
  // 视觉风格(ccMenuItem/showMenu/menuPosAt)。"关闭"直接调 onClose(i) ——跟标签上
  // 那颗 × 按钮完全同一个回调，语义天然一致(workspace 里是 closeTermView 只隐藏
  // 视图，PTY 仍在跑；inbox 收件箱里是 closeTerm 真正结束会话)，不用在这里猜一次
  // 该调哪个。"关闭其他/左侧/右侧"则总是真正结束会话(TerminalHost.closeOtherTerms
  // 等)，跟单个 × 的隐藏语义不同——批量清理标签页时，用户预期是真的了结那些会话，
  // 不是把它们悄悄留在后台占资源。
  List<PopupMenuEntry<String>> _tabMenuItems(int i) => [
    ccMenuItem(value: 'close', icon: Icons.close_rounded, label: 'Close'),
    ccMenuItem(
      value: 'closeOthers',
      icon: Icons.clear_rounded,
      label: 'Close Others',
      enabled: onCloseOthers != null && terms.length > 1,
    ),
    if (onCloseLeft != null && i > 0)
      ccMenuItem(
        value: 'closeLeft',
        icon: Icons.first_page_rounded,
        label: 'Close Tabs to the Left',
      ),
    if (onCloseRight != null && i < terms.length - 1)
      ccMenuItem(
        value: 'closeRight',
        icon: Icons.keyboard_tab_rounded,
        label: 'Close Tabs to the Right',
      ),
    const PopupMenuDivider(),
    ccMenuItem(
      value: 'copyPath',
      icon: Icons.content_copy_rounded,
      label: 'Copy Path',
    ),
  ];

  Future<void> _showTabMenu(BuildContext context, Offset pos, int i) async {
    final v = await showMenu<String>(
      context: context,
      position: menuPosAt(context, pos),
      items: _tabMenuItems(i),
    );
    if (v == null) return;
    switch (v) {
      case 'close':
        onClose(i);
      case 'closeOthers':
        onCloseOthers?.call(i);
      case 'closeLeft':
        onCloseLeft?.call(i);
      case 'closeRight':
        onCloseRight?.call(i);
      case 'copyPath':
        await Clipboard.setData(ClipboardData(text: terms[i].workdir));
        if (context.mounted) snack(context, '已复制路径');
    }
  }

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
                  onSecondaryTapDown: (d) =>
                      _showTabMenu(context, d.globalPosition, i),
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
                        sessionAvatar(
                          seed: term.id,
                          isAgent: term.isAgent,
                          size: 16,
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
