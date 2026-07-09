import '../api/models.dart';
import '../api/todo_models.dart';

// assignableTodoMemberIds mirrors the relay's project-todo assignee gate:
// direct project members are assignable, and team owner/admin are assignable
// through their effective project role. Plain team members/guests still need a
// direct project role.
List<String> assignableTodoMemberIds({
  required String selfIdentity,
  required String currentAssignee,
  required Iterable<ProjectMember> projectMembers,
  required Iterable<OrganizationMember> organizationMembers,
}) {
  final ids = <String>[];
  final seen = <String>{};
  void add(String raw) {
    final id = raw.trim();
    if (id.isEmpty || !seen.add(id)) return;
    ids.add(id);
  }

  add(selfIdentity);
  add(currentAssignee);
  for (final m in projectMembers) {
    add(m.identity);
  }
  for (final m in organizationMembers) {
    final role = m.role.trim();
    if (role == 'owner' || role == 'admin') add(m.identity);
  }
  return ids;
}

// currentAssigneeCandidateName preserves the display overlay for the current
// assignee when they are kept selectable even after losing project/team access.
String currentAssigneeCandidateName(Todo todo) {
  final id = (todo.assigneeIdentity ?? '').trim();
  final name = (todo.assigneeDisplayName ?? '').trim();
  if (id.isEmpty || name.isEmpty || name == id) return '';
  return name;
}
