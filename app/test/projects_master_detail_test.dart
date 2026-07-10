import 'package:app/api/models.dart';
import 'package:app/api/relay_client.dart';
import 'package:app/screens/projects_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MasterDetailClient extends RelayClient {
  _MasterDetailClient() : super('http://127.0.0.1', 'tok');

  String? createdName, createdOrgId;

  @override
  Future<List<Organization>> organizations() async => [
    Organization.fromJson({
      'id': 'org-a',
      'name': 'Kunlun Platform Team',
      'owner_identity': 'owner@x',
      'role': 'owner',
    }),
    Organization.fromJson({
      'id': 'org-b',
      'name': 'Operations Team With A Long Name',
      'owner_identity': 'ops@x',
      'role': 'member',
    }),
  ];

  @override
  Future<Me> me() async => Me.fromJson({
    'identity': 'owner@x',
    'organizations': [
      {'id': 'org-a', 'name': 'Kunlun Platform Team', 'role': 'owner'},
      {
        'id': 'org-b',
        'name': 'Operations Team With A Long Name',
        'role': 'member',
      },
    ],
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
      'owner_identity': 'ops@x',
      'role': 'member',
    }),
  ];

  @override
  Future<ProjectDetail> project(String id) async => ProjectDetail.fromJson({
    'project': {
      'id': id,
      'org_id': id == 'p1' ? 'org-a' : 'org-b',
      'name': id == 'p1' ? 'Backend' : 'Frontend',
      'owner_identity': id == 'p1' ? 'owner@x' : 'ops@x',
      'role': id == 'p1' ? 'owner' : 'member',
    },
    'repo_bindings': [
      {
        'repo_name': id == 'p1' ? 'backend' : 'frontend',
        'clone_url':
            'https://github.com/acme/${id == 'p1' ? 'backend' : 'frontend'}.git',
      },
    ],
    'members': const [],
  });

  @override
  Future<OrganizationDetail> organization(String id) async =>
      OrganizationDetail.fromJson({
        'organization': {
          'id': id,
          'name': id == 'org-a'
              ? 'Kunlun Platform Team'
              : 'Operations Team With A Long Name',
          'owner_identity': 'owner@x',
          'role': id == 'org-a' ? 'owner' : 'member',
        },
        'members': [
          {'identity': 'owner@x', 'role': 'owner', 'display_name': 'Owner'},
        ],
        'projects': const [],
      });

  @override
  Future<List<OnlineUser>> onlineUsers() async => const [];

  @override
  Future<Project> createProject(String name, {String? orgId}) async {
    createdName = name;
    createdOrgId = orgId;
    return Project.fromJson({'id': 'created', 'name': name, 'org_id': orgId});
  }
}

void main() {
  testWidgets('desktop uses a vertical team rail with one selected scope', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _MasterDetailClient())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('projects-team-rail')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('projects-compact-team-picker')),
      findsNothing,
    );
    expect(
      tester
          .widgetList<ListView>(find.byType(ListView))
          .where((list) => list.scrollDirection == Axis.horizontal),
      isEmpty,
    );
    expect(
      tester
          .widgetList<ListTile>(find.byType(ListTile))
          .where((tile) => tile.selected),
      hasLength(1),
    );

    await tester.tap(find.byKey(const ValueKey('project-scope-org:org-b')));
    await tester.pumpAndSettle();
    expect(find.text('Operations Team With A Long Name'), findsWidgets);
    expect(find.textContaining('1 名成员'), findsOneWidget);
    expect(
      tester
          .widgetList<ListTile>(find.byType(ListTile))
          .where((tile) => tile.selected),
      hasLength(1),
    );
    expect(find.text('Backend'), findsNothing);
    expect(find.text('Frontend'), findsOneWidget);
  });

  testWidgets('project create dialog cannot submit into a switched account', (
    tester,
  ) async {
    final oldClient = _MasterDetailClient();
    final newClient = _MasterDetailClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: oldClient)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新建项目'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('create-project-name')),
      'Stale Project',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: newClient)),
      ),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pumpAndSettle();

    expect(oldClient.createdName, isNull);
    expect(newClient.createdName, isNull);
    expect(find.text('Stale Project'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('project creation uses an explicit dialog and selected team', (
    tester,
  ) async {
    final client = _MasterDetailClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('create-project-name')), findsNothing);
    await tester.tap(find.byTooltip('新建项目'));
    await tester.pumpAndSettle();
    expect(find.byType(ProjectCreateDialog), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('create-project-name')),
      'Desktop App',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pumpAndSettle();
    expect(client.createdName, 'Desktop App');
    expect(client.createdOrgId, 'org-a');
  });

  testWidgets('narrow layout collapses the rail and keeps repo URLs visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _MasterDetailClient())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('projects-team-rail')), findsNothing);
    expect(
      find.byKey(const ValueKey('projects-compact-team-picker')),
      findsOneWidget,
    );
    expect(find.text('https://github.com/acme/backend.git'), findsOneWidget);
    final repo = tester.widget<Text>(
      find.byKey(const ValueKey('project-row-repos-p1')),
    );
    expect(repo.maxLines, 1);
    expect(repo.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow selected-team tabs fit without the desktop rail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _MasterDetailClient())),
      ),
    );
    await tester.pumpAndSettle();
    final picker = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    picker.onChanged!('org:org-a');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('projects-team-rail')), findsNothing);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('成员'), findsOneWidget);
    expect(find.text('邀请'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('project-team-tab-1')));
    await tester.pumpAndSettle();
    expect(find.text('Owner'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop master-detail visual regression', (tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _MasterDetailClient())),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(ProjectsPage),
      matchesGoldenFile('goldens/projects_master_desktop.png'),
    );
  });

  testWidgets('narrow master-detail visual regression', (tester) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(body: ProjectsPage(client: _MasterDetailClient())),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(ProjectsPage),
      matchesGoldenFile('goldens/projects_master_narrow.png'),
    );
  });
}
