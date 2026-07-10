import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/api/relay_client.dart';
import 'package:app/api/sse.dart';
import 'package:app/api/todo_models.dart';
import 'package:app/local/todo_store.dart';
import 'package:flutter_test/flutter_test.dart';

// Hand-built canned JSON matching pkg/todoschema.Todo's wire shape (see
// app/lib/api/todo_models.dart). Only the fields a given test cares about
// need to vary; everything else gets a harmless default.
Map<String, dynamic> _todoJson({
  required String id,
  String? projectId,
  String status = 'todo',
  String title = 'title',
  String? assigneeIdentity,
  String? assigneeDisplayName,
}) => {
  'id': id,
  'project_id': projectId,
  'owner_identity': 'alice',
  'title': title,
  'body_md': '',
  'status': status,
  'priority': 'normal',
  'assignee_identity': assigneeIdentity,
  'assignee_display_name': assigneeDisplayName,
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

void main() {
  test(
    'mergeTodoRefreshResults deduplicates by id and keeps later payload',
    () {
      final merged = mergeTodoRefreshResults(
        [
          Todo.fromJson(_todoJson(id: 'p1', title: 'personal')),
          Todo.fromJson(_todoJson(id: 'dup', title: 'old')),
        ],
        [
          Todo.fromJson(_todoJson(id: 'dup', projectId: 'proj1', title: 'new')),
          Todo.fromJson(_todoJson(id: 't1', projectId: 'proj1')),
        ],
      );

      expect(merged.map((t) => t.id), ['p1', 'dup', 't1']);
      expect(merged.firstWhere((t) => t.id == 'dup').title, 'new');
      expect(merged.firstWhere((t) => t.id == 'dup').projectId, 'proj1');
    },
  );

  group('refresh', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test('merges the personal and project(-union) scoped requests', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final scope = req.uri.queryParameters['scope'];
        final items = scope == 'personal'
            ? [_todoJson(id: 'p1')]
            : [
                _todoJson(id: 't1', projectId: 'proj1'),
                _todoJson(id: 't2', projectId: 'proj1'),
              ];
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'items': items}));
        await req.response.close();
      });

      final client = RelayClient('http://127.0.0.1:${server.port}', 'tok');
      final store = TodoStore()..debugSetClient(client);
      await store.refresh();

      expect(store.error, isNull);
      expect(store.all.map((t) => t.id).toSet(), {'p1', 't1', 't2'});
      expect(store.all.firstWhere((t) => t.id == 'p1').isPersonal, isTrue);
      expect(store.all.firstWhere((t) => t.id == 't1').isPersonal, isFalse);
    });

    test('surfaces a request failure via error without touching all', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.statusCode = 500;
        await req.response.close();
      });

      final client = RelayClient('http://127.0.0.1:${server.port}', 'tok');
      final store = TodoStore()..debugSetClient(client);
      await store.refresh();

      expect(store.error, isNotNull);
      expect(store.all, isEmpty);
      expect(store.loading, isFalse);
    });

    test('is a safe no-op before a client is set', () async {
      final store = TodoStore();
      await store.refresh();
      expect(store.all, isEmpty);
      expect(store.loading, isFalse);
    });

    test('stop clears data and detaches the client', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((req) async {
        requests++;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'items': [_todoJson(id: 'p1')],
          }),
        );
        await req.response.close();
      });

      final client = RelayClient('http://127.0.0.1:${server.port}', 'tok');
      final store = TodoStore()..debugSetClient(client);
      await store.refresh();
      expect(store.all.map((t) => t.id), ['p1']);

      await store.stop();
      expect(store.all, isEmpty);
      expect(store.loading, isFalse);
      expect(store.error, isNull);

      await store.refresh();
      expect(requests, 2);
      expect(store.all, isEmpty);
    });

    test('stop ignores an in-flight refresh result', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      var requests = 0;
      server.listen((req) async {
        requests++;
        await release.future;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'items': [_todoJson(id: 'late')],
          }),
        );
        await req.response.close();
      });

      final client = RelayClient('http://127.0.0.1:${server.port}', 'tok');
      final store = TodoStore()..debugSetClient(client);
      final refresh = store.refresh();
      while (requests < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(store.loading, isTrue);

      await store.stop();
      release.complete();
      await refresh;

      expect(store.all, isEmpty);
      expect(store.loading, isFalse);
      expect(store.error, isNull);
    });
  });

  group('SSE upsert', () {
    test('todo.created inserts a new row', () {
      final store = TodoStore();
      store.onSseEvent(
        SseEvent('todo.created', jsonEncode(_todoJson(id: 'x1'))),
      );
      expect(store.all.map((t) => t.id), ['x1']);
    });

    test('todo.updated replaces the existing row in place', () {
      final store = TodoStore();
      store.all = [Todo.fromJson(_todoJson(id: 'x1', status: 'todo'))];
      store.onSseEvent(
        SseEvent(
          'todo.updated',
          jsonEncode(_todoJson(id: 'x1', status: 'in_progress')),
        ),
      );
      expect(store.all.length, 1);
      expect(store.all.single.status, TodoStatus.inProgress);
    });

    test('todo.status_changed upserts by id like todo.updated', () {
      final store = TodoStore();
      store.all = [Todo.fromJson(_todoJson(id: 'x1', status: 'todo'))];
      store.onSseEvent(
        SseEvent(
          'todo.status_changed',
          jsonEncode(_todoJson(id: 'x1', status: 'done')),
        ),
      );
      expect(store.all.single.status, TodoStatus.done);
    });

    test(
      'todo.assigned upserts the assignee fields (status is independent)',
      () {
        final store = TodoStore();
        // Assignee and status are unrelated dimensions (see AssignTodo's doc in
        // internal/relay/store/todos.go) — a todo.assigned event can carry any
        // status at all, not a dedicated "assigned" one.
        final json = _todoJson(
          id: 'x1',
          status: 'in_progress',
          assigneeIdentity: 'bob',
          assigneeDisplayName: 'Bob',
        );
        store.onSseEvent(SseEvent('todo.assigned', jsonEncode(json)));
        expect(store.all.single.assigneeIdentity, 'bob');
        expect(store.all.single.assigneeDisplayName, 'Bob');
        expect(store.all.single.status, TodoStatus.inProgress);
      },
    );

    test('todo.deleted removes the row by id', () {
      final store = TodoStore();
      store.all = [
        Todo.fromJson(_todoJson(id: 'x1')),
        Todo.fromJson(_todoJson(id: 'x2')),
      ];
      store.onSseEvent(SseEvent('todo.deleted', jsonEncode({'id': 'x1'})));
      expect(store.all.map((t) => t.id), ['x2']);
    });

    test('todo.deleted on an unknown id is a safe no-op', () {
      final store = TodoStore();
      store.all = [Todo.fromJson(_todoJson(id: 'x1'))];
      store.onSseEvent(SseEvent('todo.deleted', jsonEncode({'id': 'nope'})));
      expect(store.all.map((t) => t.id), ['x1']);
    });

    test(
      'todo.comment_created upserts the (comment_count-bumped) todo and calls onComment',
      () {
        final store = TodoStore();
        store.all = [Todo.fromJson(_todoJson(id: 'x1'))];
        String? seen;
        store.onComment = (id) => seen = id;
        final json = _todoJson(id: 'x1')..['comment_count'] = 3;
        store.onSseEvent(SseEvent('todo.comment_created', jsonEncode(json)));
        expect(seen, 'x1');
        expect(store.all.single.commentCount, 3);
      },
    );

    test('onComment is a safe no-op when unset', () {
      final store = TodoStore();
      store.all = [Todo.fromJson(_todoJson(id: 'x1'))];
      expect(
        () => store.onSseEvent(
          SseEvent('todo.comment_created', jsonEncode(_todoJson(id: 'x1'))),
        ),
        returnsNormally,
      );
    });

    test('malformed event data is ignored, not thrown', () {
      final store = TodoStore();
      expect(
        () => store.onSseEvent(SseEvent('todo.created', 'not json')),
        returnsNormally,
      );
      expect(store.all, isEmpty);
    });

    test('unknown event types are ignored', () {
      final store = TodoStore();
      store.onSseEvent(
        SseEvent('todo.mystery', jsonEncode(_todoJson(id: 'x1'))),
      );
      expect(store.all, isEmpty);
    });
  });
}
