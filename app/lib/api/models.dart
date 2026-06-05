// Mirrors pkg/handoffschema (the relay's JSON shapes) — only the fields the GUI
// renders.

String _s(dynamic v) => v?.toString() ?? '';

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

class Repo {
  final String name, branch;
  Repo.fromJson(Map<String, dynamic>? j)
      : name = _s(j?['name']),
        branch = _s(j?['branch']);
}

class Package {
  final String id, kind, sender, recipient, summaryMd, noteMd, prdMd;
  final Repo repo;
  final List<String> modulePaths;

  Package.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        kind = _s(j['kind']).isEmpty ? 'delivery' : _s(j['kind']),
        sender = _s(j['sender']),
        recipient = _s(j['recipient']),
        summaryMd = _s(j['summary_md']),
        noteMd = _s(j['note_md']),
        prdMd = _s(j['prd_md']),
        repo = Repo.fromJson(j['repo'] as Map<String, dynamic>?),
        modulePaths =
            (j['module_paths'] as List?)?.map((e) => _s(e)).toList() ?? const [];
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
  final String id, name, role;
  ProjectRole.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        role = _s(j['role']);
}

class Me {
  final String identity;
  final bool isAdmin;
  final List<ProjectRole> projects;
  Me.fromJson(Map<String, dynamic> j)
      : identity = _s(j['identity']),
        isAdmin = j['is_admin'] == true,
        projects = (j['projects'] as List?)
                ?.map((e) => ProjectRole.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [];
}

class Project {
  final String id, name, ownerIdentity;
  Project.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        ownerIdentity = _s(j['owner_identity']);
}

class ProjectMember {
  final String identity, role;
  ProjectMember.fromJson(Map<String, dynamic> j)
      : identity = _s(j['identity']),
        role = _s(j['role']);
}

class ProjectDetail {
  final Project project;
  final List<String> repos;
  final List<ProjectMember> members;
  ProjectDetail.fromJson(Map<String, dynamic> j)
      : project = Project.fromJson((j['project'] ?? const {}) as Map<String, dynamic>),
        repos = (j['repos'] as List?)?.map(_s).toList() ?? const [],
        members = (j['members'] as List?)
                ?.map((e) => ProjectMember.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [];
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
      : identity = _s(j['identity']),
        displayName = _s(j['display_name']),
        isAdmin = j['is_admin'] == true,
        disabled = j['disabled'] == true;
}
