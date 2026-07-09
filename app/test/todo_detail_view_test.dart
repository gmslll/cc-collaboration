import 'dart:async';

import 'package:app/api/relay_client.dart';
import 'package:app/api/todo_models.dart';
import 'package:app/local/config.dart';
import 'package:app/local/session_overview.dart';
import 'package:app/local/todo_permissions.dart';
import 'package:app/screens/todo_detail_view.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('stale todo detail load cannot overwrite a newer todo', (
    tester,
  ) async {
    final client = _DelayedTodoClient();
    final first = _todo('td1', 'first list title');
    final second = _todo('td2', 'second list title');

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodoDetailView(client: client, todo: first),
        ),
      ),
    );
    await tester.pump();
    expect(client.requestedTodos, ['td1']);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodoDetailView(client: client, todo: second),
        ),
      ),
    );
    await tester.pump();
    expect(client.requestedTodos, ['td1', 'td2']);

    client.completeTodo('td2', _todo('td2', 'second full title'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'second full title'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'first full title'), findsNothing);

    client.completeTodo('td1', _todo('td1', 'first full title'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'second full title'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'first full title'), findsNothing);
  });

  testWidgets('stale todo detail load cannot overwrite a newer client', (
    tester,
  ) async {
    final oldClient = _DelayedTodoClient();
    final newClient = _DelayedTodoClient();
    final listTodo = _todo('td1', 'list title');

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodoDetailView(client: oldClient, todo: listTodo),
        ),
      ),
    );
    await tester.pump();
    expect(oldClient.requestedTodos, ['td1']);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodoDetailView(client: newClient, todo: listTodo),
        ),
      ),
    );
    await tester.pump();
    expect(newClient.requestedTodos, ['td1']);

    newClient.completeTodo('td1', _todo('td1', 'new account title'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'new account title'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'old account title'), findsNothing);

    oldClient.completeTodo('td1', _todo('td1', 'old account title'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'new account title'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'old account title'), findsNothing);
  });

  testWidgets('same-todo detail refresh does not cancel comment reload', (
    tester,
  ) async {
    final client = _DelayedTodoClient(delayComments: true);
    final first = _todo('td1', 'title', updatedAt: '2026-01-01T00:00:00Z');
    final refreshed = _todo('td1', 'title', updatedAt: '2026-01-01T00:00:01Z');

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodoDetailView(client: client, todo: first),
        ),
      ),
    );
    await tester.pump();
    expect(client.requestedComments, ['td1']);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodoDetailView(client: client, todo: refreshed),
        ),
      ),
    );
    await tester.pump();

    client.completeComments('td1', [_comment('alice@x', 'comment landed')]);
    await tester.pump();
    expect(find.text('comment landed'), findsOneWidget);
  });

  testWidgets('read-only todo detail hides comment input', (tester) async {
    final client = _DelayedTodoClient();
    final todo = _todo('td-readonly', 'read only title');

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodoDetailView(
            client: client,
            todo: todo,
            access: TodoAccess.none,
          ),
        ),
      ),
    );
    await tester.pump();

    client.completeTodo('td-readonly', todo);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, '写评论…'), findsNothing);
    expect(find.widgetWithIcon(IconButton, Icons.send_rounded), findsNothing);
  });

  testWidgets('comment submit ignores duplicate taps while posting', (
    tester,
  ) async {
    final client = _DelayedTodoClient(delayPostComment: true);
    final todo = _todo('td-comment', 'comment title');

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodoDetailView(client: client, todo: todo),
        ),
      ),
    );
    await tester.pump();
    client.completeTodo('td-comment', todo);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'ship it');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    await tester.tap(find.byType(IconButton).last);
    await tester.pump();

    expect(client.postedComments, ['td-comment:ship it']);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    client.completePost('td-comment', 'ship it');
    await tester.pumpAndSettle();

    expect(client.postedComments, ['td-comment:ship it']);
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
  });

  testWidgets('delete action ignores duplicate taps while pending', (
    tester,
  ) async {
    final client = _DelayedTodoClient(delayDelete: true);
    final todo = _todo('td-delete', 'delete title');
    var deleted = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodoDetailView(
            client: client,
            todo: todo,
            onDeleted: () => deleted++,
          ),
        ),
      ),
    );
    await tester.pump();
    client.completeTodo('td-delete', todo);
    await tester.pumpAndSettle();

    Finder deleteButton() =>
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '删除待办');

    await tester.tap(deleteButton());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();

    expect(client.deleteCalls, 1);
    expect(tester.widget<IconButton>(deleteButton()).onPressed, isNull);

    await tester.tap(deleteButton());
    await tester.pump();
    expect(client.deleteCalls, 1);
    expect(deleted, 0);

    client.completeDelete();
    await tester.pumpAndSettle();

    expect(client.deleteCalls, 1);
    expect(deleted, 1);
    expect(tester.widget<IconButton>(deleteButton()).onPressed, isNotNull);
  });

  testWidgets('property controls are locked while an update is pending', (
    tester,
  ) async {
    final client = _DelayedTodoClient(delayUpdate: true);
    final todo = _todo('td-props', 'property title');

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodoDetailView(client: client, todo: todo),
        ),
      ),
    );
    await tester.pump();
    client.completeTodo('td-props', todo);
    await tester.pumpAndSettle();

    Finder priorityLabel() => find.descendant(
      of: find.byType(TodoDetailView),
      matching: find.text('普通'),
    );

    await tester.tap(priorityLabel());
    await tester.pumpAndSettle();
    await tester.tap(find.text('高'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(client.updateCalls, 1);
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    await tester.tap(priorityLabel());
    await tester.pump();

    expect(client.updateCalls, 1);
    if (find.text('低').evaluate().isNotEmpty) {
      await tester.tap(find.text('低'), warnIfMissed: false);
      await tester.pump();
    }
    expect(client.updateCalls, 1);

    client.completeUpdate(
      _todo('td-props', 'property title', priority: 'high'),
    );
    await tester.pumpAndSettle();

    expect(client.updateCalls, 1);
    expect(find.text('高'), findsOneWidget);
    expect(find.text('普通'), findsNothing);
  });

  testWidgets('stale text save response cannot overwrite a newer save', (
    tester,
  ) async {
    final client = _DelayedTodoClient(delayUpdate: true);
    final todo = _todo('td-save-race', 'initial title');
    final changed = <Todo>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodoDetailView(
            client: client,
            todo: todo,
            onChanged: changed.add,
          ),
        ),
      ),
    );
    await tester.pump();
    client.completeTodo('td-save-race', todo);
    await tester.pumpAndSettle();

    final titleField = find.byType(TextField).first;
    await tester.enterText(titleField, 'older title');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.enterText(titleField, 'newer title');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    final firstOlderSave = client.updatedTitles.indexOf('older title');
    final latestNewerSave = client.updatedTitles.lastIndexOf('newer title');
    expect(firstOlderSave, isNot(-1));
    expect(latestNewerSave, isNot(-1));
    expect(latestNewerSave, greaterThan(firstOlderSave));

    client.completeUpdate(
      _todo('td-save-race', 'newer title'),
      index: latestNewerSave,
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'newer title'), findsOneWidget);
    expect(changed.map((t) => t.title), ['newer title']);

    client.completeUpdate(
      _todo('td-save-race', 'older title'),
      index: firstOlderSave,
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'newer title'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'older title'), findsNothing);
    expect(changed.map((t) => t.title), ['newer title']);
  });

  testWidgets('resume session failure releases the action button', (
    tester,
  ) async {
    final client = _DelayedTodoClient();
    final overview = SessionOverviewStore();
    final spawn = Completer<(String?, String?)>();
    var spawnCalls = 0;
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
        }) {
          spawnCalls++;
          return spawn.future;
        };

    final todo = _todo(
      'td-resume-fail',
      'resume title',
      assigneeIdentity: 'bot@x',
      assigneeAgentSessionId: 'agent-session-1',
      assigneeWorkdir: '/tmp/cc-project',
      assigneeAgentKind: 'codex',
    );
    final config = AppConfig(
      'http://127.0.0.1',
      'tok',
      'me@x',
      const {},
      const [
        WorkspaceCfg('ws', '/tmp', 'codex', '', '', [
          ProjectCfg('proj', '/tmp/cc-project'),
        ]),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: TodoDetailView(
            client: client,
            todo: todo,
            overviewStore: overview,
            config: config,
          ),
        ),
      ),
    );
    await tester.pump();

    Finder resumeButton() => find.widgetWithText(TextButton, '打开/恢复会话');

    await tester.tap(resumeButton());
    await tester.pump();

    expect(spawnCalls, 1);
    expect(tester.widget<TextButton>(resumeButton()).onPressed, isNull);

    spawn.complete((null, 'boom'));
    await tester.pumpAndSettle();

    expect(find.text('恢复会话失败: boom'), findsOneWidget);
    expect(tester.widget<TextButton>(resumeButton()).onPressed, isNotNull);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}

