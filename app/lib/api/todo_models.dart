// Mirrors pkg/todoschema (the relay's JSON shapes for the Todo feature).
// Kept apart from models.dart because _s/_t are file-private helpers and
// can't be imported across files — each model file writes its own copy.

String _s(dynamic v) => v?.toString() ?? '';

// _sn is the nullable variant: both a missing key and an explicit JSON null
// or empty string collapse to Dart null (project_id/assignee_* are all
// "unset" in that sense — there's no meaningful empty-string state for them).
String? _sn(dynamic v) {
  final s = v?.toString() ?? '';
  return s.isEmpty ? null : s;
}

DateTime _t(dynamic v) =>
    DateTime.tryParse(_s(v))?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);

DateTime? _tn(dynamic v) => v == null ? null : DateTime.tryParse(_s(v))?.toLocal();

int _i(dynamic v) => v is int ? v : int.tryParse(_s(v)) ?? 0;

// TodoStatus is the mutable lifecycle state (unlike handoffs' append-only
// state machine, any of these can transition to any other at any time).
// Declaration order is also the Linear board column order — Triage first as
// the "待分诊" inbox, then the rest of the pipeline through to Duplicate —
// see _boardColumnDefs in todos_page.dart, which iterates TodoStatus.values
// directly rather than re-declaring the order.
enum TodoStatus {
  triage,
  backlog,
  todo,
  inProgress,
  inReview,
  done,
  canceled,
  duplicate,
}

TodoStatus todoStatusFromName(String? n) => switch (n) {
  'triage' => TodoStatus.triage,
  'backlog' => TodoStatus.backlog,
  'todo' => TodoStatus.todo,
  'in_progress' => TodoStatus.inProgress,
  'in_review' => TodoStatus.inReview,
  'done' => TodoStatus.done,
  'canceled' => TodoStatus.canceled,
  'duplicate' => TodoStatus.duplicate,
  _ => TodoStatus.todo,
};

// todoStatusName is the wire form (snake_case) — NOT the same as the enum's
// built-in .name for inProgress/inReview, so callers must use this when
// serialising.
String todoStatusName(TodoStatus s) => switch (s) {
  TodoStatus.triage => 'triage',
  TodoStatus.backlog => 'backlog',
  TodoStatus.todo => 'todo',
  TodoStatus.inProgress => 'in_progress',
  TodoStatus.inReview => 'in_review',
  TodoStatus.done => 'done',
  TodoStatus.canceled => 'canceled',
  TodoStatus.duplicate => 'duplicate',
};

String todoStatusLabel(TodoStatus s) => switch (s) {
  TodoStatus.triage => '待分诊',
  TodoStatus.backlog => '待办池',
  TodoStatus.todo => '待办',
  TodoStatus.inProgress => '进行中',
  TodoStatus.inReview => '待审核',
  TodoStatus.done => '已完成',
  TodoStatus.canceled => '已取消',
  TodoStatus.duplicate => '重复',
};

class TodoAttachment {
  final String name, sha256;
  final int size;
  TodoAttachment.fromJson(Map<String, dynamic> j)
      : name = _s(j['name']),
        sha256 = _s(j['sha256']),
        size = _i(j['size']);
}

class TodoComment {
  final String authorIdentity, body;
  final DateTime createdAt;
  TodoComment.fromJson(Map<String, dynamic> j)
      : authorIdentity = _s(j['author_identity']),
        body = _s(j['body']),
        createdAt = _t(j['created_at']);
}

class Todo {
  final String id;
  final String? projectId; // null = personal
  final String ownerIdentity;
  final String title, bodyMd;
  final TodoStatus status;
  final String priority; // low | normal | high
  final String? assigneeIdentity, assigneeSessionId, assigneeSessionLabel;
  // assigneeAgentSessionId/assigneeWorkdir/assigneeAgentKind are the
  // permanent-resume counterpart to assigneeSessionId: the latter is a bus
  // session id (e.g. "ts2") that goes stale the moment that tab closes,
  // while these three survive it — the real Claude/Codex transcript UUID
  // plus where/what kind of agent it belongs to, so "打开/恢复会话" can
  // respawn the exact same conversation long after the bus id is gone.
  final String? assigneeAgentSessionId, assigneeWorkdir, assigneeAgentKind;
  // workspaceName/repoName are an optional binding to a workspace/repo from
  // the local config tree (see local/config.dart WorkspaceCfg/ProjectCfg) —
  // never required. Both null means "not bound to any repo". Unlike
  // assigneeWorkdir (an absolute path, meaningful only on the machine that
  // set it), these are plain names that stay valid across machines.
  final String? workspaceName, repoName;
  // groupName is a free-form, user-defined bucket (e.g. "我的日常",
  // "xxx项目") — plain string, no separate group entity server-side (see
  // pkg/todoschema.Todo.GroupName). null/empty means ungrouped.
  final String? groupName;
  final String recurrence; // '' | daily | weekly | monthly
  final DateTime? dueAt, nextOccurrenceAt, completedAt;
  final DateTime createdAt, updatedAt;
  final int commentCount, attachmentCount;
  // Only populated by GET-by-id; list responses omit this to avoid N+1 joins.
  final List<TodoAttachment> attachments;
  final String? sourceRef, sourceUrl, sourceProvider, sourceTeamKey;
  final String? sourceProjectId;
  // Linear-side assignee (display name + avatar URL) for the card — shown even
  // when the assignee isn't a relay user (see todoschema.Todo.SourceAssigneeName).
  final String? sourceAssigneeName, sourceAssigneeAvatarUrl;

