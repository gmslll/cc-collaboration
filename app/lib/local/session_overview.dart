import 'package:flutter/foundation.dart';

import 'hook_activity.dart';
import 'local_bus.dart';

// Shared, UI-free projection of a terminal session for the "会话总览" surface.
//
// A glanceable snapshot — label, workspace→project→worktree hierarchy, status,
// token usage, and a preview of the agent's latest reply — produced ONCE by the
// desktop WorkspacePage (the owner of the live sessions) and consumed by BOTH:
//   - the desktop top-level SessionOverviewPage (via SessionOverviewStore), and
//   - the phone overview (serialised over the relay's `overview` frame).
// Kept in lib/local so it carries no screens/ import; both ends + the remote
// layer share the same type.

// ScreenSnapshot is one coloured live-screen snapshot for the quick-reply popup:
// the ANSI tail PLUS the source terminal's own geometry (cols×rows). The preview
// renders it at THAT native width instead of reflowing to the popup's narrow
// width, so absolute-positioned TUI chrome (box art, separators, the agent's
// input prompt) stays aligned instead of shattering. cols/rows travel with the
// ansi through both the local previewHandler and the remote `screen` frame.
typedef ScreenSnapshot = ({String ansi, int cols, int rows});

// SessionStatus is the at-a-glance state shown on each card. `shell` = a plain
// (non-agent) terminal. Agent states combine the coarse terminal busy flag with
// recent hook events so the overview can say what the agent is actually doing.
enum SessionStatus {
  working,
  runningTool,
  toolDone,
  toolFailed,
  waitingPermission,
  compacting,
  subagent,
  needsReview,
  waitingInput,
  idle,
  shell,
}

SessionStatus sessionStatusFromName(String? n) => switch (n) {
  'working' => SessionStatus.working,
  'runningTool' => SessionStatus.runningTool,
  'toolDone' => SessionStatus.toolDone,
  'toolFailed' => SessionStatus.toolFailed,
  'waitingPermission' => SessionStatus.waitingPermission,
  'compacting' => SessionStatus.compacting,
  'subagent' => SessionStatus.subagent,
  'needsReview' => SessionStatus.needsReview,
  'waitingInput' => SessionStatus.waitingInput,
  'shell' => SessionStatus.shell,
  _ => SessionStatus.idle,
};

// statusLabel is the pure (no-material) Chinese label; UIs map the colour.
String statusLabel(SessionStatus s) => switch (s) {
  SessionStatus.working => '思考中',
  SessionStatus.runningTool => '运行工具',
  SessionStatus.toolDone => '工具完成',
  SessionStatus.toolFailed => '工具失败',
  SessionStatus.waitingPermission => '待授权',
  SessionStatus.compacting => '压缩中',
  SessionStatus.subagent => '子代理',
  SessionStatus.needsReview => '待 review',
  SessionStatus.waitingInput => '等待输入',
  SessionStatus.idle => '空闲',
  SessionStatus.shell => 'shell',
};

bool sessionStatusIsActive(SessionStatus s) => switch (s) {
  SessionStatus.working ||
  SessionStatus.runningTool ||
  SessionStatus.toolDone ||
  SessionStatus.toolFailed ||
  SessionStatus.waitingPermission ||
  SessionStatus.compacting ||
  SessionStatus.subagent => true,
  _ => false,
};

