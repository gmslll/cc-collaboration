import 'dart:async';
import 'dart:io';

import 'package:app/api/models.dart';
import 'package:app/api/relay_client.dart';
import 'package:app/screens/projects_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _longTeamName =
    'Kunlun International Collaboration Operations Team With A Very Long Name';
const _longProjectName =
    'Backend Freight Control Surface For Multi Team Dispatch Coordination';
const _longOwnerIdentity =
    'owner.with.a.very.long.identity.for.layout.regression@kunlun.example.com';
const _longRepoName =
    'kunlun/dispatch-coordination-platform-with-very-long-repository-name';
const _longCustomOrgRole =
    'custom-organization-access-controller-with-a-very-long-label';
const _longCandidateIdentity =
    'candidate.with.a.very.long.identity.for.project.member.dropdown@kunlun.example.com';
const _longCandidateDisplayName =
    'Candidate With A Very Long Display Name For Project Member Dropdown';

void main() {
  final source = File('lib/screens/projects_page.dart').readAsStringSync();

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
      canManageOrganization(orgWithRole(' owner '), isAdmin: false),
      isTrue,
    );
    expect(
      canManageOrganization(orgWithRole(' admin '), isAdmin: false),
      isTrue,
    );
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
    expect(organizationRoleLabel(' owner ', isAdmin: true), '负责人');
    expect(organizationRoleLabel(' custom ', isAdmin: false), 'custom');
  });

  test('role matching normalizes dropdown values', () {
    expect(roleMatches('owner', ' owner '), isTrue);
    expect(roleMatches(' admin ', 'admin'), isTrue);
    expect(roleMatches('member', 'viewer'), isFalse);
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
    expect(projectRoleLabel(' owner '), '负责人');
    expect(projectRoleLabel(' custom '), 'custom');
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
      projectListRoleLabel(
        project(owner: ' owner@x '),
        isAdmin: false,
        identity: 'owner@x',
      ),
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
    expect(projectOwnerLabel(' owner@x '), '负责人 · owner@x');
  });

  test('project list subtitle includes team role and owner', () {
    final project = Project.fromJson({
      'id': 'p1',
      'org_id': 'org-a',
      'name': 'Backend',
      'owner_identity': 'owner@x',
      'role': '',
    });

    expect(
      projectListSubtitle(
        project,
        teamName: 'Kunlun',
        isAdmin: false,
        identity: 'owner@x',
      ),
      'Kunlun · 负责人 · 负责人 · owner@x',
    );
  });

  test('team workspace search matches projects and teams', () {
    final org = Organization.fromJson({
      'id': 'org-a',
      'name': 'Kunlun Operations',
      'owner_identity': 'team-owner@x',
      'role': 'owner',
    });
    final project = Project.fromJson({
      'id': 'p1',
      'org_id': 'org-a',
      'name': 'Backend Control',
      'owner_identity': 'project-owner@x',
      'role': 'member',
    });

    expect(organizationMatchesSearch(org, 'oper'), isTrue);
    expect(organizationMatchesSearch(org, '访客'), isFalse);
    expect(
      projectMatchesSearch(
        project,
        'backend',
        teamName: org.name,
        isAdmin: false,
        identity: 'member@x',
      ),
      isTrue,
    );
    expect(
      projectMatchesSearch(
        project,
        'kunlun',
        teamName: org.name,
        isAdmin: false,
        identity: 'member@x',
      ),
      isTrue,
    );
    expect(
      projectMatchesSearch(
        project,
        '只读',
        teamName: org.name,
        isAdmin: false,
        identity: 'member@x',
      ),
      isFalse,
    );
    expect(
      projectVisibleForSearch(
        project,
        'team-owner@x',
        team: org,
        fallbackTeamName: 'Fallback',
        isAdmin: false,
        identity: 'member@x',
      ),
      isTrue,
    );
  });

  test(
    'identity helpers ignore surrounding whitespace without matching blank',
    () {
      expect(identityMatches(' owner@x ', 'owner@x'), isTrue);
      expect(identityMatches('owner@x', ' owner@x '), isTrue);
      expect(identityMatches('Owner@X', ' owner@x '), isTrue);
      expect(identityMatches(' ', ' '), isFalse);
      expect(identityMatches('', 'owner@x'), isFalse);
    },
  );

  test('online identity lookup trims relay values', () {
    final onlineUsers = [
      OnlineUser.fromJson({'identity': ' owner@x ', 'online': true}),
      OnlineUser.fromJson({'identity': 'Case@X', 'online': true}),
      OnlineUser.fromJson({'identity': 'viewer@x', 'online': false}),
    ];

    expect(isIdentityOnline(onlineUsers, 'owner@x'), isTrue);
    expect(isIdentityOnline(onlineUsers, ' case@x '), isTrue);
    expect(isIdentityOnline(onlineUsers, ' viewer@x '), isFalse);
  });

  test('project management checks normalize owner and member identities', () {
    ProjectDetail detail({
      required String ownerIdentity,
      required List<Map<String, Object?>> members,
    }) => ProjectDetail.fromJson({
      'project': {
        'id': 'p1',
        'org_id': 'org-a',
        'name': 'Backend',
        'owner_identity': ownerIdentity,
        'role': '',
      },
      'repos': const [],
      'members': members,
    });

    expect(
      canManageProjectDetail(
        detail(ownerIdentity: ' owner@x ', members: const []),
        isAdmin: false,
        identity: 'owner@x',
      ),
      isTrue,
    );
    expect(
      canManageProjectDetail(
        detail(ownerIdentity: 'Owner@X', members: const []),
        isAdmin: false,
        identity: ' owner@x ',
      ),
      isTrue,
    );
    expect(
      canManageProjectDetail(
        ProjectDetail.fromJson({
          'project': {
            'id': 'p2',
            'org_id': 'org-a',
            'name': 'Frontend',
            'owner_identity': 'other@x',
            'role': ' admin ',
          },
          'repos': const [],
          'members': const [],
        }),
        isAdmin: false,
        identity: 'viewer@x',
      ),
      isTrue,
    );
    expect(
      canManageProjectDetail(
        ProjectDetail.fromJson({
          'project': {
            'id': 'p3',
            'org_id': 'org-a',
            'name': 'Ops',
            'owner_identity': 'other@x',
            'role': ' owner ',
          },
          'repos': const [],
          'members': const [],
        }),
        isAdmin: false,
        identity: 'viewer@x',
      ),
      isTrue,
    );
    expect(
      canManageProjectDetail(
        detail(
          ownerIdentity: 'other@x',
          members: const [
            {'identity': ' project-owner@x ', 'role': 'owner'},
          ],
        ),
        isAdmin: false,
        identity: 'project-owner@x',
      ),
      isTrue,
    );
    expect(
      canManageProjectDetail(
        detail(
          ownerIdentity: 'other@x',
          members: const [
            {'identity': ' project-owner@x ', 'role': 'member'},
          ],
        ),
        isAdmin: false,
        identity: 'project-owner@x',
      ),
      isFalse,
    );
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

  test('project member candidates skip blank and existing members', () {
    final candidates = projectMemberCandidates(
      [
        OrganizationMember.fromJson({
          'identity': ' existing@x ',
          'role': 'member',
          'display_name': 'Existing',
        }),
        OrganizationMember.fromJson({
          'identity': '   ',
          'role': 'member',
          'display_name': 'Blank',
        }),
        OrganizationMember.fromJson({
          'identity': ' zed@x ',
          'role': 'member',
          'display_name': 'Zed',
        }),
        OrganizationMember.fromJson({
          'identity': ' zed@x ',
          'role': 'admin',
          'display_name': 'Zed Duplicate',
        }),
        OrganizationMember.fromJson({
          'identity': ' ann@x ',
          'role': 'member',
          'display_name': 'Ann',
        }),
      ],
      [
        ProjectMember.fromJson({'identity': 'existing@x', 'role': 'member'}),
      ],
    );

    expect(candidates.map((m) => m.identity).toList(), ['ann@x', 'zed@x']);
  });

  test('project member candidates sort labels case-insensitively', () {
    final candidates = projectMemberCandidates([
      OrganizationMember.fromJson({
        'identity': 'zed@x',
        'role': 'member',
        'display_name': 'zed',
      }),
      OrganizationMember.fromJson({
        'identity': 'alpha@x',
        'role': 'member',
        'display_name': 'Alpha',
      }),
      OrganizationMember.fromJson({
        'identity': 'bravo@x',
        'role': 'member',
        'display_name': '   ',
      }),
    ], const []);

    expect(candidates.map((m) => m.identity).toList(), [
      'alpha@x',
      'bravo@x',
      'zed@x',
    ]);
  });

  test('project creation team id defaults to a real manageable team', () {
    final orgs = [
      Organization.fromJson({
        'id': 'org-a',
        'name': 'Kunlun',
        'owner_identity': 'owner@x',
        'role': 'owner',
      }),
    ];

    expect(createProjectTeamId(null, orgs), 'org-a');
    expect(createProjectTeamId('', orgs), 'org-a');
    expect(createProjectTeamId('   ', orgs), 'org-a');
    expect(createProjectTeamId('missing-org', orgs), 'org-a');
    expect(createProjectTeamId(' org-a ', orgs), 'org-a');
    expect(createProjectTeamId(null, const []), isNull);
  });

  test('responsive control width never exceeds the available width', () {
    expect(
      responsiveControlWidth(const BoxConstraints(maxWidth: 180), 260),
      180,
    );
    expect(
      responsiveControlWidth(const BoxConstraints(maxWidth: 320), 260),
      260,
    );
  });

  test('project dialogs are capped for compact screens', () {
    expect(projectDialogWidth(const Size(1024, 800)), 420);
    expect(projectDialogWidth(const Size(360, 760)), 328);
    expect(projectDialogWidth(const Size(24, 760)), 420);
  });

  test('member action width leaves room for identity text', () {
    expect(
      memberActionWidth(const BoxConstraints(maxWidth: 220)),
      closeTo(105.6, 0.001),
    );
    expect(memberActionWidth(const BoxConstraints(maxWidth: 640)), 156);
    expect(
      memberActionWidth(
        const BoxConstraints(maxWidth: 300),
        preferred: 180,
        maxFraction: 0.4,
      ),
      120,
    );
  });

  test('project workspace dropdown menus are capped for small screens', () {
    expect(projectsMenuMaxHeight(const Size(1024, 900)), 320);
    expect(projectsMenuMaxHeight(const Size(320, 420)), closeTo(243.6, 0.001));
    expect(projectsMenuMaxHeight(const Size(320, 220)), 160);
    expect(projectsMenuMaxHeight(Size.zero), 320);
  });

  test('project sheet loading height is responsive', () {
    expect(projectSheetLoadingHeight(const Size(1024, 900)), 180);
    expect(
      projectSheetLoadingHeight(const Size(320, 500)),
      closeTo(140, 0.001),
    );
    expect(projectSheetLoadingHeight(const Size(320, 300)), 96);
  });

  test('team rail dimensions adapt on compact screens', () {
    expect(projectTeamPanelHeight(const Size(1024, 900)), 104);
    expect(projectTeamPanelHeight(const Size(320, 360)), 96);
    expect(projectTeamPanelHeight(Size.zero), 104);

    expect(projectTeamCardWidth(const Size(1024, 900)), 286);
    expect(projectTeamCardWidth(const Size(320, 760)), 272);
    expect(projectTeamCardWidth(const Size(240, 760)), 220);
    expect(projectTeamCardWidth(Size.zero), 286);
  });

  test('project rename dialog uses responsive controls', () {
    final start = source.indexOf('Future<void> _rename(String current) async');
    final renameDialog = source.substring(
      start,
      source.indexOf(
        'Future<void> _removeMember(String identity) async',
        start,
      ),
    );

    expect(renameDialog, contains('projectDialogWidth(size)'));
    expect(renameDialog, contains('insetPadding: const EdgeInsets.symmetric'));
    expect(renameDialog, contains('maxLines: 1'));
    expect(renameDialog, contains('overflow: TextOverflow.ellipsis'));
    expect(renameDialog, contains('textInputAction: TextInputAction.done'));
    expect(renameDialog, contains('onSubmitted: (_) => Navigator.pop'));
    expect(renameDialog, isNot(contains('content: TextField(')));
  });

  test('project delete dialog uses responsive controls', () {
    final start = source.indexOf('Future<void> _delete() async');
    final deleteDialog = source.substring(
      start,
      source.indexOf('bool _isOnline(String identity)', start),
    );

    expect(deleteDialog, contains('projectDialogWidth(size)'));
    expect(deleteDialog, contains('insetPadding: const EdgeInsets.symmetric'));
    expect(deleteDialog, contains('maxLines: 1'));
    expect(deleteDialog, contains('overflow: TextOverflow.ellipsis'));
    expect(deleteDialog, contains('SingleChildScrollView'));
    expect(deleteDialog, contains('projectName'));
    expect(deleteDialog, isNot(contains('content: const Text(')));
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

  test('project member candidates compare identities case-insensitively', () {
    final candidates = projectMemberCandidates(
      [
        OrganizationMember.fromJson({
          'identity': 'Dev@X',
          'display_name': 'Dev',
          'role': 'member',
        }),
        OrganizationMember.fromJson({
          'identity': 'qa@x',
          'display_name': 'QA',
          'role': 'member',
        }),
        OrganizationMember.fromJson({
          'identity': 'QA@X',
          'display_name': 'QA duplicate',
          'role': 'member',
        }),
      ],
      [
        ProjectMember.fromJson({'identity': ' dev@x ', 'role': 'member'}),
      ],
    );

    expect([for (final c in candidates) c.identity], ['qa@x']);
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
          online(' Alice@X ', true),
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

  testWidgets('team workspace header renders on narrow screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _ProjectsPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('团队工作台'), findsOneWidget);
    expect(find.text('新建团队'), findsOneWidget);
    expect(find.text('新建项目'), findsWidgets);
    expect(find.text('可管理'), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
    expect(find.text('2'), findsNWidgets(2)); // teams + projects
    expect(find.text('1'), findsNWidgets(2)); // manageable + unique online
    expect(find.text('Kunlun'), findsNWidgets(2));

    final teamCard = find.ancestor(
      of: find.text('Kunlun').last,
      matching: find.byType(Material),
    );
    expect(tester.getSize(teamCard.first).width, 286);

    FilledButton button(String label) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));

    expect(button('新建团队').onPressed, isNull);
    expect(button('新建项目').onPressed, isNull);

    await tester.enterText(find.byType(TextField).at(0), 'New Team');
    await tester.pump();
    expect(button('新建团队').onPressed, isNotNull);
    expect(button('新建项目').onPressed, isNull);

    await tester.enterText(find.byType(TextField).at(1), 'New Project');
    await tester.pump();
    expect(button('新建团队').onPressed, isNotNull);
    expect(button('新建项目').onPressed, isNotNull);
  });

  testWidgets('empty project state focuses project creation', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _NoProjectTeamsFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('还没有项目'), findsOneWidget);
    expect(find.text('2 个团队已就绪'), findsOneWidget);
    expect(find.text('可管理'), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '新建项目').last);
    await tester.pump();

    final projectField = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(projectField.focusNode?.hasFocus, isTrue);
  });

  testWidgets('project creation uses first manageable team by default', (
    tester,
  ) async {
    final client = _CaptureCreateProjectFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(1), 'Default Scoped');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '新建项目'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(client.createdName, 'Default Scoped');
    expect(client.createdOrgId, 'org-a');
  });

  testWidgets('project creation is disabled until a team is available', (
    tester,
  ) async {
    final client = _NoTeamsProjectsPageFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(1), 'Needs Team');
    await tester.pump();

    final createButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '新建项目').first,
    );
    expect(createButton.onPressed, isNull);
    expect(find.text('等待加入团队'), findsOneWidget);
  });

  testWidgets('project creation ignores duplicate submit taps', (tester) async {
    final client = _CountingCreateProjectFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(1), 'Single Project');
    await tester.pump();

    final createButton = find.widgetWithText(FilledButton, '新建项目');
    await tester.tap(createButton);
    await tester.tap(createButton);

    expect(client.createProjectCalls, 1);
    expect(client.createdProjectName, 'Single Project');
    await tester.pump();
    expect(find.text('创建中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).enabled,
      isFalse,
    );
    expect(
      tester
          .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
          .onChanged,
      isNull,
    );

    client.completeCreateProject();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('project creation completion after unmount is ignored', (
    tester,
  ) async {
    final client = _CountingCreateProjectFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(1), 'Unmounted Project');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '新建项目'));
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    client.completeCreateProject();
    await tester.pumpAndSettle();

    expect(client.createProjectCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('project creation completion after account switch is ignored', (
    tester,
  ) async {
    final oldClient = _CountingCreateProjectFakeClient();
    final newClient = _ProjectsPageFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: oldClient)),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField).at(1), 'Old Pending Project');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '新建项目'));
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: newClient)),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), 'New Draft Project');
    await tester.pump();

    oldClient.completeCreateProject();
    await tester.pump();
    await tester.pump();

    expect(oldClient.createProjectCalls, 1);
    expect(find.text('Old Pending Project'), findsNothing);
    expect(find.text('New Draft Project'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('organization creation ignores duplicate submit taps', (
    tester,
  ) async {
    final client = _CountingCreateOrganizationFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'Single Team');
    await tester.pump();

    final createButton = find.widgetWithText(FilledButton, '新建团队');
    await tester.tap(createButton);
    await tester.tap(createButton);

    expect(client.createOrganizationCalls, 1);
    expect(client.createdOrganizationName, 'Single Team');
    await tester.pump();
    expect(find.text('创建中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).enabled,
      isFalse,
    );

    client.completeCreateOrganization();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'organization creation completion after account switch is ignored',
    (tester) async {
      final oldClient = _CountingCreateOrganizationFakeClient();
      final newClient = _ProjectsPageFakeClient();

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(body: ProjectsPage(client: oldClient)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'Old Pending Team');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '新建团队'));
      await tester.pump();

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(body: ProjectsPage(client: newClient)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'New Draft Team');
      await tester.pump();

      oldClient.completeCreateOrganization();
      await tester.pumpAndSettle();

      expect(oldClient.createOrganizationCalls, 1);
      expect(find.text('Old Pending Team'), findsNothing);
      expect(find.text('New Draft Team'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('project creation is disabled until team context loads', (
    tester,
  ) async {
    final client = _StaleProjectsLoadFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await client.waitForProjectRequests(1);

    await tester.enterText(find.byType(TextField).at(1), 'Fresh Project');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '新建项目'));
    await tester.pump();
    final createButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '新建项目'),
    );
    expect(createButton.onPressed, isNull);

    client.completeProjects(0, const []);
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Fresh Project'), findsOneWidget);
  });

  testWidgets('project page account switch ignores stale team loads', (
    tester,
  ) async {
    final oldClient = _DelayedProjectsContextFakeClient(
      identity: 'old@x',
      orgName: 'Old Team',
      projectName: 'Old Project',
    );
    final newClient = _DelayedProjectsContextFakeClient(
      identity: 'new@x',
      orgName: 'New Team',
      projectName: 'New Project',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: oldClient)),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: newClient)),
      ),
    );
    await tester.pump();

    newClient.completeAll();
    await tester.pumpAndSettle();
    expect(find.text('New Project'), findsOneWidget);
    expect(find.text('New Team'), findsNWidgets(2));

    oldClient.completeAll();
    await tester.pumpAndSettle();

    expect(find.text('New Project'), findsOneWidget);
    expect(find.text('New Team'), findsNWidgets(2));
    expect(find.text('Old Project'), findsNothing);
    expect(find.text('Old Team'), findsNothing);
  });

  testWidgets(
    'project page keeps loading when best-effort team context throws',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(
            body: ProjectsPage(client: _ThrowingContextFakeClient()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Backend'), findsOneWidget);
      expect(find.text('Frontend'), findsOneWidget);
      expect(find.textContaining('加载失败'), findsNothing);
    },
  );

  test('team and project sheets ignore stale detail loads', () {
    final orgSheet = source.substring(
      source.indexOf('class _OrganizationSheetState'),
      source.indexOf('class _ProjectSheet extends StatefulWidget'),
    );
    final projectSheet = source.substring(
      source.indexOf('class _ProjectSheetState'),
      source.indexOf('class _CompactProjectChip'),
    );

    for (final sheet in [orgSheet, projectSheet]) {
      expect(sheet, contains('int _loadGeneration = 0;'));
      expect(sheet, contains('final generation = ++_loadGeneration;'));
      expect(sheet, contains('bool _isCurrentLoad(int generation)'));
      expect(sheet, contains('if (_isCurrentLoad(generation))'));
      expect(sheet, contains('projectSheetLoadingHeight'));
      expect(sheet, isNot(contains('height: 180')));
    }
  });

  testWidgets('team workspace creation controls shrink on compact widths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(240, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _ProjectsPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    final teamFieldWidth = tester.getSize(find.byType(TextField).at(0)).width;
    final projectFieldWidth = tester
        .getSize(find.byType(TextField).at(1))
        .width;
    final dropdownWidth = tester
        .getSize(find.byType(DropdownButton<String>))
        .width;

    expect(tester.takeException(), isNull);
    expect(teamFieldWidth, lessThanOrEqualTo(180));
    expect(projectFieldWidth, lessThanOrEqualTo(180));
    expect(dropdownWidth, lessThanOrEqualTo(180));
  });

  testWidgets('team workspace search filters teams and projects together', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _ProjectsPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Kunlun'), findsNWidgets(2));
    expect(find.text('Ops'), findsOneWidget);
    expect(find.text('Backend'), findsOneWidget);
    expect(find.text('Frontend'), findsOneWidget);

    final searchField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '搜索团队 / 项目 / 负责人',
    );
    await tester.enterText(searchField, 'ops');
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Kunlun'), findsOneWidget);
    expect(find.text('Backend'), findsNothing);
    expect(find.text('Ops'), findsOneWidget);
    expect(find.text('Frontend'), findsOneWidget);
    expect(find.text('匹配 1 团队 · 1 项目'), findsOneWidget);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump();
    expect(find.text('Backend'), findsOneWidget);
  });

  testWidgets('organization sheet uses compact empty project state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _ProjectsPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kunlun').last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('还没有项目'), findsOneWidget);
    expect(find.text('在团队工作台新建项目后，会出现在这里。'), findsOneWidget);
  });

  testWidgets('project sheet uses compact empty repo state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _ProjectsPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backend'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('还没有绑定 repo'), findsOneWidget);
    expect(find.text('绑定 repo 后团队成员可以按项目查看交接和待办。'), findsOneWidget);
  });

  testWidgets('project sheet disables repo binding until a repo is entered', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _ProjectsPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backend'));
    await tester.pumpAndSettle();

    TextButton bindButton() =>
        tester.widget<TextButton>(find.widgetWithText(TextButton, '绑定'));

    expect(tester.takeException(), isNull);
    expect(bindButton().onPressed, isNull);

    await tester.enterText(
      find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == 'repo 名(如 kunlun-backend)',
      ),
      'kunlun/backend',
    );
    await tester.pump();

    expect(bindButton().onPressed, isNotNull);
  });

  testWidgets('project sheet keeps repo input when binding fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: ProjectsPage(client: _FailingMapRepoProjectsPageFakeClient()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backend'));
    await tester.pumpAndSettle();

    final repoField = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.hintText == 'repo 名(如 kunlun-backend)',
    );
    await tester.enterText(repoField, 'kunlun/backend');
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '绑定'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(repoField).controller?.text,
      'kunlun/backend',
    );
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('project sheet ignores duplicate repo binding taps', (
    tester,
  ) async {
    final client = _CountingMapRepoProjectsPageFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backend'));
    await tester.pumpAndSettle();

    final repoField = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.hintText == 'repo 名(如 kunlun-backend)',
    );
    await tester.enterText(repoField, 'kunlun/backend');
    await tester.pump();

    final bindButton = find.widgetWithText(TextButton, '绑定');
    await tester.tap(bindButton);
    await tester.tap(bindButton);

    expect(client.mapRepoCalls, 1);
    await tester.pump();
    expect(find.text('绑定中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<TextField>(repoField).enabled, isFalse);

    client.completeMapRepo();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('project sheet ignores duplicate member add taps', (
    tester,
  ) async {
    final client = _CountingProjectMemberProjectsPageFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backend'));
    await tester.pumpAndSettle();

    final memberField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'identity',
    );
    await tester.tap(memberField);
    await tester.enterText(memberField, 'dev@x');
    await tester.pump();

    final addButton = find.widgetWithText(FilledButton, '加成员');
    await tester.tap(addButton);
    await tester.tap(addButton);

    expect(client.addMemberCalls, 1);
    expect(client.addedMemberIdentity, 'dev@x');
    await tester.pump();
    expect(find.text('添加中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<TextField>(memberField).enabled, isFalse);

    client.completeAddMember();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('project sheet can invite a project member', (tester) async {
    final client = _CountingProjectInvitationProjectsPageFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backend'));
    await tester.pumpAndSettle();

    final memberField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'identity',
    );
    await tester.enterText(memberField, 'invite@x');
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, '邀请'));
    await tester.tap(find.widgetWithText(OutlinedButton, '邀请'));

    expect(client.inviteMemberCalls, 1);
    expect(client.invitedIdentity, 'invite@x');
    await tester.pump();
    expect(find.text('邀请中'), findsOneWidget);

    client.completeInviteMember();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('project sheet member input submits from keyboard', (
    tester,
  ) async {
    final client = _CountingProjectMemberProjectsPageFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backend'));
    await tester.pumpAndSettle();

    final memberField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'identity',
    );
    await tester.showKeyboard(memberField);
    await tester.enterText(memberField, 'dev@x');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(client.addMemberCalls, 1);
    expect(client.addedMemberIdentity, 'dev@x');
    expect(find.text('添加中'), findsOneWidget);
    expect(tester.widget<TextField>(memberField).enabled, isFalse);

    client.completeAddMember();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'project sheet mutation after account switch closes stale sheet',
    (tester) async {
      final oldClient = _CountingProjectMemberProjectsPageFakeClient();
      final newClient = _CountingLoadProjectsPageFakeClient();

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(body: ProjectsPage(client: oldClient)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Backend'));
      await tester.pumpAndSettle();

      final memberField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'identity',
      );
      await tester.enterText(memberField, 'dev@x');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '加成员'));
      await tester.pump();
      expect(oldClient.addMemberCalls, 1);

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(body: ProjectsPage(client: newClient)),
        ),
      );
      await tester.pump();
      await tester.pump();
      final newLoadCount = newClient.projectsCalls;

      oldClient.completeAddMember();
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, '加成员'), findsNothing);
      expect(newClient.projectsCalls, newLoadCount);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('project sheet locks delete while request is pending', (
    tester,
  ) async {
    final client = _CountingDeleteProjectProjectsPageFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backend'));
    await tester.pumpAndSettle();

    Finder deleteButton() =>
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '删除');

    await tester.tap(deleteButton());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(client.deleteProjectCalls, 1);
    expect(find.text('删除项目?'), findsNothing);
    expect(tester.widget<IconButton>(deleteButton()).onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(deleteButton());
    await tester.pump();

    expect(client.deleteProjectCalls, 1);
    expect(find.text('删除项目?'), findsNothing);

    client.completeDeleteProject();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('project delete confirmation after account switch is ignored', (
    tester,
  ) async {
    final oldClient = _CountingDeleteProjectProjectsPageFakeClient();
    final newClient = _CountingDeleteProjectProjectsPageFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: oldClient)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backend'));
    await tester.pumpAndSettle();

    Finder deleteButton() =>
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '删除');

    await tester.tap(deleteButton());
    await tester.pumpAndSettle();
    expect(find.text('删除项目?'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: newClient)),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(oldClient.deleteProjectCalls, 0);
    expect(newClient.deleteProjectCalls, 0);
    expect(find.text('删除项目?'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('project sheet confirms member removal before request', (
    tester,
  ) async {
    final client = _CountingRemoveProjectMemberProjectsPageFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backend'));
    await tester.pumpAndSettle();

    Finder removeButton() =>
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '移除');

    await tester.tap(removeButton());
    await tester.pumpAndSettle();
    expect(find.text('移除项目成员'), findsOneWidget);
    expect(client.removeMemberCalls, 0);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.text('移除项目成员'), findsNothing);
    expect(client.removeMemberCalls, 0);

    await tester.tap(removeButton());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移除'));
    await tester.pump();

    expect(client.removeMemberCalls, 1);
    expect(client.removedMemberIdentity, 'dev@x');

    client.completeRemoveMember();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'project member removal confirmation after account switch is ignored',
    (tester) async {
      final oldClient = _CountingRemoveProjectMemberProjectsPageFakeClient();
      final newClient = _CountingRemoveProjectMemberProjectsPageFakeClient();

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(body: ProjectsPage(client: oldClient)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Backend'));
      await tester.pumpAndSettle();

      Finder removeButton() =>
          find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '移除');

      await tester.tap(removeButton());
      await tester.pumpAndSettle();
      expect(find.text('移除项目成员'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(body: ProjectsPage(client: newClient)),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, '移除'));
      await tester.pumpAndSettle();

      expect(oldClient.removeMemberCalls, 0);
      expect(newClient.removeMemberCalls, 0);
      expect(find.text('移除项目成员'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('organization sheet keeps member input when adding fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: ProjectsPage(client: _FailingOrgMemberProjectsPageFakeClient()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kunlun').last);
    await tester.pumpAndSettle();

    final memberField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '成员 identity',
    );
    await tester.enterText(memberField, 'qa@x');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '加入团队'));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(memberField).controller?.text, 'qa@x');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('organization sheet ignores duplicate member add taps', (
    tester,
  ) async {
    final client = _CountingOrgMemberProjectsPageFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kunlun').last);
    await tester.pumpAndSettle();

    final memberField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '成员 identity',
    );
    await tester.enterText(memberField, 'qa@x');
    await tester.pump();

    final addButton = find.widgetWithText(FilledButton, '加入团队');
    await tester.tap(addButton);
    await tester.tap(addButton);

    expect(client.addOrganizationMemberCalls, 1);
    expect(client.addedOrganizationMemberIdentity, 'qa@x');
    await tester.pump();
    expect(find.text('加入中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<TextField>(memberField).enabled, isFalse);

    client.completeAddOrganizationMember();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('organization sheet can invite a team member', (tester) async {
    final client = _CountingOrgInvitationProjectsPageFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kunlun').last);
    await tester.pumpAndSettle();

    final memberField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '成员 identity',
    );
    await tester.enterText(memberField, 'invite@x');
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, '邀请'));
    await tester.tap(find.widgetWithText(OutlinedButton, '邀请'));

    expect(client.inviteOrganizationMemberCalls, 1);
    expect(client.invitedOrganizationIdentity, 'invite@x');
    await tester.pump();
    expect(find.text('邀请中'), findsOneWidget);

    client.completeInviteOrganizationMember();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('organization sheet can delete a team', (tester) async {
    final client = _CountingDeleteOrganizationProjectsPageFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kunlun').last);
    await tester.pumpAndSettle();

    Finder deleteButton() =>
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '删除团队');

    await tester.tap(deleteButton());
    await tester.pumpAndSettle();
    expect(find.text('删除团队?'), findsOneWidget);
    expect(find.textContaining('1 个项目'), findsOneWidget);
    expect(client.deleteOrganizationCalls, 0);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();

    expect(client.deleteOrganizationCalls, 1);
    expect(client.deletedOrganizationId, 'org-a');
    expect(tester.widget<IconButton>(deleteButton()).onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(deleteButton());
    await tester.pump();
    expect(client.deleteOrganizationCalls, 1);

    client.completeDeleteOrganization();
    await tester.pumpAndSettle();
    expect(find.text('删除团队?'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('team workspace shows pending invitations and accepts them', (
    tester,
  ) async {
    final client = _InvitationPanelProjectsPageFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('待处理邀请'), findsOneWidget);
    expect(find.text('Kunlun · Backend'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '接受'));
    await tester.pumpAndSettle();

    expect(client.acceptInvitationCalls, 1);
    expect(client.acceptedInvitationId, 'inv-project');
    expect(find.text('待处理邀请'), findsNothing);
  });

  testWidgets('pending invitations fit on compact screens', (tester) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = _InvitationPanelProjectsPageFakeClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('待处理邀请'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'organization sheet mutation after account switch closes stale sheet',
    (tester) async {
      final oldClient = _CountingOrgMemberProjectsPageFakeClient();
      final newClient = _CountingLoadProjectsPageFakeClient();

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(body: ProjectsPage(client: oldClient)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Kunlun').last);
      await tester.pumpAndSettle();

      final memberField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '成员 identity',
      );
      await tester.enterText(memberField, 'qa@x');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '加入团队'));
      await tester.pump();
      expect(oldClient.addOrganizationMemberCalls, 1);

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(body: ProjectsPage(client: newClient)),
        ),
      );
      await tester.pump();
      await tester.pump();
      final newLoadCount = newClient.projectsCalls;

      oldClient.completeAddOrganizationMember();
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, '加入团队'), findsNothing);
      expect(newClient.projectsCalls, newLoadCount);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'organization member removal confirmation after account switch is ignored',
    (tester) async {
      final oldClient = _CountingOrgMemberProjectsPageFakeClient();
      final newClient = _CountingOrgMemberProjectsPageFakeClient();

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(body: ProjectsPage(client: oldClient)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Kunlun').last);
      await tester.pumpAndSettle();

      Finder removeButton() =>
          find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '移除');

      await tester.tap(removeButton());
      await tester.pumpAndSettle();
      expect(find.text('移除团队成员'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(body: ProjectsPage(client: newClient)),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, '移除'));
      await tester.pumpAndSettle();

      expect(oldClient.removeOrganizationMemberCalls, 0);
      expect(newClient.removeOrganizationMemberCalls, 0);
      expect(find.text('移除团队成员'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('organization sheet member input shrinks on compact widths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(240, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _ProjectsPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kunlun').last);
    await tester.pumpAndSettle();

    final memberField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '成员 identity',
    );

    expect(tester.takeException(), isNull);
    expect(tester.getSize(memberField).width, lessThanOrEqualTo(208));
  });

  testWidgets('project sheet member controls shrink on compact widths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(240, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _ProjectsPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backend'));
    await tester.pumpAndSettle();

    final teamPicker = find.byType(DropdownButtonFormField<String>);
    final memberField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'identity',
    );

    expect(tester.takeException(), isNull);
    expect(tester.getSize(teamPicker), isNotNull);
    expect(tester.getSize(teamPicker).width, lessThanOrEqualTo(208));
    expect(tester.getSize(memberField).width, lessThanOrEqualTo(208));
  });

  testWidgets('organization sheet member actions fit compact widths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _ProjectsPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kunlun').last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.widgetWithIcon(IconButton, Icons.close_rounded), findsWidgets);
  });

  testWidgets('organization sheet role menus are capped on compact screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _ProjectsPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kunlun').last);
    await tester.pumpAndSettle();

    final roleMenus = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(DropdownButton<String>),
    );

    expect(tester.takeException(), isNull);
    expect(roleMenus, findsWidgets);
    for (final menu in tester.widgetList<DropdownButton<String>>(roleMenus)) {
      expect(menu.menuMaxHeight, projectsMenuMaxHeight(const Size(320, 760)));
    }
  });

  testWidgets('project sheet member actions fit compact widths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _ProjectsPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backend'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.widgetWithIcon(IconButton, Icons.close_rounded), findsWidgets);
  });

  testWidgets('project sheet member menus are capped on compact screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _ProjectsPageFakeClient())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backend'));
    await tester.pumpAndSettle();

    final roleMenus = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(DropdownButton<String>),
    );
    final candidateMenus = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(DropdownButtonFormField<String>),
    );
    final expectedHeight = projectsMenuMaxHeight(const Size(320, 760));

    expect(tester.takeException(), isNull);
    expect(roleMenus, findsWidgets);
    expect(candidateMenus, findsOneWidget);
    for (final menu in tester.widgetList<DropdownButton<String>>(roleMenus)) {
      expect(menu.menuMaxHeight, expectedHeight);
    }
  });

  testWidgets('project list clamps long project names and metadata', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: ProjectsPage(client: _LongNameProjectsPageFakeClient()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(find.text(_longProjectName));
    final subtitleText =
        '$_longTeamName · 负责人 · ${projectOwnerLabel(_longOwnerIdentity)}';
    final subtitle = tester.widget<Text>(find.text(subtitleText));

    expect(tester.takeException(), isNull);
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(subtitle.maxLines, 1);
    expect(subtitle.overflow, TextOverflow.ellipsis);
  });

  testWidgets('project create team dropdown clamps long team names', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: ProjectsPage(client: _LongNameProjectsPageFakeClient()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();

    final teamOption = tester.widget<Text>(
      find.byKey(const ValueKey('project-create-team-org-a')).last,
    );

    expect(tester.takeException(), isNull);
    expect(teamOption.data, _longTeamName);
    expect(teamOption.maxLines, 1);
    expect(teamOption.overflow, TextOverflow.ellipsis);
  });

  testWidgets('organization sheet clamps long title and summary text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: ProjectsPage(client: _LongRoleOrganizationFakeClient()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(_longTeamName).last);
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(find.text(_longTeamName).last);
    final summaryText = '$_longCustomOrgRole · 2 成员 · 1 项目';
    final summary = tester.widget<Text>(find.text(summaryText));

    expect(tester.takeException(), isNull);
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(summary.maxLines, 1);
    expect(summary.overflow, TextOverflow.ellipsis);
  });

  testWidgets('project sheet clamps long title chips and repo labels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: ProjectsPage(client: _LongNameProjectsPageFakeClient()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(_longProjectName));
    await tester.pumpAndSettle();

    final projectTitles = tester.widgetList<Text>(find.text(_longProjectName));
    final teamLabels = tester.widgetList<Text>(find.text(_longTeamName));
    final ownerLabels = tester.widgetList<Text>(
      find.text(projectOwnerLabel(_longOwnerIdentity)),
    );
    final repoLabel = tester.widget<Text>(find.text(_longRepoName));

    expect(tester.takeException(), isNull);
    expect(
      projectTitles.any(
        (text) => text.maxLines == 1 && text.overflow == TextOverflow.ellipsis,
      ),
      isTrue,
    );
    expect(
      teamLabels.any(
        (text) => text.maxLines == 1 && text.overflow == TextOverflow.ellipsis,
      ),
      isTrue,
    );
    expect(
      ownerLabels.any(
        (text) => text.maxLines == 1 && text.overflow == TextOverflow.ellipsis,
      ),
      isTrue,
    );
    expect(repoLabel.maxLines, 1);
    expect(repoLabel.overflow, TextOverflow.ellipsis);
  });

  testWidgets('project member candidate dropdown clamps long member labels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: ProjectsPage(client: _LongCandidateProjectsPageFakeClient()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backend'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();

    final labelText =
        '$_longCandidateDisplayName · $_longCandidateIdentity · 成员';
    final label = tester.widget<Text>(
      find.byKey(ValueKey('project-member-candidate-$_longCandidateIdentity')),
    );

    expect(tester.takeException(), isNull);
    expect(label.data, labelText);
    expect(label.maxLines, 1);
    expect(label.overflow, TextOverflow.ellipsis);
  });
}

