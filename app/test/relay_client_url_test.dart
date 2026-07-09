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
    await client.removeOrganizationMember('org/team#1', 'dev/team#1');
    await client.renameProject('proj/team#1', 'Renamed');
    await client.mapRepo('proj/team#1', 'owner/repo');
    await client.unmapRepo('proj/team#1', 'owner/repo');
    await client.addMember('proj/team#1', 'dev/team#1', 'member');
    await client.removeMember('proj/team#1', 'dev/team#1');
    await client.deleteProject('proj/team#1');
    await client.deleteToken('tok/team#1');
    await client.setUserAdmin('dev/team#1', true);
    await client.setUserDisabled('dev/team#1', true);
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
      'DELETE /v1/orgs/org%2Fteam%231/members/dev%2Fteam%231',
      'PATCH /v1/projects/proj%2Fteam%231',
      'POST /v1/projects/proj%2Fteam%231/repos',
      'DELETE /v1/projects/proj%2Fteam%231/repos',
      'POST /v1/projects/proj%2Fteam%231/members',
      'DELETE /v1/projects/proj%2Fteam%231/members/dev%2Fteam%231',
      'DELETE /v1/projects/proj%2Fteam%231',
      'DELETE /v1/tokens/tok%2Fteam%231',
      'POST /v1/users/dev%2Fteam%231/admin',
      'POST /v1/users/dev%2Fteam%231/disable',
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
}
