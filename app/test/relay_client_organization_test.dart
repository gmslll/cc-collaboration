import 'dart:convert';
import 'dart:io';

import 'package:app/api/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;

  tearDown(() async {
    await server.close(force: true);
  });

  test('loads organization detail with member candidates', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      expect(req.uri.path, '/v1/orgs/org1');
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'organization': {
            'id': 'org1',
            'name': 'Kunlun',
            'owner_identity': 'owner@x',
            'role': 'admin',
          },
          'members': [
            {'identity': 'dev@x', 'role': 'member', 'display_name': 'Dev'},
            {'identity': 'ops@x', 'role': 'admin'},
          ],
          'projects': [
            {
              'id': 'p1',
              'org_id': 'org1',
              'name': 'Backend',
              'owner_identity': 'owner@x',
              'role': 'admin',
            },
          ],
        }),
      );
      await req.response.close();
    });

    final client = RelayClient('http://127.0.0.1:${server.port}', 'tok');
    final org = await client.organization('org1');

    expect(org.organization.name, 'Kunlun');
    expect(org.members.map((m) => m.identity), ['dev@x', 'ops@x']);
    expect(org.members.first.displayName, 'Dev');
    expect(org.members.last.displayName, '');
    expect(org.projects.single.name, 'Backend');
  });
}