class _ProjectsPageFakeClient extends RelayClient {
  _ProjectsPageFakeClient() : super('http://127.0.0.1', 'tok');

  @override
  Future<List<Organization>> organizations() async => [
    Organization.fromJson({
      'id': 'org-a',
      'name': 'Kunlun',
      'owner_identity': 'owner@x',
      'role': 'owner',
    }),
    Organization.fromJson({
      'id': 'org-b',
      'name': 'Ops',
      'owner_identity': 'owner@x',
      'role': 'member',
    }),
  ];

  @override
  Future<Me> me() async => Me.fromJson({
    'identity': 'owner@x',
    'is_admin': false,
    'organizations': [
      {'id': 'org-a', 'name': 'Kunlun', 'role': 'owner'},
      {'id': 'org-b', 'name': 'Ops', 'role': 'member'},
    ],
    'projects': [],
  });

  @override
  Future<List<Project>> projects() async => [
    Project.fromJson({
      'id': 'p1',
      'org_id': 'org-a',
      'name': 'Backend',
      'owner_identity': 'owner@x',
      'role': 'owner',
    }),
    Project.fromJson({
      'id': 'p2',
      'org_id': 'org-b',
      'name': 'Frontend',
      'owner_identity': 'owner@x',
      'role': 'member',
    }),
  ];

