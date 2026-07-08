import 'package:app/api/models.dart';
import 'package:app/local/todo_assignment_candidates.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectMember _projectMember(String identity, String role) =>
    ProjectMember.fromJson({'identity': identity, 'role': role});

OrganizationMember _orgMember(String identity, String role) =>
    OrganizationMember.fromJson({'identity': identity, 'role': role});

void main() {
  test('includes direct project members and team managers only', () {
    final ids = assignableTodoMemberIds(
      selfIdentity: 'owner@x',
      currentAssignee: 'former@x',
      projectMembers: [
        _projectMember('member@x', 'member'),
        _projectMember('viewer@x', 'viewer'),
        _projectMember('org-admin@x', 'member'),
      ],
      organizationMembers: [
        _orgMember('org-owner@x', 'owner'),
        _orgMember('org-admin@x', 'admin'),
        _orgMember('plain-member@x', 'member'),
        _orgMember('guest@x', 'guest'),
      ],
    );

    expect(ids, [
      'owner@x',
      'former@x',
      'member@x',
      'viewer@x',
      'org-admin@x',
      'org-owner@x',
    ]);
  });

  test('trims and deduplicates identities while preserving priority order', () {
    final ids = assignableTodoMemberIds(
      selfIdentity: ' owner@x ',
      currentAssignee: 'owner@x',
      projectMembers: [
        _projectMember(' member@x ', 'member'),
        _projectMember('member@x', 'viewer'),
      ],
      organizationMembers: [
        _orgMember('owner@x', 'admin'),
        _orgMember(' admin@x ', 'admin'),
      ],
    );

    expect(ids, ['owner@x', 'member@x', 'admin@x']);
  });
}
