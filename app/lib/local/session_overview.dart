import 'package:flutter/foundation.dart';

// Shared, UI-free projection of a terminal session for the "会话总览" surface.
//
// A glanceable snapshot — label, workspace→project→worktree hierarchy, status,
// token usage, and a preview of the agent's latest reply — produced ONCE by the
// desktop WorkspacePage (the owner of the live sessions) and consumed by BOTH:
//   - the desktop top-level SessionOverviewPage (via SessionOverviewStore), and
//   - the phone overview (serialised over the relay's `overview` frame).
// Kept in lib/local so it carries no screens/ import; both ends + the remote
// layer share the same type.

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
  final String? worktree; // worktree name (null at project root)
  final SessionStatus status;
  final String statusDetail; // richer live state derived from recent hook events
  final String? usageLabel; // SessionUsage.shortLabel(), or null
  final String preview; // latest assistant reply / terminal tail

  const SessionCard({
    required this.sid,
    required this.label,
    required this.agentKind,
    required this.isAgent,
    required this.workspace,
    required this.project,
    required this.worktree,
    required this.status,
    this.statusDetail = '',
    required this.usageLabel,
    required this.preview,
  });

  Map<String, dynamic> toJson() => {
    'sid': sid,
    'label': label,
    'agent': agentKind,
    'isAgent': isAgent,
    'ws': workspace,
    'proj': project,
    'wt': worktree,
    'status': status.name,
    'statusDetail': statusDetail,
    'usage': usageLabel,
    'preview': preview,
  };

  factory SessionCard.fromJson(Map<dynamic, dynamic> m) => SessionCard(
    sid: (m['sid'] ?? '').toString(),
    label: (m['label'] ?? '').toString(),
    agentKind: (m['agent'] ?? '').toString(),
    isAgent: m['isAgent'] == true,
    workspace: (m['ws'] ?? '').toString(),
    project: (m['proj'] ?? '').toString(),
    worktree: m['wt']?.toString(),
    status: sessionStatusFromName(m['status'] as String?),
    statusDetail: (m['statusDetail'] ?? '').toString(),
    usageLabel: m['usage']?.toString(),
    preview: (m['preview'] ?? '').toString(),
  );
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
  Future<String?> Function(String sid)? previewHandler;
  // reviewedHandler marks a session as "已查看" — the overview page can't reach
  // `terms`, so opening the quick-reply preview routes through here to let
  // WorkspacePage clear that session's 待 review flag (the same "the user is
  // looking at it" semantics as local foregrounding / a phone watching it).
  void Function(String sid)? reviewedHandler;

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

  Future<String?> loadPreview(String sid) async =>
      previewHandler == null ? null : await previewHandler!(sid);

  // markReviewed reports that the user is now looking at [sid] (opened its
  // quick-reply preview in the overview) so WorkspacePage drops its 待 review
  // highlight. Safe no-op until WorkspacePage registers the handler.
  void markReviewed(String sid) => reviewedHandler?.call(sid);
}