  @override
  Future<List<OnlineUser>> onlineUsers() async => [
    OnlineUser.fromJson({'identity': 'owner@x', 'online': true}),
    OnlineUser.fromJson({'identity': 'owner@x', 'online': true}),
    OnlineUser.fromJson({'identity': 'offline@x', 'online': false}),
  ];

  @override
  Future<ProjectDetail> project(String id) async => ProjectDetail.fromJson({
    'project': {
      'id': id,
      'org_id': 'org-a',
      'name': id == 'p1' ? 'Backend' : 'Frontend',
      'owner_identity': 'owner@x',
      'role': 'owner',
    },
    'repos': const [],
    'members': [
      {'identity': 'owner@x', 'role': 'owner', 'display_name': 'Owner'},
    ],
  });

  @override
  Future<OrganizationDetail> organization(String id) async =>
      OrganizationDetail.fromJson({
        'organization': {
          'id': id,
          'name': 'Kunlun',
          'owner_identity': 'owner@x',
          'role': 'owner',
        },
        'members': [
          {'identity': 'owner@x', 'role': 'owner', 'display_name': 'Owner'},
          {'identity': 'dev@x', 'role': 'member', 'display_name': 'Dev'},
        ],
        'projects': const [],
      });

  @override
  Future<void> mapRepo(String id, String repoName) async {}
}