  Todo({
    required this.id,
    required this.projectId,
    required this.ownerIdentity,
    required this.title,
    required this.bodyMd,
    required this.status,
    required this.priority,
    required this.assigneeIdentity,
    required this.assigneeSessionId,
    required this.assigneeSessionLabel,
    required this.assigneeAgentSessionId,
    required this.assigneeWorkdir,
    required this.assigneeAgentKind,
    required this.workspaceName,
    required this.repoName,
    required this.groupName,
    required this.recurrence,
    required this.dueAt,
    required this.nextOccurrenceAt,
    required this.completedAt,
    required this.createdAt,
    required this.updatedAt,
    required this.commentCount,
    required this.attachmentCount,
    required this.attachments,
    required this.sourceRef,
    required this.sourceUrl,
    required this.sourceProvider,
    required this.sourceTeamKey,
    required this.sourceProjectId,
    required this.sourceAssigneeName,
    required this.sourceAssigneeAvatarUrl,
  });

  factory Todo.fromJson(Map<String, dynamic> j) => Todo(
        id: _s(j['id']),
        projectId: _sn(j['project_id']),
        ownerIdentity: _s(j['owner_identity']),
        title: _s(j['title']),
        bodyMd: _s(j['body_md']),
        status: todoStatusFromName(_s(j['status'])),
        priority: _s(j['priority']).isEmpty ? 'normal' : _s(j['priority']),
        assigneeIdentity: _sn(j['assignee_identity']),
        assigneeSessionId: _sn(j['assignee_session_id']),
        assigneeSessionLabel: _sn(j['assignee_session_label']),
        assigneeAgentSessionId: _sn(j['assignee_agent_session_id']),
        assigneeWorkdir: _sn(j['assignee_workdir']),
        assigneeAgentKind: _sn(j['assignee_agent_kind']),
        workspaceName: _sn(j['workspace_name']),
        repoName: _sn(j['repo_name']),
        groupName: _sn(j['group_name']),
        recurrence: _s(j['recurrence']),
        dueAt: _tn(j['due_at']),
        nextOccurrenceAt: _tn(j['next_occurrence_at']),
        completedAt: _tn(j['completed_at']),
        createdAt: _t(j['created_at']),
        updatedAt: _t(j['updated_at']),
        commentCount: _i(j['comment_count']),
        attachmentCount: _i(j['attachment_count']),
        attachments: (j['attachments'] as List?)
                ?.map((e) => TodoAttachment.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        sourceRef: _sn(j['source_ref']),
        sourceUrl: _sn(j['source_url']),
        sourceProvider: _sn(j['source_provider']),
        sourceTeamKey: _sn(j['source_team_key']),
        sourceProjectId: _sn(j['source_project_id']),
        sourceAssigneeName: _sn(j['source_assignee_name']),
        sourceAssigneeAvatarUrl: _sn(j['source_assignee_avatar_url']),
      );

  // PATCH /v1/todos/{id} and the status-update endpoint both reuse the bare
  // row scan (no attachments join, to dodge an N+1) — so their responses
  // always carry an empty `attachments`, unlike GET-by-id. Callers applying
  // one of those responses on top of an already-loaded Todo should use
  // copyWith to keep the previously-fetched attachment list instead of
  // clobbering it back to empty.
  Todo copyWith({List<TodoAttachment>? attachments}) => Todo(
        id: id,
        projectId: projectId,
        ownerIdentity: ownerIdentity,
        title: title,
        bodyMd: bodyMd,
        status: status,
        priority: priority,
        assigneeIdentity: assigneeIdentity,
        assigneeSessionId: assigneeSessionId,
        assigneeSessionLabel: assigneeSessionLabel,
        assigneeAgentSessionId: assigneeAgentSessionId,
        assigneeWorkdir: assigneeWorkdir,
        assigneeAgentKind: assigneeAgentKind,
        workspaceName: workspaceName,
        repoName: repoName,
        groupName: groupName,
        recurrence: recurrence,
        dueAt: dueAt,
        nextOccurrenceAt: nextOccurrenceAt,
        completedAt: completedAt,
        createdAt: createdAt,
        updatedAt: updatedAt,
        commentCount: commentCount,
        attachmentCount: attachmentCount,
        attachments: attachments ?? this.attachments,
        sourceRef: sourceRef,
        sourceUrl: sourceUrl,
        sourceProvider: sourceProvider,
        sourceTeamKey: sourceTeamKey,
        sourceProjectId: sourceProjectId,
        sourceAssigneeName: sourceAssigneeName,
        sourceAssigneeAvatarUrl: sourceAssigneeAvatarUrl,
      );

  // scope is never sent by the relay — it's derived locally so the UI can
  // split "个人待办" vs "团队待办" without a server-side concept of scope.
  // Uses the same string values as the `scope` query param (personal/project)
  // so it round-trips cleanly through RelayClient.todos(scope: ...).
  bool get isPersonal => projectId == null;
  String get scope => isPersonal ? 'personal' : 'project';
  bool get isLinear =>
      sourceProvider == 'linear' || (sourceRef ?? '').startsWith('linear:');
}
