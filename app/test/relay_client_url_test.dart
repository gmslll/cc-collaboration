import 'dart:convert';
import 'dart:io';

import 'package:app/api/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;

  tearDown(() async {
    await server.close(force: true);
  });

  test('encodes relay path IDs and attachment names', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String>[];
    server.listen((req) async {
      seen.add('${req.method} ${req.uri.path}');
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path ==
              '/v1/handoffs/h%2Fteam%231/attachments/logs%2Fa%20%231.txt' ||
          req.uri.path ==
              '/v1/todos/td%2Fteam%231/attachments/screens%2Fa%20%231.png') {
        req.response.headers.contentType = ContentType.binary;
        req.response.add([1, 2, 3]);
      } else if (req.uri.path == '/v1/orgs/org%2Fteam%231') {
        req.response.write(
          jsonEncode({
            'organization': {
              'id': 'org/team#1',
              'name': 'Team',
              'owner_identity': 'owner@x',
              'role': 'owner',
            },
            'members': <Map<String, dynamic>>[],
            'projects': <Map<String, dynamic>>[],
          }),
        );
      } else if (req.uri.path == '/v1/users/dev%2Fteam%231/reset-password') {
        req.response.write(jsonEncode({'password': 'pw'}));
      } else {
        req.response.write(jsonEncode({'ok': true}));
      }
      await req.response.close();
    });

    final client = RelayClient('http://127.0.0.1:${server.port}', 'tok');

    await client.ack('h/team#1');
    await client.attachment('h/team#1', 'logs/a #1.txt');
    await client.deleteCapsule('cap/team#1');
    await client.patchCapsule('cap/team#1', visibility: 'private');
    await client.deleteTodo('td/team#1');
    await client.uploadTodoAttachment('td/team#1', 'screens/a #1.png', [
      1,
      2,
      3,
    ]);
    await client.todoAttachment('td/team#1', 'screens/a #1.png');
    await client.organization('org/team#1');
    await client.addOrganizationMember('org/team#1', 'dev/team#1', 'member');
    await client.inviteOrganizationMember('org/team#1', 'dev/team#1', 'member');
    await client.cancelOrganizationInvitation('org/team#1', 'inv/team#1');
    await client.removeOrganizationMember('org/team#1', 'dev/team#1');
    await client.deleteOrganization('org/team#1');
    await client.renameProject('proj/team#1', 'Renamed');
    await client.mapRepo('proj/team#1', 'owner/repo');
    await client.unmapRepo('proj/team#1', 'owner/repo');
    await client.addMember('proj/team#1', 'dev/team#1', 'member');
    await client.inviteProjectMember('proj/team#1', 'dev/team#1', 'member');
    await client.cancelProjectInvitation('proj/team#1', 'pinv/team#1');
    await client.acceptInvitation('inv/team#1');
    await client.declineInvitation('dinv/team#1');
    await client.removeMember('proj/team#1', 'dev/team#1');
    await client.deleteProject('proj/team#1');
    await client.deleteToken('tok/team#1');
    await client.setUserAdmin('dev/team#1', true);
    await client.setUserDisabled('dev/team#1', true);
    await client.deleteUser('dev/team#1');
    await client.resetPassword('dev/team#1');

    expect(seen, [
      'POST /v1/handoffs/h%2Fteam%231/ack',
      'GET /v1/handoffs/h%2Fteam%231/attachments/logs%2Fa%20%231.txt',
      'DELETE /v1/capsules/cap%2Fteam%231',
      'PATCH /v1/capsules/cap%2Fteam%231',
      'DELETE /v1/todos/td%2Fteam%231',
      'POST /v1/todos/td%2Fteam%231/attachments/screens%2Fa%20%231.png',
      'GET /v1/todos/td%2Fteam%231/attachments/screens%2Fa%20%231.png',
      'GET /v1/orgs/org%2Fteam%231',
      'POST /v1/orgs/org%2Fteam%231/members',
      'POST /v1/orgs/org%2Fteam%231/invitations',
      'DELETE /v1/orgs/org%2Fteam%231/invitations/inv%2Fteam%231',
      'DELETE /v1/orgs/org%2Fteam%231/members/dev%2Fteam%231',
      'DELETE /v1/orgs/org%2Fteam%231',
      'PATCH /v1/projects/proj%2Fteam%231',
      'POST /v1/projects/proj%2Fteam%231/repos',
      'DELETE /v1/projects/proj%2Fteam%231/repos',
      'POST /v1/projects/proj%2Fteam%231/members',
      'POST /v1/projects/proj%2Fteam%231/invitations',
      'DELETE /v1/projects/proj%2Fteam%231/invitations/pinv%2Fteam%231',
      'POST /v1/invitations/inv%2Fteam%231/accept',
      'POST /v1/invitations/dinv%2Fteam%231/decline',
      'DELETE /v1/projects/proj%2Fteam%231/members/dev%2Fteam%231',
      'DELETE /v1/projects/proj%2Fteam%231',
      'DELETE /v1/tokens/tok%2Fteam%231',
      'POST /v1/users/dev%2Fteam%231/admin',
      'POST /v1/users/dev%2Fteam%231/disable',
      'DELETE /v1/users/dev%2Fteam%231',
      'POST /v1/users/dev%2Fteam%231/reset-password',
    ]);
  });

  test('sendMessage includes project context for scoped injection', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Map<String, dynamic>? body;
    server.listen((req) async {
      body =
          jsonDecode(await utf8.decoder.bind(req).join())
              as Map<String, dynamic>;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'ok': true}));
      await req.response.close();
    });

    final client = RelayClient('http://127.0.0.1:${server.port}', 'tok');
    await client.sendMessage(
      'dev@x',
      'ts1',
      'hello',
      project: 'Backend',
      projectId: 'project-1',
    );

    expect(body, {
      'recipient': 'dev@x',
      'session_id': 'ts1',
      'body': 'hello',
      'project': 'Backend',
      'project_id': 'project-1',
    });
  });

  test('normalizes todo team fields before sending requests', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <Map<String, dynamic>>[];
    server.listen((req) async {
      Map<String, dynamic> body = const {};
      if (req.method != 'GET') {
        final raw = await utf8.decoder.bind(req).join();
        body = raw.isEmpty ? const {} : jsonDecode(raw) as Map<String, dynamic>;
      }
      seen.add({
        'method': req.method,
        'path': req.uri.path,
        'query': req.uri.queryParameters,
        'body': body,
      });
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/v1/todos' && req.method == 'GET') {
        req.response.write(jsonEncode({'items': []}));
      } else if (req.uri.path == '/v1/todos/groups') {
        req.response.write(jsonEncode({'groups': []}));
      } else if (req.uri.path.contains('/groups/')) {
        req.response.write(jsonEncode({'ok': true}));
      } else {
        req.response.write(jsonEncode(_todoResponse()));
      }
      await req.response.close();
    });

    final client = RelayClient('http://127.0.0.1:${server.port}', 'tok');
    await client.todos(
      scope: ' project ',
      project: ' project-1 ',
      status: ' in_review ',
      group: ' Sprint ',
    );
    await client.createTodo(
      title: '  keep title padding  ',
      bodyMd: '  keep body padding  ',
      priority: ' high ',
      projectId: ' project-1 ',
      recurrence: ' weekly ',
      workspaceName: ' Workspace ',
      repoName: ' Repo ',
      groupName: ' Sprint ',
    );
    await client.updateTodo(
      'td1',
      priority: ' low ',
      recurrence: ' ',
      workspaceName: ' ',
      repoName: ' Repo ',
      groupName: ' Sprint ',
    );
    await client.todoGroups(projectId: ' project-1 ');
    await client.renameTodoGroup(' Old ', ' New ', projectId: ' project-1 ');
    await client.clearTodoGroup(' Old ', projectId: ' project-1 ');
    await client.assignTodo(
      'td1',
      assigneeIdentity: ' dev@x ',
      assigneeSessionId: ' ts1 ',
      assigneeSessionLabel: ' codex ',
      assigneeAgentSessionId: ' agent-1 ',
      assigneeWorkdir: ' /tmp/repo ',
      assigneeAgentKind: ' codex ',
    );
    await client.assignTodo(
      'td1',
      assigneeIdentity: '   ',
      assigneeSessionId: ' ts1 ',
      assigneeSessionLabel: ' codex ',
      assigneeAgentSessionId: ' agent-1 ',
      assigneeWorkdir: ' /tmp/repo ',
      assigneeAgentKind: ' codex ',
    );

    expect(seen[0]['query'], {
      'scope': 'project',
      'project': 'project-1',
      'status': 'in_review',
      'group': 'Sprint',
    });
    expect(seen[1]['body'], {
      'title': '  keep title padding  ',
      'body_md': '  keep body padding  ',
      'priority': 'high',
      'project_id': 'project-1',
      'recurrence': 'weekly',
      'workspace_name': 'Workspace',
      'repo_name': 'Repo',
      'group_name': 'Sprint',
    });
    expect(seen[2]['body'], {
      'priority': 'low',
      'recurrence': '',
      'workspace_name': '',
      'repo_name': 'Repo',
      'group_name': 'Sprint',
    });
    expect(seen[3]['query'], {'project': 'project-1'});
    expect(seen[4]['body'], {
      'project_id': 'project-1',
      'old_name': 'Old',
      'new_name': 'New',
    });
    expect(seen[5]['body'], {'project_id': 'project-1', 'name': 'Old'});
    expect(seen[6]['body'], {
      'assignee_identity': 'dev@x',
      'assignee_session_id': 'ts1',
      'assignee_session_label': 'codex',
      'assignee_agent_session_id': 'agent-1',
      'assignee_workdir': '/tmp/repo',
      'assignee_agent_kind': 'codex',
    });
    expect(seen[7]['body'], {'assignee_identity': ''});
  });

  test('auth trims identity but preserves password bytes', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Map<String, dynamic>? body;
    server.listen((req) async {
      expect(req.uri.path, '/v1/register');
      body =
          jsonDecode(await utf8.decoder.bind(req).join())
              as Map<String, dynamic>;
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({'token': 'tok', 'identity': body?['identity']}),
      );
      await req.response.close();
    });

    final result = await register(
      'http://127.0.0.1:${server.port}',
      ' dev@x ',
      '  password  ',
    );

    expect(result.identity, 'dev@x');
    expect(body, {'identity': 'dev@x', 'password': '  password  '});
  });

  test('auth fallback identity uses the trimmed request identity', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'token': 'tok'}));
      await req.response.close();
    });

    final result = await login(
      'http://127.0.0.1:${server.port}',
      ' dev@x ',
      'password',
    );

    expect(result.identity, 'dev@x');
  });
}

Map<String, dynamic> _todoResponse() => {
  'id': 'td1',
  'project_id': 'project-1',
  'owner_identity': 'owner@x',
  'title': 'todo',
  'body_md': '',
  'status': 'todo',
  'priority': 'normal',
  'assignee_identity': null,
  'assignee_display_name': null,
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