class _NoProjectTeamsFakeClient extends _ProjectsPageFakeClient {
  @override
  Future<List<Project>> projects() async => const [];
}

class _NoTeamsProjectsPageFakeClient extends _ProjectsPageFakeClient {
  @override
  Future<List<Organization>> organizations() async => const [];

  @override
  Future<Me> me() async => Me.fromJson({
    'identity': 'owner@x',
    'is_admin': false,
    'organizations': const [],
    'projects': const [],
  });

  @override
  Future<List<Project>> projects() async => const [];
}

class _ThrowingContextFakeClient extends _ProjectsPageFakeClient {
  @override
  Future<List<Organization>> organizations() {
    throw StateError('organizations-context-unavailable');
  }

  @override
  Future<List<OnlineUser>> onlineUsers() {
    throw StateError('online-context-unavailable');
  }
}

class _CaptureCreateProjectFakeClient extends _ProjectsPageFakeClient {
  String? createdName;
  String? createdOrgId;

  @override
  Future<Project> createProject(String name, {String? orgId}) async {
    createdName = name;
    createdOrgId = orgId;
    return Project.fromJson({
      'id': 'created',
      'org_id': orgId ?? '',
      'name': name,
      'owner_identity': 'owner@x',
      'role': 'owner',
    });
  }
}