class SessionCard {
  final String sid;
  final String label;
  final String agentKind; // 'claude' / 'codex' / '' (shell)
  final bool isAgent;
  final String workspace; // workspace name ('' if unmapped/orphan)
  final String project; // project name ('' if unmapped/orphan)
  final String projectId; // relay project id ('' if unmapped/legacy)
  final String? worktree; // worktree name (null at project root)
  final SessionStatus status;
  final String
  statusDetail; // richer live state derived from recent hook events
  final String? usageLabel; // SessionUsage.shortLabel(), or null
  final String preview; // latest assistant reply / terminal tail
  // agentSessionId/workdir back the 待办 "打开/恢复会话" affordance: the real
  // Claude/Codex transcript UUID + absolute working directory for this live
  // session, so a caller that only has a todo's permanently-bound resume
  // trio (assignee_agent_session_id/workdir/kind — see pkg/todoschema.Todo)
  // can tell "still this exact session" apart from "gone, respawn from the
  // saved id". Null for a shell session (no agent transcript) or when the
  // card came from a legacy phone client that predates this field.
  final String? agentSessionId;
  final String? workdir;
  // Small, recent execution trace for overview cards. This is intentionally
  // short; full per-session activity still streams through the dedicated
  // activity channel when a session is opened/watched.
  final List<HookActivity> recentActivity;
  // isSupervisor distinguishes a 总管 session from a plain agent one of the
  // same agentKind — TerminalSession.agentKind alone doesn't encode this (it
  // returns bare 'claude'/'codex' either way), but respawning a todo bound to
  // a supervisor session needs the 'supervisor:claude'/'supervisor:codex' kind
  // string _spawnManagedSession's _supervisorAgentForKind expects, or the
  // resumed session silently loses its supervisor identity/behavior.
  final bool isSupervisor;

  const SessionCard({
    required this.sid,
    required this.label,
    required this.agentKind,
    required this.isAgent,
    required this.workspace,
    required this.project,
    this.projectId = '',
    required this.worktree,
    required this.status,
    this.statusDetail = '',
    required this.usageLabel,
    required this.preview,
    this.agentSessionId,
    this.workdir,
    this.recentActivity = const [],
    this.isSupervisor = false,
  });

  Map<String, dynamic> toJson() => {
    'sid': sid,
    'label': label,
    'agent': agentKind,
    'isAgent': isAgent,
    'ws': workspace,
    'proj': project,
    'projectId': projectId,
    'wt': worktree,
    'status': status.name,
    'statusDetail': statusDetail,
    'usage': usageLabel,
    'preview': preview,
    'agentSessionId': agentSessionId,
    'workdir': workdir,
    if (recentActivity.isNotEmpty)
      'recentActivity': [for (final a in recentActivity) a.toJson()],
    'isSupervisor': isSupervisor,
  };

  factory SessionCard.fromJson(Map<dynamic, dynamic> m) {
    final rawActivity = m['recentActivity'];
    return SessionCard(
      sid: (m['sid'] ?? '').toString(),
      label: (m['label'] ?? '').toString(),
      agentKind: (m['agent'] ?? '').toString(),
      isAgent: m['isAgent'] == true,
      workspace: (m['ws'] ?? '').toString(),
      project: (m['proj'] ?? '').toString(),
      projectId: (m['projectId'] ?? '').toString().trim(),
      worktree: m['wt']?.toString(),
      status: sessionStatusFromName(m['status'] as String?),
      statusDetail: (m['statusDetail'] ?? '').toString(),
      usageLabel: m['usage']?.toString(),
      preview: (m['preview'] ?? '').toString(),
      agentSessionId: m['agentSessionId']?.toString(),
      workdir: m['workdir']?.toString(),
      recentActivity: rawActivity is List
          ? [
              for (final a in rawActivity)
                if (a is Map) HookActivity.fromWire(a),
            ]
          : const [],
      isSupervisor: m['isSupervisor'] == true,
    );
  }
}

