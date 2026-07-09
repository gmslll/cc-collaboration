import 'dart:async';

import 'package:app/api/relay_client.dart';
import 'package:app/api/todo_models.dart';
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
}

Todo _todo(String id, String title) => Todo.fromJson({
  'id': id,
  'owner_identity': 'me@x',
  'title': title,
  'body_md': '',
  'status': 'todo',
  'priority': 'normal',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
  'comment_count': 0,
  'attachment_count': 0,
  'attachments': <Map<String, dynamic>>[],
});

class _DelayedTodoClient extends RelayClient {
  _DelayedTodoClient() : super('http://127.0.0.1', 'tok');

  final requestedTodos = <String>[];
  final _todos = <String, Completer<Todo>>{};

  @override
  Future<Todo> todo(String id) {
    requestedTodos.add(id);
    final completer = Completer<Todo>();
    _todos[id] = completer;
    return completer.future;
  }

  @override
  Future<List<TodoComment>> todoComments(String id) async => const [];

  void completeTodo(String id, Todo todo) {
    _todos[id]!.complete(todo);
  }
}