class _CountingCreateProjectFakeClient extends _ProjectsPageFakeClient {
  final _createProjectCompleter = Completer<Project>();
  int createProjectCalls = 0;
  String? createdProjectName;

  @override
  Future<Project> createProject(String name, {String? orgId}) {
    createProjectCalls++;
    createdProjectName = name;
    return _createProjectCompleter.future;
  }

  void completeCreateProject() {
    if (_createProjectCompleter.isCompleted) return;
    _createProjectCompleter.complete(
      _project(id: 'created-project', name: createdProjectName ?? 'Created'),
    );
  }
}

class _CountingCreateOrganizationFakeClient extends _ProjectsPageFakeClient {
  final _createOrganizationCompleter = Completer<Organization>();
  int createOrganizationCalls = 0;
  String? createdOrganizationName;

  @override
  Future<Organization> createOrganization(String name) {
    createOrganizationCalls++;
    createdOrganizationName = name;
    return _createOrganizationCompleter.future;
  }

  void completeCreateOrganization() {
    if (_createOrganizationCompleter.isCompleted) return;
    _createOrganizationCompleter.complete(
      Organization.fromJson({
        'id': 'created-org',
        'name': createdOrganizationName ?? 'Created',
        'owner_identity': 'owner@x',
        'role': 'owner',
      }),
    );
  }
}