Todo _todo(
  String id,
  String title, {
  String updatedAt = '2026-01-01T00:00:00Z',
  String priority = 'normal',
  String? assigneeIdentity,
  String? assigneeAgentSessionId,
  String? assigneeWorkdir,
  String? assigneeAgentKind,
}) {
  final json = <String, dynamic>{
    'id': id,
    'owner_identity': 'me@x',
    'title': title,
    'body_md': '',
    'status': 'todo',
    'priority': priority,
    'created_at': '2026-01-01T00:00:00Z',
    'updated_at': updatedAt,
    'comment_count': 0,
    'attachment_count': 0,
    'attachments': <Map<String, dynamic>>[],
  };
  if (assigneeIdentity != null) {
    json['assignee_identity'] = assigneeIdentity;
  }
  if (assigneeAgentSessionId != null) {
    json['assignee_agent_session_id'] = assigneeAgentSessionId;
  }
  if (assigneeWorkdir != null) {
    json['assignee_workdir'] = assigneeWorkdir;
  }
  if (assigneeAgentKind != null) {
    json['assignee_agent_kind'] = assigneeAgentKind;
  }
  return Todo.fromJson(json);
}

TodoComment _comment(String author, String body) => TodoComment.fromJson({
  'author_identity': author,
  'body': body,
  'created_at': '2026-01-01T00:00:00Z',
});

