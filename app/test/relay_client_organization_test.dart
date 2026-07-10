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
          'invitations': [
            {
              'id': 'inv1',
              'scope': 'org',
              'org_id': 'org1',
              'org_name': 'Kunlun',
              'identity': 'new@x',
              'role': 'member',
              'inviter_identity': 'owner@x',
              'created_at': '2026-07-10T00:00:00Z',
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
    expect(org.invitations.single.identity, 'new@x');
    expect(org.invitations.single.orgName, 'Kunlun');
  });

  test('updates organization members', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String>[];
    server.listen((req) async {
      seen.add('${req.method} ${req.uri.path}');
      req.response.headers.contentType = ContentType.json;
      if (req.method == 'POST') {
        expect(req.uri.path, '/v1/orgs/org1/members');
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        expect(body, {'identity': 'dev@x', 'role': 'admin'});
      } else {
        expect(req.method, 'DELETE');
        expect(req.uri.path, '/v1/orgs/org1/members/dev%40x');
      }
      req.response.write(jsonEncode({'ok': true}));
      await req.response.close();
    });

    final client = RelayClient('http://127.0.0.1:${server.port}', 'tok');
    await client.addOrganizationMember('org1', 'dev@x', 'admin');
    await client.removeOrganizationMember('org1', 'dev@x');

    expect(seen, [
      'POST /v1/orgs/org1/members',
      'DELETE /v1/orgs/org1/members/dev%40x',
    ]);
  });

  test('normalizes organization and project management fields', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <Map<String, dynamic>>[];
    server.listen((req) async {
      Map<String, dynamic> body = const {};
      if (req.method != 'GET' && req.method != 'DELETE') {
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
      if (req.uri.path == '/v1/orgs' && req.method == 'POST') {
        req.response.write(
          jsonEncode({
            'id': 'org1',
            'name': 'Kunlun',
            'owner_identity': 'owner@x',
            'role': 'owner',
          }),
        );
      } else if (req.uri.path == '/v1/projects' && req.method == 'POST') {
        req.response.write(
          jsonEncode({
            'id': 'p1',
            'org_id': 'org1',
            'name': 'Backend',
            'owner_identity': 'owner@x',
            'role': 'owner',
          }),
        );
      } else {
        req.response.write(jsonEncode({'ok': true}));
      }
      await req.response.close();
    });

    final client = RelayClient('http://127.0.0.1:${server.port}', 'tok');
    await client.createOrganization(' Kunlun ');
    await client.addOrganizationMember(' org1 ', ' dev@x ', ' admin ');
    await client.inviteOrganizationMember(' org1 ', ' invite@x ', ' member ');
    await client.cancelOrganizationInvitation(' org1 ', ' inv1 ');
    await client.removeOrganizationMember(' org1 ', ' dev@x ');
    await client.createProject(' Backend ', orgId: ' org1 ');
    await client.renameProject(' p1 ', ' Backend API ');
    await client.mapRepo(' p1 ', ' owner/repo ');
    await client.unmapRepo(' p1 ', ' owner/repo ');
    await client.addMember(' p1 ', ' dev@x ', ' member ');
    await client.inviteProjectMember(' p1 ', ' project-invite@x ', ' viewer ');
    await client.cancelProjectInvitation(' p1 ', ' pinv1 ');
    await client.acceptInvitation(' inv-accept ');
    await client.declineInvitation(' inv-decline ');
    await client.removeMember(' p1 ', ' dev@x ');

    expect(seen[0]['body'], {'name': 'Kunlun'});
    expect(seen[1], {
      'method': 'POST',
      'path': '/v1/orgs/org1/members',
      'query': <String, String>{},
      'body': {'identity': 'dev@x', 'role': 'admin'},
    });
    expect(seen[2], {
      'method': 'POST',
      'path': '/v1/orgs/org1/invitations',
      'query': <String, String>{},
      'body': {'identity': 'invite@x', 'role': 'member'},
    });
    expect(seen[3]['path'], '/v1/orgs/org1/invitations/inv1');
    expect(seen[4]['path'], '/v1/orgs/org1/members/dev%40x');
    expect(seen[5]['body'], {'name': 'Backend', 'org_id': 'org1'});
    expect(seen[6], {
      'method': 'PATCH',
      'path': '/v1/projects/p1',
      'query': <String, String>{},
      'body': {'name': 'Backend API'},
    });
    expect(seen[7]['body'], {'repo_name': 'owner/repo'});
    expect(seen[8]['query'], {'repo_name': 'owner/repo'});
    expect(seen[9], {
      'method': 'POST',
      'path': '/v1/projects/p1/members',
      'query': <String, String>{},
      'body': {'identity': 'dev@x', 'role': 'member'},
    });
    expect(seen[10], {
      'method': 'POST',
      'path': '/v1/projects/p1/invitations',
      'query': <String, String>{},
      'body': {'identity': 'project-invite@x', 'role': 'viewer'},
    });
    expect(seen[11]['path'], '/v1/projects/p1/invitations/pinv1');
    expect(seen[12]['path'], '/v1/invitations/inv-accept/accept');
    expect(seen[13]['path'], '/v1/invitations/inv-decline/decline');
    expect(seen[14]['path'], '/v1/projects/p1/members/dev%40x');
  });
}