Project _project({required String id, required String name}) =>
    Project.fromJson({
      'id': id,
      'org_id': 'org-a',
      'name': name,
      'owner_identity': 'owner@x',
      'role': 'owner',
    });

class _StaleProjectsLoadFakeClient extends _ProjectsPageFakeClient {
  final _projectRequests = <Completer<List<Project>>>[];

  @override
  Future<List<Project>> projects() {
    final completer = Completer<List<Project>>();
    _projectRequests.add(completer);
    return completer.future;
  }

  Future<void> waitForProjectRequests(int count) async {
    while (_projectRequests.length < count) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void completeProjects(int index, List<Project> projects) {
    _projectRequests[index].complete(projects);
  }

  @override
  Future<Project> createProject(String name, {String? orgId}) async =>
      _project(id: 'created', name: name);
}

class _DelayedProjectsContextFakeClient extends RelayClient {
  _DelayedProjectsContextFakeClient({
    required this.identity,
    required this.orgName,
    required this.projectName,
  }) : super('http://127.0.0.1', 'tok');

  final String identity;
  final String orgName;
  final String projectName;
  final _orgs = Completer<List<Organization>>();
  final _me = Completer<Me>();
  final _projects = Completer<List<Project>>();
  final _online = Completer<List<OnlineUser>>();

