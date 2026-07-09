import 'package:app/remote/remote_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestRemoteClient extends RemoteClient {
  _TestRemoteClient() : super(relayUrl: 'http://relay.test', token: 'token');

  final sent = <Map<String, dynamic>>[];

  @override
  void send(Map<String, dynamic> frame) {
    sent.add(Map<String, dynamic>.from(frame));
  }

  void markHostOnline() {
    onFrame({'t': 'sessions', 'items': const []});
  }
}

void main() {
  test('remote git create branch includes optional start ref', () {
    final client = _TestRemoteClient();
    addTearDown(client.dispose);

    client.gitCreateBranch('/repo', 'feat/team', start: ' origin/main ');

    expect(client.sent, [
      {
        't': 'git.createBranch',
        'path': '/repo',
        'branch': 'feat/team',
        'start': 'origin/main',
      },
    ]);
  });

  test('remote git create branch omits blank start ref', () {
    final client = _TestRemoteClient();
    addTearDown(client.dispose);

    client.gitCreateBranch('/repo', 'feat/team', start: '   ');

    expect(client.sent, [
      {'t': 'git.createBranch', 'path': '/repo', 'branch': 'feat/team'},
    ]);
  });

  test('remote config commands trim fields before sending frames', () {
    final client = _TestRemoteClient();
    addTearDown(client.dispose);

    client.newWorkspace(' Mobile ', ' /tmp/mobile ');
    client.removeWorkspace(' Mobile ');
    client.addProject(' Team ', ' https://github.com/org/repo.git ');
    client.removeProject(' Team ', ' Backend ');
    client.addWorktree(' Team ', ' Backend ', ' feat/team ', ' origin/main ');
    client.removeWorktree(' Team ', ' Backend ', ' feat/team ');

    expect(client.sent, [
      {'t': 'ws.new', 'name': 'Mobile', 'path': '/tmp/mobile'},
      {'t': 'ws.remove', 'name': 'Mobile'},
      {
        't': 'proj.add',
        'workspace': 'Team',
        'source': 'https://github.com/org/repo.git',
      },
      {'t': 'proj.remove', 'workspace': 'Team', 'project': 'Backend'},
      {
        't': 'wt.add',
        'workspace': 'Team',
        'project': 'Backend',
        'branch': 'feat/team',
        'start': 'origin/main',
      },
      {
        't': 'wt.remove',
        'workspace': 'Team',
        'project': 'Backend',
        'branch': 'feat/team',
        'force': true,
      },
    ]);
  });

  test('remote config commands preserve default workspace and omit blanks', () {
    final client = _TestRemoteClient();
    addTearDown(client.dispose);

    client.newWorkspace(' Mobile ', '   ');
    client.addProject('', ' /repo ');
    client.addWorktree('', ' Backend ', ' feat/team ', '   ');

    expect(client.sent, [
      {'t': 'ws.new', 'name': 'Mobile'},
      {'t': 'proj.add', 'workspace': '', 'source': '/repo'},
      {
        't': 'wt.add',
        'workspace': '',
        'project': 'Backend',
        'branch': 'feat/team',
      },
    ]);
  });

  testWidgets('remote assign fails immediately when the host is offline', (
    tester,
  ) async {
    final client = _TestRemoteClient();
    addTearDown(client.dispose);

    final result = await client.requestAssign(
      todoId: 'todo-1',
      mode: 'existing',
      sid: 'session-1',
    );

    expect(result, '电脑端未在线，请先在电脑端开启「共享工作区」');
    expect(client.sent, isEmpty);
  });

  testWidgets('remote assign supersede cancels the older timeout', (
    tester,
  ) async {
    final client = _TestRemoteClient()..markHostOnline();
    addTearDown(client.dispose);

    final first = client.requestAssign(
      todoId: 'todo-1',
      mode: 'existing',
      sid: 'old-session',
    );
    await tester.pump(const Duration(seconds: 5));
    final second = client.requestAssign(
      todoId: 'todo-1',
      mode: 'existing',
      sid: 'new-session',
    );

    expect(await first, '已被新的指派请求取代');
    var secondDone = false;
    String? secondResult = 'pending';
    second.then((value) {
      secondDone = true;
      secondResult = value;
    });

    await tester.pump(const Duration(seconds: 26));

    expect(secondDone, isFalse);

    client.onFrame({'t': 'todo.assign.ok', 'todoId': 'todo-1'});
    await tester.pump();

    expect(secondDone, isTrue);
    expect(secondResult, isNull);
    expect(client.sent, [
      {
        't': 'todo.assign',
        'todoId': 'todo-1',
        'mode': 'existing',
        'sid': 'old-session',
      },
      {
        't': 'todo.assign',
        'todoId': 'todo-1',
        'mode': 'existing',
        'sid': 'new-session',
      },
    ]);
  });

  testWidgets('remote assign sends relay project id for team scope', (
    tester,
  ) async {
    final client = _TestRemoteClient()..markHostOnline();
    addTearDown(client.dispose);

    final result = client.requestAssign(
      todoId: ' todo-1 ',
      mode: ' new ',
      sid: ' ',
      workspace: ' Team ',
      project: ' Backend ',
      projectId: ' relay-project ',
      kind: ' claude ',
      branch: ' feat/team ',
    );
    await tester.pump();

    expect(client.sent.single, {
      't': 'todo.assign',
      'todoId': 'todo-1',
      'mode': 'new',
      'workspace': 'Team',
      'project': 'Backend',
      'projectId': 'relay-project',
      'kind': 'claude',
      'branch': 'feat/team',
    });
    client.onFrame({'t': 'todo.assign.ok', 'todoId': 'todo-1'});
    await tester.pump();
    expect(await result, isNull);
  });

  testWidgets('remote assign completes when the client is disposed', (
    tester,
  ) async {
    final client = _TestRemoteClient()..markHostOnline();

    final result = client.requestAssign(
      todoId: 'todo-1',
      mode: 'existing',
      sid: 'session-1',
    );
    client.dispose();

    expect(await result, '连接已关闭');
    await tester.pump(const Duration(seconds: 31));
  });
}
