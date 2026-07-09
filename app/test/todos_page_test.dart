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
}

AppConfig _config() =>
    AppConfig('http://127.0.0.1', 'tok', 'alice@x', const {});

Me _me() => Me.fromJson({
  'identity': 'alice@x',
  'is_admin': false,
  'projects': [
    {'id': 'p1', 'org_id': 'org1', 'name': 'Backend', 'role': 'member'},
  ],
});

Map<String, dynamic> _todoJson({String? assigneeIdentity}) => {
  'id': 't1',
  'project_id': 'p1',
  'owner_identity': 'alice@x',
  'title': 'Team todo',
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