// SessionOverviewStore is the in-process source of the overview snapshot on the
// desktop. WorkspacePage publishes the latest cards; the top-level
// SessionOverviewPage listens and renders. Opening a card routes back through
// openHandler (registered by WorkspacePage) so the session's tab is reopened +
// focused. `observed` lets the workspace run its light preview-refresh ticker
// only while the overview page is actually on screen. One instance is created by
// HomeShell and injected into both pages (matching the codebase's DI pattern).
class SessionOverviewStore extends ChangeNotifier {
  List<SessionCard> cards = const [];
  final ValueNotifier<bool> observed = ValueNotifier(false);
  void Function(String sid)? openHandler;
  // inputHandler injects text/keys into a live session; previewHandler returns a
  // deeper live-screen snapshot. Both registered by WorkspacePage so the quick-
  // reply popup can preview + reply without switching to the workspace.
  void Function(String sid, String text, {bool submit})? inputHandler;
  Future<ScreenSnapshot?> Function(String sid)? previewHandler;
  // reviewedHandler marks a session as "已查看" — the overview page can't reach
  // `terms`, so opening the quick-reply preview routes through here to let
  // WorkspacePage clear that session's 待 review flag (the same "the user is
  // looking at it" semantics as local foregrounding / a phone watching it).
  void Function(String sid)? reviewedHandler;
  // dispatchHandler delivers one message to an existing local session — the
  // "指派待办给一个已有会话" path for the (future) 待办 top-level page, which like
  // this store's other consumers can't reach `terms` directly. Points straight at
  // WorkspacePage's deliverLocalMessage: same signature, same "not ready → wake +
  // queue; busy/dirty → bus inbox; else paste+submit" routing, so a dispatched
  // todo starts the target session's next turn with no extra wiring here.
  String? Function(LocalMsg m)? dispatchHandler;
  // spawnHandler starts a brand-new local session for the "指派待办→新建会话"
  // path — optionally in a fresh git worktree branch first. Resolves
  // (workspace, project) against WorkspacePage's live config (this store's
  // caller has no config of its own), validates [kind], and returns
  // (sid, null) on success or (null, error) — same result-tuple convention as
  // WorkspacePage's internal `_resolveTarget`. resumeAgentSessionId, when
  // set, respawns bound to that real Claude/Codex transcript UUID (the same
  // `--resume`/`resume <id>` path terminal_deck.dart's restoreTerms() uses
  // after an app restart) instead of minting a brand-new conversation — the
  // "打开/恢复会话" 待办 affordance's path when the bus session it was
  // assigned to is gone. workdir, when set, pins the launch to that exact
  // already-known directory (e.g. a todo's saved assigneeWorkdir, which may
  // be a worktree subdir, not the project root) — distinct from
  // newWorktreeBranch, which instead creates a brand-new one; the two are
  // mutually exclusive.
  Future<(String? sid, String? error)> Function({
    required String workspace,
    required String project,
    required String kind,
    String? newWorktreeBranch,
    String? worktreeStart,
    String? resumeAgentSessionId,
    String? workdir,
  })?
  spawnHandler;

  // captureCapsuleHandler / submitCapsuleHandler back the session card's "打成
  // 胶囊" action. Split in two so the config/relay-dependent work stays in
  // WorkspacePage (capture the transcript + distill; shell `cc-handoff capsule
  // submit`) while the review/edit dialog lives in the overview page.
  // captureCapsuleHandler freezes the session into a scratch draft dir (returns
  // a CapsuleDraft); the user reviews/edits persona/seed; submitCapsuleHandler
  // ships it. preferSelfDistill is the user's opt-in to have the LIVE session
  // distill itself (only honored when it's also idle — see chooseDistillStrategy).
  Future<(CapsuleDraft? draft, String? error)> Function(
    SessionCard card, {
    required bool preferSelfDistill,
  })?
  captureCapsuleHandler;
  Future<(bool ok, String? error)> Function(
    CapsuleDraft draft, {
    required String visibility,
    required String summary,
    required List<String> skillZips,
  })?
  submitCapsuleHandler;

  // capsuleInFlight tracks sessions whose capsule is currently being captured/
  // distilled, so the UI debounces repeat "打成胶囊" clicks and can show a busy
  // state on the card. Mutated only through the mark/clear helpers so listeners
  // (the overview cards) rebuild.
  final Set<String> capsuleInFlight = {};
  bool isCapsuleInFlight(String sid) => capsuleInFlight.contains(sid);
  void markCapsuleInFlight(String sid) {
    if (capsuleInFlight.add(sid)) notifyListeners();
  }

  void clearCapsuleInFlight(String sid) {
    if (capsuleInFlight.remove(sid)) notifyListeners();
  }

  void publish(List<SessionCard> c) {
    cards = c;
    notifyListeners();
  }

  void requestOpen(String sid) => openHandler?.call(sid);