  @override
  Future<List<Organization>> organizations() => _orgs.future;

  @override
  Future<Me> me() => _me.future;

  @override
  Future<List<Project>> projects() => _projects.future;

  @override
  Future<List<OnlineUser>> onlineUsers() => _online.future;

  void completeAll() {
    if (!_orgs.isCompleted) {
      _orgs.complete([
        Organization.fromJson({
          'id': 'org-context',
          'name': orgName,
          'owner_identity': identity,
          'role': 'owner',
        }),
      ]);
    }
    if (!_me.isCompleted) {
      _me.complete(
        Me.fromJson({
          'identity': identity,
          'is_admin': false,
          'organizations': [
            {'id': 'org-context', 'name': orgName, 'role': 'owner'},
          ],
          'projects': const [],
        }),
      );
    }
    if (!_projects.isCompleted) {
      _projects.complete([
        Project.fromJson({
          'id': 'project-context',
          'org_id': 'org-context',
          'name': projectName,
          'owner_identity': identity,
          'role': 'owner',
        }),
      ]);
    }
    if (!_online.isCompleted) {
      _online.complete([
        OnlineUser.fromJson({'identity': identity, 'online': true}),
      ]);
    }
  }
}

class _FailingMapRepoProjectsPageFakeClient extends _ProjectsPageFakeClient {
  @override
  Future<void> mapRepo(String id, String repoName) async {
    throw Exception('map failed');
  }
}

class _CountingMapRepoProjectsPageFakeClient extends _ProjectsPageFakeClient {
  final _mapRepoCompleter = Completer<void>();
  int mapRepoCalls = 0;

  @override
  Future<void> mapRepo(String id, String repoName) {
    mapRepoCalls++;
    return _mapRepoCompleter.future;
  }

  void completeMapRepo() {
    if (!_mapRepoCompleter.isCompleted) _mapRepoCompleter.complete();
  }
}

class _CountingProjectMemberProjectsPageFakeClient
    extends _ProjectsPageFakeClient {
  final _addMemberCompleter = Completer<void>();
  int addMemberCalls = 0;
  String? addedMemberIdentity;

  @override
  Future<void> addMember(String id, String identity, String role) {
    addMemberCalls++;
    addedMemberIdentity = identity;
    return _addMemberCompleter.future;
  }

  void completeAddMember() {
    if (!_addMemberCompleter.isCompleted) _addMemberCompleter.complete();
  }
}

class _CountingProjectInvitationProjectsPageFakeClient
    extends _ProjectsPageFakeClient {
  final _inviteMemberCompleter = Completer<Invitation>();
  int inviteMemberCalls = 0;
  String? invitedIdentity;

  @override
  Future<Invitation> inviteProjectMember(
    String id,
    String identity,
    String role,
  ) {
    inviteMemberCalls++;
    invitedIdentity = identity;
    return _inviteMemberCompleter.future;
  }

  void completeInviteMember() {
    if (_inviteMemberCompleter.isCompleted) return;
    _inviteMemberCompleter.complete(
      Invitation.fromJson({
        'id': 'pinv',
        'scope': 'project',
        'org_id': 'org-a',
        'org_name': 'Kunlun',
        'project_id': 'p1',
        'project_name': 'Backend',
        'identity': invitedIdentity ?? 'invite@x',
        'role': 'member',
        'inviter_identity': 'owner@x',
        'created_at': '2026-07-10T00:00:00Z',
      }),
    );
  }
}

class _CountingLoadProjectsPageFakeClient extends _ProjectsPageFakeClient {
  int projectsCalls = 0;

