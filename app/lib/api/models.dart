// Mirrors pkg/handoffschema (the relay's JSON shapes) — only the fields the GUI
// renders.

String _s(dynamic v) => v?.toString() ?? '';
String _trimmed(dynamic v) => _s(v).trim();

DateTime _t(dynamic v) =>
    DateTime.tryParse(_s(v))?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);

class ListItem {
  final String id, kind, sender, recipient, urgency, state, repoName, branch, headline;
  final DateTime createdAt;

  ListItem.fromJson(Map<String, dynamic> j)
    : id = _s(j['id']),
      kind = j['kind'] == null || _s(j['kind']).isEmpty ? 'delivery' : _s(j['kind']),
      sender = _s(j['sender']),
      recipient = _s(j['recipient']),
      urgency = _s(j['urgency']).isEmpty ? 'normal' : _s(j['urgency']),
      state = _s(j['state']),
      repoName = _s(j['repo_name']),
      branch = _s(j['branch']),
      headline = _s(j['headline']),
      createdAt = _t(j['created_at']);
}

// CapsuleListItem is one plaza row (GET /v1/capsules) — mirrors
// handoffschema.CapsuleListItem.
class CapsuleListItem {
  final String id, owner, visibility, sourceAgent, originSessionId, headline, repoName;
  final bool hasTranscript, hasPersona;
  final DateTime createdAt;

  CapsuleListItem.fromJson(Map<String, dynamic> j)
    : id = _s(j['id']),
      owner = _s(j['owner']),
      visibility = _s(j['visibility']), // server normalizes (never empty)
      sourceAgent = _s(j['source_agent']),
      originSessionId = _s(j['origin_session_id']),
      headline = _s(j['headline']),
      repoName = _s(j['repo_name']),
      hasTranscript = j['has_transcript'] == true,
      hasPersona = j['has_persona'] == true,
      createdAt = _t(j['created_at']);
}

class Repo {
  final String name, branch;
  Repo.fromJson(Map<String, dynamic>? j) : name = _s(j?['name']), branch = _s(j?['branch']);
}

class Package {
  final String id, kind, sender, recipient, urgency, summaryMd, noteMd, prdMd;
  final Repo repo;
  final DeliveryTarget? deliveryTarget;
  final List<String> modulePaths;
  final List<Attachment> attachments;
  final Git? git;
  final ApiDelta? apiDelta;

  Package.fromJson(Map<String, dynamic> j)
    : id = _s(j['id']),
      kind = _s(j['kind']).isEmpty ? 'delivery' : _s(j['kind']),
      sender = _s(j['sender']),
      recipient = _s(j['recipient']),
      urgency = _s(j['urgency']).isEmpty ? 'normal' : _s(j['urgency']),
      summaryMd = _s(j['summary_md']),
      noteMd = _s(j['note_md']),
      prdMd = _s(j['prd_md']),
      repo = Repo.fromJson(j['repo'] as Map<String, dynamic>?),
      deliveryTarget = DeliveryTarget.fromJsonOrNull(j['delivery_target']),
      modulePaths = (j['module_paths'] as List?)?.map((e) => _s(e)).toList() ?? const [],
      attachments =
          (j['attachments'] as List?)
              ?.map((e) => Attachment.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      git = j['git'] is Map ? Git.fromJson(j['git'] as Map<String, dynamic>) : null,
      apiDelta = j['api_delta'] is Map
          ? ApiDelta.fromJson(j['api_delta'] as Map<String, dynamic>)
          : null;
}

class DeliveryTarget {
  final String projectId, orgId, member;

  const DeliveryTarget({required this.projectId, required this.orgId, required this.member});

  static DeliveryTarget? fromJsonOrNull(dynamic v) {
    if (v is! Map<String, dynamic>) return null;
    final target = DeliveryTarget(
      projectId: _trimmed(v['project_id']),
      orgId: _trimmed(v['org_id']),
      member: _trimmed(v['member']),
    );
    return target.isEmpty ? null : target;
  }

