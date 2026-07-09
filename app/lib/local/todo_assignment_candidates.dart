import '../api/models.dart';

typedef AssignableTodoMember = ({String identity, String roleLabel});

// assignableTodoMembers mirrors the relay's assignee gate. Personal todos may
// assign to self; team todos may assign only to direct project members or team
// owner/admin through their effective project role. Plain team members/guests
// still need a direct project role.
List<AssignableTodoMember> assignableTodoMembers({
  required String selfIdentity,
  required bool includeSelf,
  required Iterable<ProjectMember> projectMembers,
  required Iterable<OrganizationMember> organizationMembers,
}) {
  final members = <AssignableTodoMember>[];
  final seen = <String>{};
  final ranks = <String, int>{};
  void add(String raw, String roleLabel, int rank) {
    final id = raw.trim();
    if (id.isEmpty) return;
    if (seen.add(id)) {
      ranks[id] = rank;
      members.add((identity: id, roleLabel: roleLabel));
      return;
    }
    if (rank <= (ranks[id] ?? 0)) return;
    ranks[id] = rank;
    final index = members.indexWhere((m) => m.identity == id);
    if (index >= 0) {
      members[index] = (identity: id, roleLabel: roleLabel);
    }
  }

  if (includeSelf) add(selfIdentity, '个人', 100);
  for (final m in projectMembers) {
    final role = m.role.trim();
    add(m.identity, _projectAssignmentRoleLabel(role), _projectRoleRank(role));
  }
  for (final m in organizationMembers) {
    final role = m.role.trim();
    if (role == 'owner' || role == 'admin') {
      add(
        m.identity,
        _teamManagerAssignmentRoleLabel(role),
        _teamRoleRank(role),
      );
    }
  }
  return members;
}

List<String> assignableTodoMemberIds({
  required String selfIdentity,
  required bool includeSelf,
  required Iterable<ProjectMember> projectMembers,
  required Iterable<OrganizationMember> organizationMembers,
}) => [
  for (final m in assignableTodoMembers(
    selfIdentity: selfIdentity,
    includeSelf: includeSelf,
    projectMembers: projectMembers,
    organizationMembers: organizationMembers,
  ))
    m.identity,
];

String _projectAssignmentRoleLabel(String raw) {
  switch (raw.trim()) {
    case 'owner':
      return '项目负责人';
    case 'admin':
      return '项目管理员';
    case 'viewer':
      return '项目只读';
    case 'member':
    case '':
      return '项目成员';
    default:
      return '项目${raw.trim()}';
  }
}

String _teamManagerAssignmentRoleLabel(String role) {
  switch (role) {
    case 'owner':
      return '团队负责人';
    case 'admin':
      return '团队管理员';
    default:
      return '团队成员';
  }
}

int _projectRoleRank(String role) {
  switch (role) {
    case 'owner':
      return 90;
    case 'admin':
      return 80;
    case 'member':
      return 30;
    case 'viewer':
      return 20;
    default:
      return 10;
  }
}

int _teamRoleRank(String role) {
  switch (role) {
    case 'owner':
      return 85;
    case 'admin':
      return 80;
    default:
      return 10;
  }
}