  @override
  Future<List<Project>> projects() {
    projectsCalls++;
    return super.projects();
  }
}

class _CountingDeleteProjectProjectsPageFakeClient
    extends _ProjectsPageFakeClient {
  final _deleteProjectCompleter = Completer<void>();
  int deleteProjectCalls = 0;

  @override
  Future<void> deleteProject(String id) {
    deleteProjectCalls++;
    return _deleteProjectCompleter.future;
  }

  void completeDeleteProject() {
    if (!_deleteProjectCompleter.isCompleted) {
      _deleteProjectCompleter.complete();
    }
  }
}

class _CountingDeleteOrganizationProjectsPageFakeClient
    extends _ProjectsPageFakeClient {
  final _deleteOrganizationCompleter = Completer<void>();
  int deleteOrganizationCalls = 0;
  String? deletedOrganizationId;

  @override
  Future<OrganizationDetail> organization(String id) async =>
      OrganizationDetail.fromJson({
        'organization': {
          'id': id,
          'name': 'Kunlun',
          'owner_identity': 'owner@x',
          'role': 'owner',
        },
        'members': [
          {'identity': 'owner@x', 'role': 'owner', 'display_name': 'Owner'},
        ],
        'projects': [
          {
            'id': 'p1',
            'org_id': id,
            'name': 'Backend',
            'owner_identity': 'owner@x',
            'role': 'owner',
          },
        ],
      });

  @override
  Future<void> deleteOrganization(String id) {
    deleteOrganizationCalls++;
    deletedOrganizationId = id;
    return _deleteOrganizationCompleter.future;
  }

  void completeDeleteOrganization() {
    if (!_deleteOrganizationCompleter.isCompleted) {
      _deleteOrganizationCompleter.complete();
    }
  }
}

class _CountingRemoveProjectMemberProjectsPageFakeClient
    extends _ProjectsPageFakeClient {
  final _removeMemberCompleter = Completer<void>();
  int removeMemberCalls = 0;
  String? removedMemberIdentity;

  @override
  Future<ProjectDetail> project(String id) async => ProjectDetail.fromJson({
    'project': {
      'id': id,
      'org_id': 'org-a',
      'name': id == 'p1' ? 'Backend' : 'Frontend',
      'owner_identity': 'owner@x',
      'role': 'owner',
    },
    'repos': const [],
    'members': [
      {'identity': 'owner@x', 'role': 'owner', 'display_name': 'Owner'},
      {'identity': 'dev@x', 'role': 'member', 'display_name': 'Dev'},
    ],
  });

  @override
  Future<void> removeMember(String id, String identity) {
    removeMemberCalls++;
    removedMemberIdentity = identity;
    return _removeMemberCompleter.future;
  }

  void completeRemoveMember() {
    if (!_removeMemberCompleter.isCompleted) {
      _removeMemberCompleter.complete();
    }
  }
}

class _FailingOrgMemberProjectsPageFakeClient extends _ProjectsPageFakeClient {
  @override
  Future<void> addOrganizationMember(
    String id,
    String identity,
    String role,
  ) async {
    throw Exception('add member failed');
  }
}

class _CountingOrgMemberProjectsPageFakeClient extends _ProjectsPageFakeClient {
  final _addOrganizationMemberCompleter = Completer<void>();
  int addOrganizationMemberCalls = 0;
  String? addedOrganizationMemberIdentity;
  int removeOrganizationMemberCalls = 0;
  String? removedOrganizationMemberIdentity;

  @override
  Future<void> addOrganizationMember(String id, String identity, String role) {
    addOrganizationMemberCalls++;
    addedOrganizationMemberIdentity = identity;
    return _addOrganizationMemberCompleter.future;
  }

  @override
  Future<void> removeOrganizationMember(String id, String identity) async {
    removeOrganizationMemberCalls++;
    removedOrganizationMemberIdentity = identity;
  }

  void completeAddOrganizationMember() {
    if (!_addOrganizationMemberCompleter.isCompleted) {
      _addOrganizationMemberCompleter.complete();
    }
  }
}

class _CountingOrgInvitationProjectsPageFakeClient
    extends _ProjectsPageFakeClient {
  final _inviteOrganizationMemberCompleter = Completer<Invitation>();
  int inviteOrganizationMemberCalls = 0;
  String? invitedOrganizationIdentity;

  @override
  Future<Invitation> inviteOrganizationMember(
    String id,
    String identity,
    String role,
  ) {
    inviteOrganizationMemberCalls++;
    invitedOrganizationIdentity = identity;
    return _inviteOrganizationMemberCompleter.future;
  }

  void completeInviteOrganizationMember() {
    if (_inviteOrganizationMemberCompleter.isCompleted) return;
    _inviteOrganizationMemberCompleter.complete(
      Invitation.fromJson({
        'id': 'oinv',
        'scope': 'org',
        'org_id': 'org-a',
        'org_name': 'Kunlun',
        'identity': invitedOrganizationIdentity ?? 'invite@x',
        'role': 'member',
        'inviter_identity': 'owner@x',
        'created_at': '2026-07-10T00:00:00Z',
      }),
    );
  }
}

class _InvitationPanelProjectsPageFakeClient extends _ProjectsPageFakeClient {
  bool accepted = false;
  int acceptInvitationCalls = 0;
  String? acceptedInvitationId;

  @override
  Future<Me> me() async => Me.fromJson({
    'identity': 'invitee@x',
    'is_admin': false,
    'organizations': const [],
    'projects': const [],
    'invitations': accepted
        ? const []
        : [
            {
              'id': 'inv-project',
              'scope': 'project',
              'org_id': 'org-a',
              'org_name': 'Kunlun',
              'project_id': 'p1',
              'project_name': 'Backend',
              'identity': 'invitee@x',
              'role': 'member',
              'inviter_identity': 'owner@x',
              'created_at': '2026-07-10T00:00:00Z',
            },
          ],
  });

  @override
  Future<void> acceptInvitation(String id) async {
    acceptInvitationCalls++;
    acceptedInvitationId = id;
    accepted = true;
  }
}

class _LongCandidateProjectsPageFakeClient extends _ProjectsPageFakeClient {
  @override
  Future<OrganizationDetail> organization(String id) async =>
      OrganizationDetail.fromJson({
        'organization': {
          'id': id,
          'name': 'Kunlun',
          'owner_identity': 'owner@x',
          'role': 'owner',
        },
        'members': [
          {'identity': 'owner@x', 'role': 'owner', 'display_name': 'Owner'},
          {
            'identity': _longCandidateIdentity,
            'role': 'member',
            'display_name': _longCandidateDisplayName,
          },
        ],
        'projects': const [],
      });
}

class _LongNameProjectsPageFakeClient extends _ProjectsPageFakeClient {
  @override
  Future<List<Organization>> organizations() async => [
    Organization.fromJson({
      'id': 'org-a',
      'name': _longTeamName,
      'owner_identity': _longOwnerIdentity,
      'role': 'owner',
    }),
  ];

  @override
  Future<Me> me() async => Me.fromJson({
    'identity': _longOwnerIdentity,
    'is_admin': false,
    'organizations': [
      {'id': 'org-a', 'name': _longTeamName, 'role': 'owner'},
    ],
    'projects': [],
  });

  @override
  Future<List<Project>> projects() async => [
    Project.fromJson({
      'id': 'p-long',
      'org_id': 'org-a',
      'name': _longProjectName,
      'owner_identity': _longOwnerIdentity,
      'role': 'owner',
    }),
  ];

  @override
  Future<List<OnlineUser>> onlineUsers() async => [
    OnlineUser.fromJson({'identity': _longOwnerIdentity, 'online': true}),
  ];

  @override
  Future<ProjectDetail> project(String id) async => ProjectDetail.fromJson({
    'project': {
      'id': id,
      'org_id': 'org-a',
      'name': _longProjectName,
      'owner_identity': _longOwnerIdentity,
      'role': 'owner',
    },
    'repos': [_longRepoName],
    'members': [
      {
        'identity': _longOwnerIdentity,
        'role': 'owner',
        'display_name': 'Owner With A Long Display Name',
      },
    ],
  });
}

class _LongRoleOrganizationFakeClient extends _LongNameProjectsPageFakeClient {
  @override
  Future<OrganizationDetail> organization(String id) async =>
      OrganizationDetail.fromJson({
        'organization': {
          'id': 'org-a',
          'name': _longTeamName,
          'owner_identity': _longOwnerIdentity,
          'role': _longCustomOrgRole,
        },
        'members': [
          {
            'identity': _longOwnerIdentity,
            'role': 'owner',
            'display_name': 'Owner With A Long Display Name',
          },
          {'identity': 'member@x', 'role': 'member', 'display_name': 'Member'},
        ],
        'projects': [
          {
            'id': 'p-long',
            'org_id': 'org-a',
            'name': _longProjectName,
            'owner_identity': _longOwnerIdentity,
            'role': 'owner',
          },
        ],
      });
}
