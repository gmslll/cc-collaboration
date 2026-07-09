import 'dart:async';

import 'package:app/api/models.dart';
import 'package:app/api/relay_client.dart';
import 'package:app/api/todo_models.dart';
import 'package:app/local/config.dart';
import 'package:app/local/session_overview.dart';
import 'package:app/local/todo_store.dart';
import 'package:app/screens/todos_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

AppConfig _config({String token = 'tok', String identity = 'alice@x'}) =>
    AppConfig('http://127.0.0.1', token, identity, const {});

Me _me() => Me.fromJson({
  'identity': 'alice@x',
  'is_admin': false,
  'projects': [
    {'id': 'p1', 'org_id': 'org1', 'name': 'Backend', 'role': 'member'},
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
  String? assigneeIdentity,
}) => {
  'id': id,
  'project_id': projectId,
  'owner_identity': 'alice@x',
  'title': title,
  'body_md': '',
  'status': 'todo',
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
  Future<Todo> setTodoStatus(String id, TodoStatus status) async =>
      Todo.fromJson({
        ..._todoJson(assigneeIdentity: 'bob@x'),
        'status': 'in_progress',
      });

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
