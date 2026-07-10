import 'dart:async';
import 'dart:io';

import 'package:app/api/models.dart';
import 'package:app/api/relay_client.dart';
import 'package:app/api/todo_models.dart';
import 'package:app/local/config.dart';
import 'package:app/local/session_overview.dart';
import 'package:app/local/todo_store.dart';
import 'package:app/remote/remote_client.dart';
import 'package:app/screens/todos_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('todo assignment session cards are scoped to team project', () {
    final cards = [
      _sessionCard('s1', project: 'Backend', projectId: 'p-backend'),
      _sessionCard('s2', project: 'Backend'),
      _sessionCard('s3', project: 'Frontend', projectId: 'p-frontend'),
      _sessionCard('s4', project: 'Other'),
    ];

    expect(
      [
        for (final c in assignableSessionCardsForTodoProject(
          cards,
          todoProjectId: 'p-backend',
          todoProjectName: 'Backend',
        ))
          c.sid,
      ],
      ['s1', 's2'],
    );
    expect(
      [
        for (final c in assignableSessionCardsForTodoProject(
          cards,
          todoProjectId: null,
          todoProjectName: null,
        ))
          c.sid,
      ],
      ['s1', 's2', 's3', 's4'],
    );
  });

  test('todo assignment project name resolves from remote roots first', () {
    expect(
      todoProjectNameForAssignment(
        todoProjectId: 'p1',
        localProjects: const [ProjectCfg('Local', '/repo/local', '', 'p1')],
        remoteRoots: [RemoteRootInfo('Remote', '/repo/remote', 'ws', 'p1')],
      ),
      'Remote',
    );
  });

  test('todo member assignment list height is responsive', () {
    expect(todoMemberListMaxHeight(const Size(1024, 900)), 320);
    expect(
      todoMemberListMaxHeight(const Size(320, 420)),
      closeTo(201.6, 0.001),
    );
    expect(todoMemberListMaxHeight(const Size(320, 220)), 144);
  });

  test('todo quick create dialog size fits compact screens', () {
    expect(
      todoQuickCreateDialogSize(const Size(1200, 900)),
      const Size(560, 720),
    );
    expect(
      todoQuickCreateDialogSize(const Size(360, 420)),
      const Size(328, 372),
    );
    expect(
      todoQuickCreateDialogSize(const Size(220, 220)),
      const Size(188, 172),
    );
  });

  test('todo quick create dialog uses viewport based bounds', () {
    final source = File('lib/screens/todos_page.dart').readAsStringSync();
    final quickCreate = source.substring(
      source.indexOf('class _QuickCreateDialogState'),
      source.indexOf('class _AssignTodoDialog'),
    );

    expect(quickCreate, contains('todoQuickCreateDialogSize'));
    expect(quickCreate, contains('MediaQuery.sizeOf(context)'));
    expect(quickCreate, contains('maxWidth: dialogSize.width'));
    expect(quickCreate, contains('maxHeight: dialogSize.height'));
    expect(quickCreate, isNot(contains('maxWidth: 560')));
  });

  test('todo desktop panes adapt near the wide breakpoint', () {
    expect(todoListPaneWidth(720), closeTo(316.8, 0.001));
    expect(todoListPaneWidth(900), 360);
    expect(todoListPaneWidth(double.infinity), 360);

    expect(todoBoardDetailPaneWidth(720), closeTo(331.2, 0.001));
    expect(todoBoardDetailPaneWidth(900), 380);
    expect(todoBoardDetailPaneWidth(double.infinity), 380);
  });

  testWidgets('team todo empty state ignores personal-only todos', (
    tester,
  ) async {
    final client = _DelayedAssignTodoClient();
    final store = TodoStore()
      ..debugSetClient(client)
      ..all = [
        Todo.fromJson(
          _todoJson(
            id: 'personal-only',
            title: 'Personal only',
            projectId: null,
          ),
        ),
      ];

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodosPage(
            client: client,
            config: _config(),
            me: _adminMe(),
            store: store,
            overviewStore: SessionOverviewStore(),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('团队'));
    await tester.pumpAndSettle();

    expect(find.text('还没有团队待办'), findsOneWidget);
    expect(find.text('Relay 团队视图暂时为空。'), findsOneWidget);
    expect(find.text('无匹配'), findsNothing);
  });

  testWidgets('team todo empty state separates filters from empty scope', (
    tester,
  ) async {
    final client = _DelayedAssignTodoClient();
    final store = TodoStore()
      ..debugSetClient(client)
      ..all = [client.teamTodo];

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodosPage(
            client: client,
            config: _config(),
            me: _adminMe(),
            store: store,
            overviewStore: SessionOverviewStore(),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('团队'));
    await tester.pumpAndSettle();
    expect(find.text('Team todo'), findsOneWidget);

    await tester.tap(find.text('已完成'));
    await tester.pumpAndSettle();

    expect(find.text('没有匹配的待办'), findsOneWidget);
    expect(find.text('清除筛选'), findsOneWidget);
    expect(find.text('还没有团队待办'), findsNothing);

    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();

    expect(find.text('Team todo'), findsOneWidget);
  });

  testWidgets('bulk todo deletion locks while request is pending', (
    tester,
  ) async {
    final client = _DelayedDeleteTodoClient();
    final store = TodoStore()
      ..debugSetClient(client)
      ..all = [client.teamTodo];

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodosPage(
            client: client,
            config: _config(),
            me: _adminMe(),
            store: store,
            overviewStore: SessionOverviewStore(),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('团队'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('选择当前筛选结果'));
    await tester.pump();
    expect(find.text('已选 1'), findsOneWidget);

    await tester.tap(find.byTooltip('删除选中待办'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('删除 1 个待办？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();

    expect(client.deleteCalls, 1);
    expect(find.text('删除 1 个待办？'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.byType(CircularProgressIndicator));
    await tester.pump();
    expect(client.deleteCalls, 1);
    expect(find.text('删除 1 个待办？'), findsNothing);

    client.completeDelete();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'bulk todo deletion confirmation after account switch is ignored',
    (tester) async {
      final oldClient = _DelayedDeleteTodoClient();
      final newClient = _DelayedDeleteTodoClient();
      final oldStore = TodoStore()
        ..debugSetClient(oldClient)
        ..all = [oldClient.teamTodo];
      final newStore = TodoStore()
        ..debugSetClient(newClient)
        ..all = [
          Todo.fromJson(
            _todoJson(
              id: 'new-todo',
              title: 'New account todo',
              projectId: null,
            ),
          ),
        ];

      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      Widget page({
        required RelayClient client,
        required TodoStore store,
        required AppConfig config,
        required Me me,
      }) => MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodosPage(
            client: client,
            config: config,
            me: me,
            store: store,
            overviewStore: SessionOverviewStore(),
          ),
        ),
      );

      await tester.pumpWidget(
        page(
          client: oldClient,
          config: _config(token: 'old', identity: 'old@x'),
          me: _adminMe(identity: 'old@x'),
          store: oldStore,
        ),
      );
      await tester.pump();

      await tester.tap(find.text('团队'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('选择当前筛选结果'));
      await tester.pump();
      expect(find.text('已选 1'), findsOneWidget);

      await tester.tap(find.byTooltip('删除选中待办'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('删除 1 个待办？'), findsOneWidget);

      await tester.pumpWidget(
        page(
          client: newClient,
          config: _config(token: 'new', identity: 'new@x'),
          me: _adminMe(identity: 'new@x'),
          store: newStore,
        ),
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(oldClient.deleteCalls, 0);
      expect(newClient.deleteCalls, 0);
      expect(find.text('New account todo'), findsOneWidget);
    },
  );

  testWidgets('team quick create dialog scrolls on compact screens', (
    tester,
  ) async {
    final client = _CreateTodoClient();
    final store = TodoStore()..debugSetClient(client);
    const longProjectName = '团队协作跨项目超长项目名称-用于验证新建待办弹窗不会撑开布局';

    await tester.binding.setSurfaceSize(const Size(360, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodosPage(
            client: client,
            config: _config(),
            me: _meWithProject('p-long', longProjectName),
            store: store,
            overviewStore: SessionOverviewStore(),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('团队'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('新建待办').first);
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(SingleChildScrollView),
      ),
      findsWidgets,
    );
    expect(find.widgetWithText(FilledButton, '创建'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('quick create after account switch is ignored', (tester) async {
    final oldClient = _CreateTodoClient();
    final newClient = _CreateTodoClient();
    final oldStore = TodoStore()
      ..debugSetClient(oldClient)
      ..all = [
        Todo.fromJson(
          _todoJson(id: 'old-todo', title: 'Old account todo', projectId: null),
        ),
      ];
    final newStore = TodoStore()
      ..debugSetClient(newClient)
      ..all = [
        Todo.fromJson(
          _todoJson(id: 'new-todo', title: 'New account todo', projectId: null),
        ),
      ];

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Widget page({
      required RelayClient client,
      required TodoStore store,
      required AppConfig config,
      required Me me,
    }) => MaterialApp(
      theme: ccTheme(),
      home: Scaffold(
        body: TodosPage(
          client: client,
          config: config,
          me: me,
          store: store,
          overviewStore: SessionOverviewStore(),
        ),
      ),
    );

    await tester.pumpWidget(
      page(
        client: oldClient,
        config: _config(token: 'old', identity: 'old@x'),
        me: _adminMe(identity: 'old@x'),
        store: oldStore,
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('新建待办').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Should not create');
    await tester.pump();

    await tester.pumpWidget(
      page(
        client: newClient,
        config: _config(token: 'new', identity: 'new@x'),
        me: _adminMe(identity: 'new@x'),
        store: newStore,
      ),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pumpAndSettle();

    expect(oldClient.createCalls, 0);
    expect(newClient.createCalls, 0);
    expect(find.text('New account todo'), findsOneWidget);
  });

  testWidgets('pending quick create after account switch closes stale dialog', (
    tester,
  ) async {
    final oldClient = _PendingCreateTodoClient();
    final newClient = _CreateTodoClient();
    final oldStore = TodoStore()
      ..debugSetClient(oldClient)
      ..all = [
        Todo.fromJson(
          _todoJson(id: 'old-todo', title: 'Old account todo', projectId: null),
        ),
      ];
    final newStore = TodoStore()
      ..debugSetClient(newClient)
      ..all = [
        Todo.fromJson(
          _todoJson(id: 'new-todo', title: 'New account todo', projectId: null),
        ),
      ];

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Widget page({
      required RelayClient client,
      required TodoStore store,
      required AppConfig config,
      required Me me,
    }) => MaterialApp(
      theme: ccTheme(),
      home: Scaffold(
        body: TodosPage(
          client: client,
          config: config,
          me: me,
          store: store,
          overviewStore: SessionOverviewStore(),
        ),
      ),
    );

    await tester.pumpWidget(
      page(
        client: oldClient,
        config: _config(token: 'old', identity: 'old@x'),
        me: _adminMe(identity: 'old@x'),
        store: oldStore,
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('新建待办').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Should not refresh');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pump();
    expect(oldClient.createCalls, 1);

    await tester.pumpWidget(
      page(
        client: newClient,
        config: _config(token: 'new', identity: 'new@x'),
        me: _adminMe(identity: 'new@x'),
        store: newStore,
      ),
    );
    await tester.pump();

    oldClient.completeCreate();
    await tester.pumpAndSettle();

    expect(newClient.createCalls, 0);
    expect(find.widgetWithText(FilledButton, '创建'), findsNothing);
    expect(find.text('New account todo'), findsOneWidget);
  });

  testWidgets('member assignment ignores duplicate submit taps', (
    tester,
  ) async {
    final client = _DelayedAssignTodoClient();
    final store = TodoStore()
      ..debugSetClient(client)
      ..all = [client.teamTodo];

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodosPage(
            client: client,
            config: _config(),
            me: _me(),
            store: store,
            overviewStore: SessionOverviewStore(),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('团队'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Team todo'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '指派'));
    await tester.pumpAndSettle();

    expect(find.text('指派给成员'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);

    final submit = find.widgetWithText(FilledButton, '指派');
    await tester.tap(submit);
    await tester.tap(submit);
    await tester.pump();

    expect(client.assignCalls, 1);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
      isNull,
    );

    client.completeAssign();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing session assignment dispatch failure releases submit', (
    tester,
  ) async {
    final client = _DelayedAssignTodoClient();
    final store = TodoStore()
      ..debugSetClient(client)
      ..all = [client.teamTodo];
    var dispatchCalls = 0;
    final overview = SessionOverviewStore()
      ..publish([_sessionCard('s1', project: 'Backend', projectId: 'p1')]);
    overview.dispatchHandler = (_) {
      dispatchCalls++;
      throw StateError('boom');
    };

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodosPage(
            client: client,
            config: _config(),
            me: _me(),
            store: store,
            overviewStore: overview,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('团队'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Team todo'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '指派'));
    await tester.pumpAndSettle();

    expect(find.text('一键指派'), findsOneWidget);
    final submit = find.widgetWithText(FilledButton, '指派并开始');
    await tester.tap(submit);
    for (var i = 0; i < 12 && dispatchCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();

    expect(dispatchCalls, 1);
    expect(find.textContaining('投递失败'), findsOneWidget);
    expect(find.text('一键指派'), findsOneWidget);
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('assignment dialog title is constrained on compact screens', (
    tester,
  ) async {
    final client = _DelayedAssignTodoClient();
    final store = TodoStore()
      ..debugSetClient(client)
      ..all = [client.teamTodo];
    final overview = SessionOverviewStore()
      ..publish([_sessionCard('s1', project: 'Backend', projectId: 'p1')]);

    await tester.binding.setSurfaceSize(const Size(320, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodosPage(
            client: client,
            config: _config(),
            me: _me(),
            store: store,
            overviewStore: overview,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('团队'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Team todo'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('指派'));
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(find.text('一键指派'));

    expect(tester.takeException(), isNull);
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
  });

  testWidgets('member assignment load error is clamped on compact screens', (
    tester,
  ) async {
    final client = _ThrowingMemberLoadClient();
    final store = TodoStore()
      ..debugSetClient(client)
      ..all = [client.teamTodo];

    await tester.binding.setSurfaceSize(const Size(320, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodosPage(
            client: client,
            config: _config(),
            me: _me(),
            store: store,
            overviewStore: SessionOverviewStore(),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('团队'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Team todo'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('指派'));
    await tester.pumpAndSettle();

    final error = tester.widget<Text>(find.textContaining('加载成员失败'));

    expect(tester.takeException(), isNull);
    expect(error.maxLines, 3);
    expect(error.overflow, TextOverflow.ellipsis);
  });

  testWidgets('new session assignment dispatch failure stays unassigned', (
    tester,
  ) async {
    final client = _DelayedAssignTodoClient();
    final store = TodoStore()
      ..debugSetClient(client)
      ..all = [client.teamTodo];
    var spawnCalls = 0;
    var dispatchCalls = 0;
    final overview = SessionOverviewStore()
      ..publish([
        _sessionCard('existing', project: 'Backend', projectId: 'p1'),
      ]);
    overview.spawnHandler =
        ({
          required workspace,
          required project,
          required kind,
          projectId,
          newWorktreeBranch,
          worktreeStart,
          resumeAgentSessionId,
          workdir,
        }) async {
          spawnCalls++;
          return ('new-sid', null);
        };
    overview.dispatchHandler = (_) {
      dispatchCalls++;
      return 'bus down';
    };

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodosPage(
            client: client,
            config: _config(
              workspaces: const [
                WorkspaceCfg('ws', '/tmp', 'claude', '', '', [
                  ProjectCfg('Backend', '/tmp/backend', '', 'p1'),
                ]),
              ],
            ),
            me: _me(),
            store: store,
            overviewStore: overview,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('团队'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Team todo'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '指派'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建会话'));
    await tester.pumpAndSettle();

    final submit = find.widgetWithText(FilledButton, '指派并开始');
    await tester.tap(submit);
    for (var i = 0; i < 20 && dispatchCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();

    expect(spawnCalls, 1);
    expect(dispatchCalls, 1);
    expect(client.assignCalls, 0);
    expect(client.statusCalls, 0);
    expect(find.textContaining('会话已创建，但投递失败'), findsOneWidget);
    expect(find.text('一键指派'), findsOneWidget);
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote existing assignment exception releases submit', (
    tester,
  ) async {
    final client = _DelayedAssignTodoClient();
    final store = TodoStore()
      ..debugSetClient(client)
      ..all = [client.teamTodo];
    final remote = _ThrowingAssignRemoteClient();
    addTearDown(() {
      if (identical(phoneRemoteClient, remote)) phoneRemoteClient = null;
      remote.dispose();
    });
    phoneRemoteClient = remote;
    remote.onFrame({'t': 'sessions', 'items': const []});
    remote.onFrame({
      't': 'overview',
      'items': [
        _sessionCard('remote-s1', project: 'Backend', projectId: 'p1').toJson(),
      ],
    });

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodosPage(
            client: client,
            config: _config(),
            me: _me(),
            store: store,
            overviewStore: SessionOverviewStore(),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('团队'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Team todo'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '指派'));
    await tester.pumpAndSettle();

    expect(find.text('一键指派'), findsOneWidget);
    final submit = find.widgetWithText(FilledButton, '指派并开始');
    await tester.tap(submit);
    await tester.pump();

    expect(remote.assignCalls, 1);
    expect(find.textContaining('远程指派失败'), findsOneWidget);
    expect(find.text('一键指派'), findsOneWidget);
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('pending member assignment after account switch is ignored', (
    tester,
  ) async {
    final oldClient = _DelayedAssignTodoClient();
    final newClient = _DelayedAssignTodoClient();
    final oldStore = TodoStore()
      ..debugSetClient(oldClient)
      ..all = [oldClient.teamTodo];
    final newStore = TodoStore()
      ..debugSetClient(newClient)
      ..all = [
        Todo.fromJson(
          _todoJson(id: 'new-todo', title: 'New account todo', projectId: null),
        ),
      ];

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Widget page({
      required RelayClient client,
      required TodoStore store,
      required AppConfig config,
      required Me me,
    }) => MaterialApp(
      theme: ccTheme(),
      home: Scaffold(
        body: TodosPage(
          client: client,
          config: config,
          me: me,
          store: store,
          overviewStore: SessionOverviewStore(),
        ),
      ),
    );

    await tester.pumpWidget(
      page(
        client: oldClient,
        config: _config(token: 'old', identity: 'alice@x'),
        me: _me(),
        store: oldStore,
      ),
    );
    await tester.pump();

    await tester.tap(find.text('团队'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Team todo'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '指派'));
    await tester.pumpAndSettle();

    expect(find.text('指派给成员'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '指派'));
    await tester.pump();
    expect(oldClient.assignCalls, 1);

    await tester.pumpWidget(
      page(
        client: newClient,
        config: _config(token: 'new', identity: 'new@x'),
        me: _adminMe(identity: 'new@x'),
        store: newStore,
      ),
    );
    await tester.pump();

    oldClient.completeAssign();
    await tester.pumpAndSettle();

    expect(newClient.assignCalls, 0);
    expect(find.text('指派给成员'), findsNothing);
    expect(find.text('New account todo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('viewer team todo hides assignment actions', (tester) async {
    final client = _DelayedAssignTodoClient();
    final store = TodoStore()
      ..debugSetClient(client)
      ..all = [client.teamTodo];

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodosPage(
            client: client,
            config: _config(),
            me: _viewerMe(),
            store: store,
            overviewStore: SessionOverviewStore(),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('团队'));
    await tester.pumpAndSettle();

    expect(find.text('Team todo'), findsOneWidget);
    expect(find.byTooltip('一键指派'), findsNothing);

    await tester.tap(find.text('Team todo'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, '指派'), findsNothing);
  });

  testWidgets('account switch ignores stale todo view and project loads', (
    tester,
  ) async {
    final oldClient = _DelayedTodoPageContextClient(
      setting: const {
        'scope': 'team',
        'teamSource': 'relay',
        'projectFilter': 'old-p',
      },
      meValue: _meWithProject('old-p', 'Old Project'),
    );
    final newClient = _DelayedTodoPageContextClient(
      setting: null,
      meValue: _meWithProject('new-p', 'New Project'),
    );
    final oldStore = TodoStore()
      ..debugSetClient(oldClient)
      ..all = [
        Todo.fromJson(_todoJson(id: 'old', title: 'Old todo', projectId: null)),
      ];
    final newStore = TodoStore()
      ..debugSetClient(newClient)
      ..all = [
        Todo.fromJson(_todoJson(id: 'new', title: 'New todo', projectId: null)),
      ];

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodosPage(
            client: oldClient,
            config: _config(token: 'old', identity: 'old@x'),
            me: _meWithProject('old-p', 'Old Project'),
            store: oldStore,
            overviewStore: SessionOverviewStore(),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodosPage(
            client: newClient,
            config: _config(token: 'new', identity: 'new@x'),
            me: _meWithProject('new-p', 'New Project'),
            store: newStore,
            overviewStore: SessionOverviewStore(),
          ),
        ),
      ),
    );
    await tester.pump();

    newClient.completeAll();
    await tester.pumpAndSettle();
    expect(find.text('New todo'), findsOneWidget);

    oldClient.completeAll();
    await tester.pumpAndSettle();

    expect(find.text('New todo'), findsOneWidget);
    expect(find.text('Old todo'), findsNothing);
    expect(find.text('Old Project'), findsNothing);
  });
}

SessionCard _sessionCard(
  String sid, {
  String project = '',
  String projectId = '',
  String? workdir,
}) => SessionCard(
  sid: sid,
  label: sid,
  agentKind: 'claude',
  isAgent: true,
  workspace: 'ws',
  project: project,
  projectId: projectId,
  worktree: null,
  status: SessionStatus.idle,
  usageLabel: null,
  preview: '',
  workdir: workdir,
);

AppConfig _config({
  String token = 'tok',
  String identity = 'alice@x',
  List<WorkspaceCfg> workspaces = const [],
}) => AppConfig('http://127.0.0.1', token, identity, const {}, workspaces);

Me _me() => Me.fromJson({
  'identity': 'alice@x',
  'is_admin': false,
  'projects': [
    {'id': 'p1', 'org_id': 'org1', 'name': 'Backend', 'role': 'member'},
  ],
});

Me _viewerMe() => Me.fromJson({
  'identity': 'alice@x',
  'is_admin': false,
  'projects': [
    {'id': 'p1', 'org_id': 'org1', 'name': 'Backend', 'role': 'viewer'},
  ],
});

Me _adminMe({String identity = 'alice@x'}) => Me.fromJson({
  'identity': identity,
  'is_admin': true,
  'projects': [
    {'id': 'p1', 'org_id': 'org1', 'name': 'Backend', 'role': 'owner'},
  ],
});

Me _meWithProject(String projectId, String projectName) => Me.fromJson({
  'identity': 'alice@x',
  'is_admin': false,
  'projects': [
    {'id': projectId, 'org_id': 'org1', 'name': projectName, 'role': 'member'},
  ],
});

Map<String, dynamic> _todoJson({
  String id = 't1',
  String title = 'Team todo',
  String? projectId = 'p1',
  String status = 'todo',
  String? assigneeIdentity,
}) => {
  'id': id,
  'project_id': projectId,
  'owner_identity': 'alice@x',
  'title': title,
  'body_md': '',
  'status': status,
  'priority': 'normal',
  'assignee_identity': assigneeIdentity,
  'assignee_display_name': assigneeIdentity == null ? null : 'Bob',
  'assignee_session_id': null,
  'assignee_session_label': null,
  'recurrence': '',
  'due_at': null,
  'next_occurrence_at': null,
  'completed_at': null,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
  'comment_count': 0,
  'attachment_count': 0,
};

class _DelayedAssignTodoClient extends RelayClient {
  _DelayedAssignTodoClient() : super('http://127.0.0.1', 'tok');

  final Todo teamTodo = Todo.fromJson(_todoJson());
  final _assignCompleter = Completer<Todo>();
  int assignCalls = 0;
  int statusCalls = 0;

  @override
  Future<Map<String, dynamic>?> getSetting(String key) async => null;

  @override
  Future<void> putSetting(String key, Map<String, dynamic> value) async {}

  @override
  Future<List<String>> todoGroups({String? projectId}) async => const [];

  @override
  Future<Todo> todo(String id) async => teamTodo;

  @override
  Future<List<TodoComment>> todoComments(String id) async => const [];

  @override
  Future<Me> me() async => _me();

  @override
  Future<List<OnlineUser>> onlineUsers() async => [
    OnlineUser.fromJson({'identity': 'bob@x', 'online': true}),
  ];

  @override
  Future<ProjectDetail> project(String id) async => ProjectDetail.fromJson({
    'project': {
      'id': id,
      'org_id': 'org1',
      'name': 'Backend',
      'owner_identity': 'alice@x',
      'role': 'member',
    },
    'members': [
      {'identity': 'bob@x', 'display_name': 'Bob', 'role': 'member'},
    ],
  });

  @override
  Future<OrganizationDetail> organization(String id) async =>
      OrganizationDetail.fromJson({
        'organization': {
          'id': id,
          'name': 'Kunlun',
          'owner_identity': 'alice@x',
          'role': 'member',
        },
        'members': const [],
        'projects': const [],
      });

  @override
  Future<Todo> assignTodo(
    String id, {
    String? assigneeIdentity,
    String? assigneeSessionId,
    String? assigneeSessionLabel,
    String? assigneeAgentSessionId,
    String? assigneeWorkdir,
    String? assigneeAgentKind,
  }) {
    assignCalls++;
    return _assignCompleter.future;
  }

  @override
  Future<Todo> setTodoStatus(String id, TodoStatus status) async {
    statusCalls++;
    return Todo.fromJson({
      ..._todoJson(assigneeIdentity: 'bob@x'),
      'status': 'in_progress',
    });
  }

  @override
  Future<List<Todo>> todos({
    required String scope,
    String? project,
    String? status,
    String? group,
    int? limit,
  }) async => scope == 'project'
      ? [Todo.fromJson(_todoJson(assigneeIdentity: 'bob@x'))]
      : const [];

  void completeAssign() {
    _assignCompleter.complete(
      Todo.fromJson(_todoJson(assigneeIdentity: 'bob@x')),
    );
  }
}

class _ThrowingAssignRemoteClient extends RemoteClient {
  _ThrowingAssignRemoteClient()
    : super(relayUrl: 'http://127.0.0.1', token: 'tok');

  int assignCalls = 0;

  @override
  Future<String?> requestAssign({
    required String todoId,
    required String mode,
    String? sid,
    String? workspace,
    String? project,
    String? projectId,
    String? kind,
    String? branch,
  }) async {
    assignCalls++;
    throw StateError('bridge down');
  }
}

class _DelayedDeleteTodoClient extends _DelayedAssignTodoClient {
  final _deleteCompleter = Completer<void>();
  int deleteCalls = 0;

  @override
  Future<void> deleteTodo(String id) {
    deleteCalls++;
    return _deleteCompleter.future;
  }

  void completeDelete() {
    _deleteCompleter.complete();
  }
}

class _ThrowingMemberLoadClient extends _DelayedAssignTodoClient {
  @override
  Future<ProjectDetail> project(String id) {
    throw StateError(
      'team-member-load-failed-with-a-very-long-unbroken-relay-error-message-'
      'that-should-not-stretch-the-assignment-dialog-on-compact-screens',
    );
  }
}

class _CreateTodoClient extends _DelayedAssignTodoClient {
  int createCalls = 0;

  @override
  Future<Todo> createTodo({
    required String title,
    String bodyMd = '',
    String priority = 'normal',
    String? projectId,
    String recurrence = '',
    DateTime? dueAt,
    String? workspaceName,
    String? repoName,
    String? groupName,
  }) async {
    createCalls++;
    return Todo.fromJson(
      _todoJson(id: 'created', title: title, projectId: projectId),
    );
  }
}

class _PendingCreateTodoClient extends _CreateTodoClient {
  final _createCompleter = Completer<Todo>();

  @override
  Future<Todo> createTodo({
    required String title,
    String bodyMd = '',
    String priority = 'normal',
    String? projectId,
    String recurrence = '',
    DateTime? dueAt,
    String? workspaceName,
    String? repoName,
    String? groupName,
  }) {
    createCalls++;
    return _createCompleter.future;
  }

  void completeCreate() {
    _createCompleter.complete(
      Todo.fromJson(
        _todoJson(id: 'created', title: 'Created', projectId: null),
      ),
    );
  }
}

class _DelayedTodoPageContextClient extends RelayClient {
  _DelayedTodoPageContextClient({required this.setting, required this.meValue})
    : super('http://127.0.0.1', 'tok');

  final Map<String, dynamic>? setting;
  final Me meValue;
  final _settingCompleter = Completer<Map<String, dynamic>?>();
  final _meCompleter = Completer<Me>();
  final _groupsCompleters = <Completer<List<String>>>[];

  @override
  Future<Map<String, dynamic>?> getSetting(String key) =>
      _settingCompleter.future;

  @override
  Future<void> putSetting(String key, Map<String, dynamic> value) async {}

  @override
  Future<Me> me() => _meCompleter.future;

  @override
  Future<List<String>> todoGroups({String? projectId}) {
    final completer = Completer<List<String>>();
    _groupsCompleters.add(completer);
    return completer.future;
  }

  void completeAll() {
    if (!_settingCompleter.isCompleted) _settingCompleter.complete(setting);
    if (!_meCompleter.isCompleted) _meCompleter.complete(meValue);
    for (final completer in _groupsCompleters) {
      if (!completer.isCompleted) completer.complete(const []);
    }
  }
}