  bool get isEmpty => projectId.isEmpty && orgId.isEmpty && member.isEmpty;
}

String deliveryTargetLabel(DeliveryTarget target) {
  final parts = <String>[];
  if (target.projectId.isNotEmpty) parts.add('项目 ${target.projectId}');
  if (target.orgId.isNotEmpty) parts.add('团队 ${target.orgId}');
  if (target.member.isNotEmpty) parts.add('成员 ${target.member}');
  return parts.join(' · ');
}

class Attachment {
  final String name, sha256;
  final int size;
  Attachment.fromJson(Map<String, dynamic> j)
    : name = _s(j['name']),
      sha256 = _s(j['sha256']),
      size = j['size'] is int ? j['size'] as int : int.tryParse(_s(j['size'])) ?? 0;
}

class Commit {
  final String sha, subject, body;
  Commit.fromJson(Map<String, dynamic> j)
    : sha = _s(j['sha']),
      subject = _s(j['subject']),
      body = _s(j['body']);
}

class Git {
  final List<Commit> commits;
  final List<String> changedPaths;
  Git.fromJson(Map<String, dynamic> j)
    : commits =
          (j['commits'] as List?)
              ?.map((e) => Commit.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      changedPaths = (j['changed_paths'] as List?)?.map(_s).toList() ?? const [];
}

// ApiOp keeps only the summary fields the detail view shows (method/path/
// summary) — mirrors the web UI's API-delta rendering.
class ApiOp {
  final String method, path, summary;
  ApiOp.fromJson(Map<String, dynamic> j)
    : method = _s(j['method']),
      path = _s(j['path']),
      summary = _s(j['summary']);
}

class ApiDelta {
  final List<ApiOp> added, changed, removed;
  ApiDelta.fromJson(Map<String, dynamic> j)
    : added = _ops(j['added']),
      changed = _ops(j['changed']),
      removed = _ops(j['removed']);
  static List<ApiOp> _ops(dynamic v) =>
      (v as List?)?.map((e) => ApiOp.fromJson(e as Map<String, dynamic>)).toList() ?? const [];
  bool get isEmpty => added.isEmpty && changed.isEmpty && removed.isEmpty;
}

class Status {
  final String state, sender, recipient;
  final DateTime createdAt;
  final DateTime? pickedAt;
  final int commentCount;
  Status.fromJson(Map<String, dynamic> j)
    : state = _s(j['state']),
      sender = _s(j['sender']),
      recipient = _s(j['recipient']),
      createdAt = _t(j['created_at']),
      pickedAt = j['picked_at'] == null ? null : _t(j['picked_at']),
      commentCount = j['comment_count'] is int ? j['comment_count'] as int : 0;
}

class Comment {
  final String sender, body;
  final DateTime createdAt;
  Comment.fromJson(Map<String, dynamic> j)
    : sender = _s(j['sender']),
      body = _s(j['body']),
      createdAt = _t(j['created_at']);
}

// --- multi-tenant (F3) ---

class ProjectRole {
  final String id, orgId, name, role;
  ProjectRole.fromJson(Map<String, dynamic> j)
    : id = _trimmed(j['id']),
      orgId = _trimmed(j['org_id']),
      name = _trimmed(j['name']),
      role = _trimmed(j['role']);
}

class OrganizationRole {
  final String id, name, role;
  OrganizationRole.fromJson(Map<String, dynamic> j)
    : id = _trimmed(j['id']),
      name = _trimmed(j['name']),
      role = _trimmed(j['role']);
}

class Me {
  final String identity;
  final bool isAdmin;
  final List<OrganizationRole> organizations;
  final List<ProjectRole> projects;
  Me.fromJson(Map<String, dynamic> j)
    : identity = _trimmed(j['identity']),
      isAdmin = j['is_admin'] == true,
      organizations =
          (j['organizations'] as List?)
              ?.map((e) => OrganizationRole.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      projects =
          (j['projects'] as List?)
              ?.map((e) => ProjectRole.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [];

  // Minimal valid identity: a non-admin member with no projects. Used as a
  // fallback when the real role isn't known yet (e.g. /v1/me unreachable at
  // launch) so consumers always get a legal Me instead of null.
  const Me.member(this.identity) : isAdmin = false, organizations = const [], projects = const [];
}

class Organization {
  final String id, name, ownerIdentity, role;
  Organization.fromJson(Map<String, dynamic> j)
    : id = _trimmed(j['id']),
      name = _trimmed(j['name']),
      ownerIdentity = _trimmed(j['owner_identity']),
      role = _trimmed(j['role']);
}

class OrganizationMember {
  final String identity, role, displayName;
  OrganizationMember.fromJson(Map<String, dynamic> j)
    : identity = _trimmed(j['identity']),
      role = _trimmed(j['role']),
      displayName = _trimmed(j['display_name']);
}

class OrganizationDetail {
  final Organization organization;
  final List<OrganizationMember> members;
  final List<Project> projects;
  OrganizationDetail.fromJson(Map<String, dynamic> j)
    : organization = Organization.fromJson((j['organization'] ?? const {}) as Map<String, dynamic>),
      members =
          (j['members'] as List?)
              ?.map((e) => OrganizationMember.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      projects =
          (j['projects'] as List?)
              ?.map((e) => Project.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [];
}

class Project {
  final String id, orgId, name, ownerIdentity, role;
  Project.fromJson(Map<String, dynamic> j)
    : id = _trimmed(j['id']),
      orgId = _trimmed(j['org_id']),
      name = _trimmed(j['name']),
      ownerIdentity = _trimmed(j['owner_identity']),
      role = _trimmed(j['role']);
}

class ProjectMember {
  final String identity, role, displayName;
  ProjectMember.fromJson(Map<String, dynamic> j)
    : identity = _trimmed(j['identity']),
      role = _trimmed(j['role']),
      // Empty on a relay that predates the display_name join (getProject) —
      // the member picker then falls back to showing the raw identity.
      displayName = _trimmed(j['display_name']);
}

class ProjectDetail {
  final Project project;
  final List<String> repos;
  final List<ProjectMember> members;
  ProjectDetail.fromJson(Map<String, dynamic> j)
    : project = Project.fromJson((j['project'] ?? const {}) as Map<String, dynamic>),
      repos = (j['repos'] as List?)?.map(_s).toList() ?? const [],
      members =
          (j['members'] as List?)
              ?.map((e) => ProjectMember.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [];
}

class OnlineUser {
  final String identity;
  final bool online;
  OnlineUser.fromJson(Map<String, dynamic> j)
    : identity = _trimmed(j['identity']),
      online = j['online'] == true;
}

// RemoteSession is one open terminal session another user published to the relay
// (GET /v1/users/{identity}/sessions) — a target for cross-user "发送到会话".
class RemoteSession {
  final String id, label, project, workdir;
  RemoteSession.fromJson(Map<String, dynamic> j)
    : id = _s(j['id']),
      label = _s(j['label']),
      project = _s(j['project']),
      workdir = _s(j['workdir']);
}

class MachineToken {
  final String id, label;
  final DateTime createdAt;
  MachineToken.fromJson(Map<String, dynamic> j)
    : id = _s(j['id']),
      label = _s(j['label']),
      createdAt = _t(j['created_at']);
}

class User {
  final String identity, displayName;
  final bool isAdmin, disabled;
  User.fromJson(Map<String, dynamic> j)
    : identity = _trimmed(j['identity']),
      displayName = _trimmed(j['display_name']),
      isAdmin = j['is_admin'] == true,
      disabled = j['disabled'] == true;
}
