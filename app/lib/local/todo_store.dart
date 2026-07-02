import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../api/sse.dart';
import '../api/todo_models.dart';
import 'config.dart';

// TodoStore is the in-process source of the merged personal+team todo list for
// the (future) 待办 top-level page. Mirrors SessionOverviewStore's shape: the
// instance exists from HomeShell construction with nothing to do, and start()
// is where real work begins — so _HomeShellState never needs a nullable
// TodoStore field, just a nullable client/me/config it already has.
class TodoStore extends ChangeNotifier {
  // Personal + team todos mixed together — Todo.isPersonal (project_id ==
  // null) is how the UI splits them, not two separate lists.
  List<Todo> all = const [];
  bool loading = false;
  String? error;
  Me? me;

  RelayClient? _client;
  StreamSubscription<SseEvent>? _sse;

  // onComment fires on todo.comment_created so a (future) detail page can
  // reload its comment list — TodoStore itself doesn't model comments.
  void Function(String todoId)? onComment;

  Future<void> start({
    required RelayClient client,
    required Me me,
    required AppConfig config,
  }) async {
    _client = client;
    this.me = me;
    await _sse?.cancel();
    await refresh();
    _sse = subscribeEvents(config.relayUrl, config.token, config.identity)
        .listen(onSseEvent, onError: (_) {});
  }

  // refresh issues the personal + team-union requests concurrently (both
  // futures start before Future.wait is even called, since the list literal
  // evaluates them eagerly) and merges the results into one list.
  Future<void> refresh() async {
    final client = _client;
    if (client == null) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        client.todos(scope: 'personal'),
        client.todos(scope: 'project'),
      ]);
      all = [...results[0], ...results[1]];
    } catch (e) {
      error = '加载待办失败: $e';
    }
    loading = false;
    notifyListeners();
  }

  // onSseEvent is public (not `_on...`) only so tests can drive it directly
  // with hand-built SseEvents instead of a live relay connection — start() is
  // the sole production caller.
  @visibleForTesting
  void onSseEvent(SseEvent ev) {
    Map<String, dynamic> data() {
      try {
        return jsonDecode(ev.data) as Map<String, dynamic>;
      } catch (_) {
        return const {};
      }
    }

    switch (ev.type) {
      case 'todo.created':
      case 'todo.updated':
      case 'todo.status_changed':
      case 'todo.assigned':
      case 'todo.comment_created':
        final d = data();
        if (d.isEmpty) return;
        final t = Todo.fromJson(d);
        if (t.id.isEmpty) return;
        _upsert(t);
        if (ev.type == 'todo.comment_created') onComment?.call(t.id);
      case 'todo.deleted':
        final id = (data()['id'] ?? '').toString();
        if (id.isNotEmpty) _remove(id);
    }
  }

  void _upsert(Todo t) {
    final idx = all.indexWhere((x) => x.id == t.id);
    all = idx == -1 ? [...all, t] : ([...all]..[idx] = t);
    notifyListeners();
  }

  void _remove(String id) {
    if (!all.any((x) => x.id == id)) return;
    all = all.where((x) => x.id != id).toList();
    notifyListeners();
  }

  // debugSetClient lets tests exercise refresh() against a fake/local
  // RelayClient without going through start()'s SSE subscription.
  @visibleForTesting
  void debugSetClient(RelayClient client) => _client = client;

  @override
  void dispose() {
    _sse?.cancel();
    super.dispose();
  }
}
