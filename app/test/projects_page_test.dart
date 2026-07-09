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

  test(
    'identity helpers ignore surrounding whitespace without matching blank',
    () {
      expect(identityMatches(' owner@x ', 'owner@x'), isTrue);
      expect(identityMatches('owner@x', ' owner@x '), isTrue);
      expect(identityMatches(' ', ' '), isFalse);
      expect(identityMatches('', 'owner@x'), isFalse);
    },
  );

  test('online identity lookup trims relay values', () {
    final onlineUsers = [
      OnlineUser.fromJson({'identity': ' owner@x ', 'online': true}),
      OnlineUser.fromJson({'identity': 'viewer@x', 'online': false}),
    ];

    expect(isIdentityOnline(onlineUsers, 'owner@x'), isTrue);
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

  test('project creation team id ignores default and stale selections', () {
    final orgs = [
      Organization.fromJson({
        'id': 'org-a',
        'name': 'Kunlun',
        'owner_identity': 'owner@x',
        'role': 'owner',
      }),
    ];

    expect(createProjectTeamId(null, orgs), isNull);
    expect(createProjectTeamId('', orgs), isNull);
    expect(createProjectTeamId('   ', orgs), isNull);
    expect(createProjectTeamId('missing-org', orgs), isNull);
    expect(createProjectTeamId(' org-a ', orgs), 'org-a');
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
    expect(find.text('新建项目'), findsOneWidget);
    expect(find.text('可管理'), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
    expect(find.text('2'), findsNWidgets(2)); // teams + projects
    expect(find.text('1'), findsNWidgets(2)); // manageable + unique online

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

  testWidgets('project creation does not submit empty default team id', (
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
    expect(client.createdOrgId, isNull);
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
      find.byKey(const ValueKey('project-create-team-org-a')),
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

class _FailingMapRepoProjectsPageFakeClient extends _ProjectsPageFakeClient {
  @override
  Future<void> mapRepo(String id, String repoName) async {
    throw Exception('map failed');
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
