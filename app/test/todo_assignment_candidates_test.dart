import 'package:app/api/models.dart';
import 'package:app/local/todo_assignment_candidates.dart';
import 'package:app/screens/todos_page.dart';
import 'package:flutter/rendering.dart';
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

  test(
    'member role pill width is capped and can shrink to available space',
    () {
      expect(
        todoMemberRolePillMaxWidth(const BoxConstraints(maxWidth: 80)),
        80,
      );
      expect(
        todoMemberRolePillMaxWidth(
          const BoxConstraints(maxWidth: 80),
          maxFraction: 0.45,
        ),
        36,
      );
      expect(
        todoMemberRolePillMaxWidth(const BoxConstraints(maxWidth: 240)),
        128,
      );
      expect(todoMemberRolePillMaxWidth(const BoxConstraints()), 128);
    },
  );

  test('member primary labels prefer display names and mark self', () {
    expect(
      todoMemberPrimaryLabel(
        identity: ' self@x ',
        displayName: ' Self Display ',
        selfIdentity: 'self@x',
      ),
      'Self Display（我）',
    );
    expect(
      todoMemberPrimaryLabel(
        identity: ' member@x ',
        displayName: '   ',
        selfIdentity: 'self@x',
      ),
      'member@x',
    );
    expect(
      todoMemberPrimaryLabel(
        identity: '   ',
        displayName: '   ',
        selfIdentity: 'self@x',
      ),
      '',
    );
  });

  test('todo member display names prefer project labels over team labels', () {
    final names = todoMemberDisplayNames(
      projectMembers: [
        ProjectMember.fromJson({
          'identity': ' dev@x ',
          'display_name': ' Project Dev ',
          'role': 'member',
        }),
        ProjectMember.fromJson({
          'identity': 'blank@x',
          'display_name': '   ',
          'role': 'member',
        }),
      ],
      organizationMembers: [
        OrganizationMember.fromJson({
          'identity': 'dev@x',
          'display_name': ' Team Dev ',
          'role': 'member',
        }),
        OrganizationMember.fromJson({
          'identity': 'blank@x',
          'display_name': ' Team Blank ',
          'role': 'member',
        }),
        OrganizationMember.fromJson({
          'identity': '   ',
          'display_name': 'Ignored',
          'role': 'member',
        }),
      ],
    );

    expect(names, {'dev@x': 'Project Dev', 'blank@x': 'Team Blank'});
  });

  test(
    'online todo member ids trim relay identities and skip offline users',
    () {
      final ids = normalizedOnlineTodoMemberIds([
        OnlineUser.fromJson({'identity': ' member@x ', 'online': true}),
        OnlineUser.fromJson({'identity': 'offline@x', 'online': false}),
        OnlineUser.fromJson({'identity': '   ', 'online': true}),
      ]);

      expect(ids, {'member@x'});
    },
  );

  test('todo dialogs fit narrow screens while keeping desktop width', () {
    expect(todoDialogWidth(const Size(320, 760)), 288);
    expect(todoDialogWidth(const Size(1024, 760)), 440);
    expect(
      todoDialogWidth(
        const Size(360, 760),
        preferred: 480,
        horizontalInset: 20,
      ),
      320,
    );
  });

  test('todo dropdown menus are capped for many projects and groups', () {
    expect(todoMenuMaxHeight(const Size(1024, 900)), 320);
    expect(todoMenuMaxHeight(const Size(320, 420)), closeTo(243.6, 0.001));
    expect(todoMenuMaxHeight(const Size(320, 220)), 160);
  });

  test('custom project roles keep explainable labels for capped pills', () {
    final members = assignableTodoMembers(
      selfIdentity: '',
      includeSelf: false,
      projectMembers: [
        _projectMember(
          'custom@x',
          'custom-project-assignment-role-with-a-very-long-label',
        ),
      ],
      organizationMembers: const [],
    );

    expect(members, [
      (
        identity: 'custom@x',
        roleLabel: '项目custom-project-assignment-role-with-a-very-long-label',
      ),
    ]);
  });
}