  // sendInput delivers a quick reply: submit=true pastes [text] then presses
  // Enter (or a bare Enter when text is empty — "确认"); submit=false sends the
  // raw keys verbatim (e.g. a menu digit, 'y', or Esc).
  void sendInput(String sid, String text, {bool submit = false}) =>
      inputHandler?.call(sid, text, submit: submit);

  Future<ScreenSnapshot?> loadPreview(String sid) async =>
      previewHandler == null ? null : await previewHandler!(sid);

  // markReviewed reports that the user is now looking at [sid] (opened its
  // quick-reply preview in the overview) so WorkspacePage drops its 待 review
  // highlight. Safe no-op until WorkspacePage registers the handler.
  void markReviewed(String sid) => reviewedHandler?.call(sid);

  // dispatch delivers [m] to a local session, e.g. a "指派待办" click:
  // `overviewStore.dispatch(LocalMsg('', targetSid, todoText, true))`. Returns a
  // human-readable error (unknown/ambiguous target, self-send, …) or null on
  // success; '会话总览未就绪' when WorkspacePage hasn't registered the handler yet
  // (e.g. mobile, where there's no local WorkspacePage at all).
  String? dispatch(LocalMsg m) =>
      dispatchHandler == null ? '会话总览未就绪' : dispatchHandler!(m);

  // spawn starts a new local session for [project] in [workspace] (optionally
  // narrowing to a fresh worktree branch first) and returns (sid, null) on
  // success or (null, error). See [spawnHandler] for the field contract.
  Future<(String? sid, String? error)> spawn({
    required String workspace,
    required String project,
    required String kind,
    String? newWorktreeBranch,
    String? worktreeStart,
    String? resumeAgentSessionId,
    String? workdir,
  }) async {
    if (spawnHandler == null) return (null, '会话总览未就绪');
    return spawnHandler!(
      workspace: workspace,
      project: project,
      kind: kind,
      newWorktreeBranch: newWorktreeBranch,
      worktreeStart: worktreeStart,
      resumeAgentSessionId: resumeAgentSessionId,
      workdir: workdir,
    );
  }

  // captureCapsule freezes [card]'s context into a draft (transcript + distilled
  // persona/seed) for review. Returns (draft, null) or (null, error); the
  // '会话总览未就绪' error covers surfaces with no local WorkspacePage (mobile).
  Future<(CapsuleDraft?, String?)> captureCapsule(
    SessionCard card, {
    required bool preferSelfDistill,
  }) async {
    if (captureCapsuleHandler == null) return (null, '会话总览未就绪');
    return captureCapsuleHandler!(card, preferSelfDistill: preferSelfDistill);
  }

  // submitCapsule ships a (possibly user-edited) capsule draft to the plaza with
  // a visibility of 'private' (个人 — only the owner) or 'public' (公开 — visible
  // to the team via the plaza). Returns (true, null) or (false, error).
  Future<(bool, String?)> submitCapsule(
    CapsuleDraft draft, {
    required String visibility,
    required String summary,
    List<String> skillZips = const [],
  }) async {
    if (submitCapsuleHandler == null) return (false, '会话总览未就绪');
    return submitCapsuleHandler!(
      draft,
      visibility: visibility,
      summary: summary,
      skillZips: skillZips,
    );
  }
}

// CapsuleDraft is the output of a capture+distill pass: a scratch dir holding
// the capsule payloads (transcript.jsonl/.txt, and — when distill succeeded —
// persona.md/seed.md) plus the metadata the submit step needs. The review
// dialog lets the user edit persona/seed in place before submitCapsule ships it.
class CapsuleDraft {
  final String draftDir;
  final String sourceAgent; // 'claude' | 'codex'
  final String? originSessionId;
  final String workdir;
  final bool hasTranscript;
  final bool hasPersona;
  final String label; // source session label, for a default summary
  const CapsuleDraft({
    required this.draftDir,
    required this.sourceAgent,
    required this.originSessionId,
    required this.workdir,
    required this.hasTranscript,
    required this.hasPersona,
    required this.label,
  });
}
