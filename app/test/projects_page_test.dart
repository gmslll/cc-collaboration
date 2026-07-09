import 'package:app/api/models.dart';
import 'package:app/screens/projects_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('global admin can manage organizations without an org role', () {
    final org = Organization.fromJson({
      'id': 'org1',
      'name': 'Kunlun',
      'owner_identity': 'owner@x',
      'role': '',
    });

    expect(canManageOrganization(org, isAdmin: true), isTrue);
    expect(canManageOrganization(org, isAdmin: false), isFalse);
  });

  test('organization owner and admin roles can manage organizations', () {
    Organization orgWithRole(String role) => Organization.fromJson({
      'id': 'org1',
      'name': 'Kunlun',
      'owner_identity': 'owner@x',
      'role': role,
    });

    expect(canManageOrganization(orgWithRole('owner'), isAdmin: false), isTrue);
    expect(canManageOrganization(orgWithRole('admin'), isAdmin: false), isTrue);
    expect(
      canManageOrganization(orgWithRole('member'), isAdmin: false),
      isFalse,
    );
    expect(
      canManageOrganization(orgWithRole('guest'), isAdmin: false),
      isFalse,
    );
  });

  test('organization role label reflects global admin fallback', () {
    expect(organizationRoleLabel('', isAdmin: true), '系统管理员');
    expect(organizationRoleLabel('', isAdmin: false), '成员');
    expect(organizationRoleLabel('owner', isAdmin: true), '负责人');
    expect(organizationRoleLabel('admin', isAdmin: true), '管理员');
    expect(organizationRoleLabel('member', isAdmin: true), '成员');
    expect(organizationRoleLabel('guest', isAdmin: true), '访客');
  });

  test(
    'organization editable role value falls back to a dropdown-safe role',
    () {
      expect(organizationEditableRoleValue(' owner '), 'owner');
      expect(organizationEditableRoleValue('admin'), 'admin');
      expect(organizationEditableRoleValue('member'), 'member');
      expect(organizationEditableRoleValue('guest'), 'guest');
      expect(organizationEditableRoleValue(''), 'member');
      expect(organizationEditableRoleValue('custom'), 'member');
    },
  );

  test('project role label uses team-facing Chinese labels', () {
    expect(projectRoleLabel(''), '成员');
    expect(projectRoleLabel('admin'), '管理员');
    expect(projectRoleLabel('owner'), '负责人');
    expect(projectRoleLabel('member'), '成员');
    expect(projectRoleLabel('viewer'), '只读');
    expect(projectRoleLabel('custom'), 'custom');
  });

  test('project editable role value falls back to a dropdown-safe role', () {
    expect(projectEditableRoleValue(' owner '), 'owner');
    expect(projectEditableRoleValue('member'), 'member');
    expect(projectEditableRoleValue('viewer'), 'viewer');
    expect(projectEditableRoleValue(''), 'member');
    expect(projectEditableRoleValue('custom'), 'member');
  });

  test('project list role label uses conservative fallback', () {
    Project project({String role = '', String owner = 'owner@x'}) =>
        Project.fromJson({
          'id': 'p1',
          'name': 'P',
          'owner_identity': owner,
          'role': role,
        });

    expect(
      projectListRoleLabel(
        project(role: 'member'),
        isAdmin: false,
        identity: 'viewer@x',
      ),
      '成员',
    );
    expect(
      projectListRoleLabel(project(), isAdmin: true, identity: 'admin@x'),
      '管理员',
    );
    expect(
      projectListRoleLabel(project(), isAdmin: false, identity: ' owner@x '),
      '负责人',
    );
    expect(
      projectListRoleLabel(project(), isAdmin: false, identity: 'member@x'),
      '只读',
    );
  });

  test('organization member picker label localizes roles', () {
    final named = OrganizationMember.fromJson({
      'identity': 'dev@x',
      'role': 'admin',
      'display_name': 'Dev',
    });
    final unnamed = OrganizationMember.fromJson({
      'identity': 'ops@x',
      'role': 'guest',
    });

    expect(organizationMemberPickerLabel(named), 'Dev · dev@x · 管理员');
    expect(organizationMemberPickerLabel(unnamed), 'ops@x · 访客');
  });

  test('organization member picker ignores blank display names', () {
    final member = OrganizationMember.fromJson({
      'identity': ' ops@x ',
      'role': ' guest ',
      'display_name': '   ',
    });

    expect(organizationMemberPickerLabel(member), 'ops@x · 访客');
  });

  test('organization member role updates protect the last owner', () {
    final owner = OrganizationMember.fromJson({
      'identity': ' owner@x ',
      'role': 'owner',
    });
    final member = OrganizationMember.fromJson({
      'identity': 'member@x',
      'role': 'member',
    });
    final secondOwner = OrganizationMember.fromJson({
      'identity': 'owner2@x',
      'role': 'owner',
    });

    expect(organizationOwnerCount([owner, member]), 1);
    expect(canRemoveOrganizationMember(owner, [owner, member]), isFalse);
    expect(canRemoveOrganizationMember(member, [owner, member]), isTrue);
    expect(
      canUpsertOrganizationMemberRole('owner@x', 'admin', [owner, member]),
      isFalse,
    );
    expect(
      canUpsertOrganizationMemberRole('owner@x', 'guest', [owner, member]),
      isFalse,
    );
    expect(
      canUpsertOrganizationMemberRole('owner@x', 'owner', [owner, member]),
      isTrue,
    );
    expect(
      canUpsertOrganizationMemberRole('owner@x', 'member', [
        owner,
        secondOwner,
        member,
      ]),
      isTrue,
    );
    expect(
      canUpsertOrganizationMemberRole('new@x', 'admin', [owner, member]),
      isTrue,
    );
    expect(canUpsertOrganizationMemberRole('', 'member', [owner]), isFalse);
  });

  test('organization removal block reasons are stricter than role changes', () {
    final owner = OrganizationMember.fromJson({
      'identity': 'owner@x',
      'role': 'owner',
    });
    final member = OrganizationMember.fromJson({
      'identity': 'member@x',
      'role': 'member',
    });
    final secondOwner = OrganizationMember.fromJson({
      'identity': 'owner2@x',
      'role': 'owner',
    });

    expect(
      organizationMemberRoleChangeBlockReason(owner, [owner, member]),
      '至少保留一个负责人',
    );
    expect(
      organizationMemberRemovalBlockReason(
        owner,
        [owner, member],
        const [],
        projectOwnerGuardComplete: true,
      ),
      '至少保留一个负责人',
    );

    expect(
      organizationMemberRoleChangeBlockReason(owner, [
        owner,
        secondOwner,
        member,
      ]),
      isNull,
    );
    expect(
      organizationMemberRemovalBlockReason(
        owner,
        [owner, secondOwner, member],
        const ['Solo'],
        projectOwnerGuardComplete: true,
      ),
      '先转移项目负责人: Solo',
    );
    expect(
      organizationMemberRemovalBlockReason(
        member,
        [owner, member],
        const [],
        projectOwnerGuardComplete: false,
        uncheckedProjectNames: const ['Solo'],
      ),
      '项目负责人状态未确认: Solo',
    );
    expect(projectOwnerGuardMessage(const []), '项目负责人状态未确认');
    expect(
      projectOwnerGuardMessage(const [' Solo ', 'Ops']),
      '项目负责人状态未确认: Solo, Ops',
    );
    expect(
      organizationMemberRemovalBlockReason(
        member,
        [owner, member],
        const [],
        projectOwnerGuardComplete: true,
      ),
      isNull,
    );
  });

  test('project owner label uses localized owner text', () {
    expect(projectOwnerLabel('owner@x'), '负责人 · owner@x');
  });

  test(
    'project member display prefers display name with identity subtitle',
    () {
      final named = ProjectMember.fromJson({
        'identity': 'dev@x',
        'role': 'member',
        'display_name': 'Dev',
      });
      final unnamed = ProjectMember.fromJson({
        'identity': 'ops@x',
        'role': 'viewer',
      });

      expect(projectMemberTitle(named), 'Dev');
      expect(projectMemberSubtitle(named), 'dev@x');
      expect(projectMemberTitle(unnamed), 'ops@x');
      expect(projectMemberSubtitle(unnamed), isNull);
    },
  );

  test('project member display trims names and falls back on blank names', () {
    final named = ProjectMember.fromJson({
      'identity': ' dev@x ',
      'role': ' member ',
      'display_name': ' Dev ',
    });
    final blank = ProjectMember.fromJson({
      'identity': ' ops@x ',
      'role': ' viewer ',
      'display_name': '   ',
    });

    expect(projectMemberTitle(named), 'Dev');
    expect(projectMemberSubtitle(named), 'dev@x');
    expect(projectMemberTitle(blank), 'ops@x');
    expect(projectMemberSubtitle(blank), isNull);
  });

  test('project member removal protects the last project owner', () {
    final owner = ProjectMember.fromJson({
      'identity': 'owner@x',
      'role': 'owner',
    });
    final member = ProjectMember.fromJson({
      'identity': 'member@x',
      'role': 'member',
    });
    final secondOwner = ProjectMember.fromJson({
      'identity': 'owner2@x',
      'role': 'owner',
    });

    expect(projectOwnerCount([owner, member]), 1);
    expect(canRemoveProjectMember(owner, [owner, member]), isFalse);
    expect(canRemoveProjectMember(member, [owner, member]), isTrue);
    expect(canRemoveProjectMember(owner, [owner, secondOwner, member]), isTrue);
  });

  test('project member role change reason protects the last project owner', () {
    final owner = ProjectMember.fromJson({
      'identity': 'owner@x',
      'role': 'owner',
    });
    final member = ProjectMember.fromJson({
      'identity': 'member@x',
      'role': 'member',
    });
    final secondOwner = ProjectMember.fromJson({
      'identity': 'owner2@x',
      'role': 'owner',
    });

    expect(
      projectMemberRoleChangeBlockReason(owner, [owner, member]),
      '至少保留一个项目负责人',
    );
    expect(projectMemberRoleChangeBlockReason(member, [owner, member]), isNull);
    expect(
      projectMemberRoleChangeBlockReason(owner, [owner, secondOwner, member]),
      isNull,
    );
  });

  test('project member role updates protect the last project owner', () {
    final owner = ProjectMember.fromJson({
      'identity': ' owner@x ',
      'role': 'owner',
    });
    final member = ProjectMember.fromJson({
      'identity': 'member@x',
      'role': 'member',
    });
    final secondOwner = ProjectMember.fromJson({
      'identity': 'owner2@x',
      'role': 'owner',
    });

    expect(canUpsertProjectMemberRole('', 'member', [owner]), isFalse);
    expect(
      canUpsertProjectMemberRole('owner@x', 'member', [owner, member]),
      isFalse,
    );
    expect(
      canUpsertProjectMemberRole('owner@x', 'viewer', [owner, member]),
      isFalse,
    );
    expect(
      canUpsertProjectMemberRole('owner@x', 'owner', [owner, member]),
      isTrue,
    );
    expect(
      canUpsertProjectMemberRole('owner@x', 'member', [
        owner,
        secondOwner,
        member,
      ]),
      isTrue,
    );
    expect(
      canUpsertProjectMemberRole('new@x', 'viewer', [owner, member]),
      isTrue,
    );
  });

  test('sole project owner map only includes projects with one owner', () {
    ProjectDetail detail({
      required String name,
      required List<Map<String, Object?>> members,
    }) => ProjectDetail.fromJson({
      'project': {
        'id': name.toLowerCase(),
        'name': name,
        'owner_identity': 'owner@x',
      },
      'repos': const [],
      'members': members,
    });

    final got = soleProjectOwnerNamesByIdentity([
      detail(
        name: 'Solo',
        members: [
          {'identity': ' owner@x ', 'role': 'owner'},
          {'identity': 'member@x', 'role': 'member'},
        ],
      ),
      detail(
        name: 'Shared',
        members: [
          {'identity': 'owner@x', 'role': 'owner'},
          {'identity': 'owner2@x', 'role': 'owner'},
        ],
      ),
      detail(
        name: 'Ops',
        members: [
          {'identity': 'ops@x', 'role': 'owner'},
        ],
      ),
    ]);

    expect(got, {
      'owner@x': ['Solo'],
      'ops@x': ['Ops'],
    });
  });

  test(
    'team workspace stats count manageable teams and unique online users',
    () {
      Organization org(String id) => Organization.fromJson({
        'id': id,
        'name': id,
        'owner_identity': 'owner@x',
        'role': 'member',
      });
      Project project(String id, String orgId) => Project.fromJson({
        'id': id,
        'org_id': orgId,
        'name': id,
        'owner_identity': 'owner@x',
        'role': 'member',
      });
      OnlineUser online(String identity, bool isOnline) =>
          OnlineUser.fromJson({'identity': identity, 'online': isOnline});

      final stats = teamWorkspaceStats(
        organizations: [org('org-a'), org('org-b')],
        projects: [project('p1', 'org-a'), project('p2', 'org-b')],
        onlineUsers: [
          online('alice@x', true),
          online('alice@x', true),
          online('bob@x', false),
          online('   ', true),
        ],
        manageableOrgIds: {'org-a', 'missing-org'},
      );

      expect(stats.teams, 2);
      expect(stats.manageableTeams, 1);
      expect(stats.projects, 2);
      expect(stats.onlineUsers, 1);
    },
  );
}