class _DelayedTodoClient extends RelayClient {
  _DelayedTodoClient({
    this.delayComments = false,
    this.delayPostComment = false,
    this.delayDelete = false,
    this.delayUpdate = false,
  }) : super('http://127.0.0.1', 'tok');

  final bool delayComments;
  final bool delayPostComment;
  final bool delayDelete;
  final bool delayUpdate;

  final requestedTodos = <String>[];
  final requestedComments = <String>[];
  final postedComments = <String>[];
  final updatedTitles = <String>[];
  int deleteCalls = 0;
  int updateCalls = 0;
  final _todos = <String, Completer<Todo>>{};
  final _comments = <String, Completer<List<TodoComment>>>{};
  final _posts = <String, Completer<TodoComment>>{};
  final _delete = Completer<void>();
  final _updates = <Completer<Todo>>[];

  @override
  Future<Todo> todo(String id) {
    requestedTodos.add(id);
    final completer = Completer<Todo>();
    _todos[id] = completer;
    return completer.future;
  }

  @override
  Future<List<TodoComment>> todoComments(String id) {
    requestedComments.add(id);
    if (!delayComments) return Future.value(const []);
    final completer = Completer<List<TodoComment>>();
    _comments[id] = completer;
    return completer.future;
  }

  @override
  Future<TodoComment> postTodoComment(String id, String body) {
    postedComments.add('$id:$body');
    if (!delayPostComment) return Future.value(_comment('me@x', body));
    final completer = Completer<TodoComment>();
    _posts['$id:$body'] = completer;
    return completer.future;
  }

  @override
  Future<void> deleteTodo(String id) {
    deleteCalls++;
    if (!delayDelete) return Future.value();
    return _delete.future;
  }

  @override
  Future<Todo> updateTodo(
    String id, {
    String? title,
    String? bodyMd,
    String? priority,
    String? recurrence,
    DateTime? dueAt,
    bool clearDueAt = false,
    String? workspaceName,
    String? repoName,
    String? groupName,
  }) {
    updateCalls++;
    updatedTitles.add(title ?? '');
    if (delayUpdate) {
      final completer = Completer<Todo>();
      _updates.add(completer);
      return completer.future;
    }
    return Future.value(
      _todo(id, title ?? 'updated', priority: priority ?? 'normal'),
    );
  }

  void completeTodo(String id, Todo todo) {
    _todos[id]!.complete(todo);
  }

  void completeComments(String id, List<TodoComment> comments) {
    _comments[id]!.complete(comments);
  }

  void completePost(String id, String body) {
    _posts['$id:$body']!.complete(_comment('me@x', body));
  }

  void completeDelete() {
    if (!_delete.isCompleted) _delete.complete();
  }

  void completeUpdate(Todo todo, {int index = 0}) {
    if (!_updates[index].isCompleted) _updates[index].complete(todo);
  }
}
