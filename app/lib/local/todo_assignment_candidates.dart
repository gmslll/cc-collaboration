import '../api/models.dart';

// assignableTodoMemberIds mirrors the relay's assignee gate. Personal todos may
// assign to self; team todos may assign only to direct project members or team
// owner/admin through their effective project role. Plain team members/guests
// still need a direct project role.
List<String> assignableTodoMemberIds({
  required String selfIdentity,
  required bool includeSelf,
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

  if (includeSelf) add(selfIdentity);
  for (final m in projectMembers) {
    add(m.identity);
  }
  for (final m in organizationMembers) {
    final role = m.role.trim();
    if (role == 'owner' || role == 'admin') add(m.identity);
  }
  return ids;
}
