import 'dart:convert';
import 'dart:io';

import 'package:app/api/models.dart';
import 'package:app/api/relay_client.dart';
import 'package:app/screens/projects_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'project repo model reads new bindings and legacy name-only responses',
    () {
      final current = ProjectDetail.fromJson({
        'project': {'id': 'p1', 'name': 'Backend'},
        'repos': ['backend'],
        'repo_bindings': [
          {
            'repo_name': 'backend',
            'clone_url': 'https://github.com/acme/backend.git',
          },
        ],
      });
      expect(current.repos, ['backend']);
      expect(current.repoBindings.single.repoName, 'backend');
      expect(current.cloneableRepos.single.cloneUrl, contains('github.com'));

      final legacy = ProjectDetail.fromJson({
        'project': {'id': 'p-old', 'name': 'Legacy'},
        'repos': [' legacy-repo '],
      });
      expect(legacy.repos, ['legacy-repo']);
      expect(legacy.repoBindings.single.cloneUrl, isEmpty);
      expect(legacy.cloneableRepos, isEmpty);
    },
  );

  test('GitHub URL preview derives a stable repository name', () {
    expect(
      githubRepoNameFromCloneUrl('https://github.com/acme/widget.git'),
      'widget',
    );
    expect(
      githubRepoNameFromCloneUrl('git@github.com:acme/widget.git'),
      'widget',
    );
    expect(githubRepoNameFromCloneUrl('file:///tmp/widget'), isNull);
    expect(
      githubRepoNameFromCloneUrl('https://gitlab.com/acme/widget'),
      isNull,
    );
    expect(githubRepoNameFromCloneUrl('https://github.com/acme/a/b'), isNull);
    expect(
      githubRepoNameFromCloneUrl('https://token@github.com/acme/widget.git'),
      isNull,
    );
    expect(
      githubRepoNameFromCloneUrl('https://github.com/acme/widget.git?token=x'),
      isNull,
    );
    expect(
      githubRepoNameFromCloneUrl('ssh://root@github.com/acme/widget.git'),
      isNull,
    );
    expect(
      githubRepoNameFromCloneUrl('ssh://git@github.com:22/acme/widget.git'),
      isNull,
    );
  });

  test(
    'relay client writes clone URL and lists only cloneable projects',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      Map<String, dynamic>? posted;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.method == 'POST' &&
            request.uri.path == '/v1/projects/p1/repos') {
          posted =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
          request.response.write(
            jsonEncode({
              'repo': {
                'repo_name': 'backend',
                'clone_url': 'https://github.com/acme/backend.git',
              },
            }),
          );
        } else if (request.uri.path == '/v1/projects') {
          request.response.write(
            jsonEncode({
              'projects': [
                {'id': 'p1', 'name': 'Backend'},
                {'id': 'p2', 'name': 'Legacy'},
              ],
            }),
          );
        } else if (request.uri.path == '/v1/projects/p1') {
          request.response.write(
            jsonEncode({
              'project': {'id': 'p1', 'name': 'Backend'},
              'repo_bindings': [
                {
                  'repo_name': 'backend',
                  'clone_url': 'https://github.com/acme/backend.git',
                },
              ],
            }),
          );
        } else if (request.uri.path == '/v1/projects/p2') {
          request.response.write(
            jsonEncode({
              'project': {'id': 'p2', 'name': 'Legacy'},
              'repos': ['legacy'],
            }),
          );
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      final client = RelayClient('http://127.0.0.1:${server.port}', 'tok');
      final binding = await client.upsertProjectRepo(
        ' p1 ',
        ' backend ',
        ' https://github.com/acme/backend.git ',
      );
      expect(binding.repoName, 'backend');
      expect(posted, {
        'repo_name': 'backend',
        'clone_url': 'https://github.com/acme/backend.git',
      });

      final projects = await client.cloneableProjectDetails();
      expect(projects.map((detail) => detail.project.id), ['p1']);
    },
  );
}
