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
      selfIdentity: 'global-admin@x',
      includeSelf: false,
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

    expect(ids, ['member@x', 'viewer@x', 'org-admin@x', 'org-owner@x']);
  });

  test('trims and deduplicates identities while preserving priority order', () {
    final ids = assignableTodoMemberIds(
      selfIdentity: ' owner@x ',
      includeSelf: true,
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

  test('does not keep inaccessible current assignee as assignable', () {
    final ids = assignableTodoMemberIds(
      selfIdentity: 'owner@x',
      includeSelf: true,
      projectMembers: [_projectMember('member@x', 'member')],
      organizationMembers: [_orgMember('admin@x', 'admin')],
    );

    expect(ids, isNot(contains('former@x')));
    expect(ids, ['owner@x', 'member@x', 'admin@x']);
  });

  test('personal todos can include self as the only assignable identity', () {
    final ids = assignableTodoMemberIds(
      selfIdentity: 'owner@x',
      includeSelf: true,
      projectMembers: const [],
      organizationMembers: const [],
    );

    expect(ids, ['owner@x']);
  });

  test('team todos do not include self unless self has project/team role', () {
    final ids = assignableTodoMemberIds(
      selfIdentity: 'global-admin@x',
      includeSelf: false,
      projectMembers: [_projectMember('member@x', 'member')],
      organizationMembers: const [],
    );

    expect(ids, ['member@x']);
    expect(ids, isNot(contains('global-admin@x')));
  });

  test(
    'member labels explain strongest assignment source without reordering',
    () {
      final members = assignableTodoMembers(
        selfIdentity: 'self@x',
        includeSelf: true,
        projectMembers: [
          _projectMember('owner@x', 'owner'),
          _projectMember('viewer@x', 'viewer'),
          _projectMember('org-admin@x', 'member'),
          _projectMember('project-owner-admin@x', 'owner'),
        ],
        organizationMembers: [
          _orgMember('org-admin@x', 'admin'),
          _orgMember('org-owner@x', 'owner'),
          _orgMember('project-owner-admin@x', 'admin'),
        ],
      );

      expect(members, [
        (identity: 'self@x', roleLabel: '个人'),
        (identity: 'owner@x', roleLabel: '项目负责人'),
        (identity: 'viewer@x', roleLabel: '项目只读'),
        (identity: 'org-admin@x', roleLabel: '团队管理员'),
        (identity: 'project-owner-admin@x', roleLabel: '项目负责人'),
        (identity: 'org-owner@x', roleLabel: '团队负责人'),
      ]);
    },
  );
}
