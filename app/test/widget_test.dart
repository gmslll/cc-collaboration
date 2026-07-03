import 'dart:io';

import 'package:app/api/github_client.dart';
import 'package:app/api/models.dart';
import 'package:app/local/diff_parse.dart';
import 'package:app/local/repo_config.dart';
import 'package:app/widgets.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _sampleDiff = '''
diff --git a/lib/a.dart b/lib/a.dart
index 1111111..2222222 100644
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -1,3 +1,3 @@
 context1
-old line
+new line
 context2
diff --git a/lib/new.dart b/lib/new.dart
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/lib/new.dart
@@ -0,0 +1,2 @@
+added1
+added2
''';

void main() {
  group('splitFileNameDir', () {
    test('splits POSIX paths', () {
      expect(splitFileNameDir('/tmp/project/lib/main.dart'), (
        'main.dart',
        '/tmp/project/lib',
      ));
    });

    test('splits Windows paths', () {
      expect(splitFileNameDir(r'E:\demoFile\oppr\package.json'), (
        'package.json',
        r'E:\demoFile\oppr',
      ));
    });

    test('uses the last separator when paths are mixed', () {
      expect(splitFileNameDir(r'E:\demoFile\oppr/src/main.dart'), (
        'main.dart',
        r'E:\demoFile\oppr/src',
      ));
    });
  });

  test('parseUnifiedDiff splits files + counts; parseRows aligns', () {
    final files = parseUnifiedDiff(_sampleDiff);
    expect(files.length, 2);
    expect(files[0].path, 'lib/a.dart');
    expect(files[0].status, 'modified');
    expect(files[0].adds, 1);
    expect(files[0].dels, 1);
    expect(files[1].path, 'lib/new.dart');
    expect(files[1].status, 'added');

    final rows = parseRows(files[0].raw).where((r) => !r.isHunk).toList();
    // context1 | (old↔new paired) | context2
    expect(rows.length, 3);
    expect(rows[0].leftKind, DiffKind.context);
    expect(rows[1].leftKind, DiffKind.removed);
    expect(rows[1].rightKind, DiffKind.added);
    expect(rows[1].left, 'old line');
    expect(rows[1].right, 'new line');

    final added = parseRows(files[1].raw).where((r) => !r.isHunk).toList();
    expect(added.length, 2);
    expect(added[0].leftKind, DiffKind.empty); // new file → left blank
    expect(added[0].rightKind, DiffKind.added);
  });

  test('splitHunks separates header + hunks; hunk rows are numbered', () {
    final files = parseUnifiedDiff(_sampleDiff);
    final (header, hunks) = splitHunks(files[0].raw);
    expect(header.contains('diff --git a/lib/a.dart b/lib/a.dart'), isTrue);
    expect(header.contains('+++ b/lib/a.dart'), isTrue);
    expect(hunks.length, 1);
    expect(hunks[0].startsWith('@@'), isTrue);
    expect(hunks[0].contains('-old line'), isTrue);
    expect(hunks[0].contains('+new line'), isTrue);

    final hunkRows = parseRows(files[0].raw).where((r) => r.isHunk).toList();
    expect(hunkRows.length, 1);
    expect(hunkRows.first.hunkIndex, 0);
  });

  test('GitHubClient.parseSlug handles https / git@ / path / non-github', () {
    expect(
      GitHubClient.parseSlug('https://github.com/owner/repo.git'),
      'owner/repo',
    );
    expect(
      GitHubClient.parseSlug('https://github.com/owner/repo'),
      'owner/repo',
    );
    expect(
      GitHubClient.parseSlug('git@github.com:owner/repo.git'),
      'owner/repo',
    );
    expect(
      GitHubClient.parseSlug('https://github.com/owner/repo/pull/5'),
      'owner/repo',
    );
    expect(GitHubClient.parseSlug('/just/a/local/path'), isNull);
    expect(GitHubClient.parseSlug(''), isNull);
  });

  test('ListItem.fromJson parses fields + defaults kind', () {
    final it = ListItem.fromJson({
      'id': 'h1',
      'sender': 'a@x',
      'urgency': 'urgent',
      'state': 'pending',
      'repo_name': 'repo',
      'headline': 'hi',
      'created_at': '2026-01-01T00:00:00Z',
    });
    expect(it.id, 'h1');
    expect(it.sender, 'a@x');
    expect(it.urgency, 'urgent');
    expect(it.kind, 'delivery'); // omitted → default
    expect(it.repoName, 'repo');
  });

  test('Package.fromJson parses nested api_delta / git / attachments', () {
    final p = Package.fromJson({
      'id': 'h1',
      'sender': 'a',
      'recipient': 'b',
      'summary_md': '# hi',
      'repo': {'name': 'r', 'branch': 'main'},
      'module_paths': ['a/b'],
      'attachments': [
        {'name': 'f.txt', 'size': 12, 'sha256': 'x'},
      ],
      'git': {
        'commits': [
          {'sha': 'abc', 'subject': 's'},
        ],
        'changed_paths': ['x.go'],
      },
      'api_delta': {
        'added': [
          {'method': 'GET', 'path': '/v1/x', 'summary': 'sum'},
        ],
      },
    });
    expect(p.repo.name, 'r');
    expect(p.modulePaths, ['a/b']);
    expect(p.attachments.single.name, 'f.txt');
    expect(p.attachments.single.size, 12);
    expect(p.git!.commits.single.sha, 'abc');
    expect(p.git!.changedPaths, ['x.go']);
    expect(p.apiDelta!.added.single.method, 'GET');
    expect(p.apiDelta!.isEmpty, isFalse);
  });

  test('Me.fromJson + ProjectRole', () {
    final me = Me.fromJson({
      'identity': 'a',
      'is_admin': true,
      'projects': [
        {'id': 'p1', 'name': 'P', 'role': 'owner'},
      ],
    });
    expect(me.isAdmin, isTrue);
    expect(me.projects.single.role, 'owner');
  });

  test('Status.fromJson handles null picked_at', () {
    final s = Status.fromJson({
      'state': 'pending',
      'comment_count': 3,
      'created_at': '2026-01-01T00:00:00Z',
    });
    expect(s.state, 'pending');
    expect(s.pickedAt, isNull);
    expect(s.commentCount, 3);
  });

  test('errorText maps DioException to friendly text', () {
    final timeout = DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.connectionTimeout,
    );
    expect(errorText(timeout), contains('超时'));

    final forbidden = DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: '/'),
        statusCode: 403,
      ),
    );
    expect(errorText(forbidden), contains('权限'));

    expect(errorText('boom'), 'boom');
  });

  test('RepoConfig save→load round-trips (.cc-handoff.toml)', () async {
    final dir = await Directory.systemTemp.createTemp('repocfg');
    try {
      final c = RepoConfig(
        raw: const {
          'integrations': {
            'other': {'enabled': true}
          }
        },
        partner: 'alex@frontend',
        partners: 'a@x, b@y',
        base: 'origin/main',
        autoLaunch: true,
        terminalApp: 'iterm2',
        linearEnabled: true,
        teamKey: 'ENG',
        linearProjectId: 'proj-123',
        types: 'mention',
        rules: [
          RuleCfg(
            whenPathMatches: '^x/',
            suggestEdit: 'a.ts, b.ts',
            suggestCreate: true,
          ),
        ],
      );
      await c.save(dir.path);
      final back = await RepoConfig.load(dir.path);
      expect(back.partner, 'alex@frontend');
      expect(back.partners, 'a@x, b@y');
      expect(back.base, 'origin/main');
      expect(back.autoLaunch, isTrue);
      expect(back.terminalApp, 'iterm2');
      expect(back.linearEnabled, isTrue);
      expect(back.teamKey, 'ENG');
      expect(back.linearProjectId, 'proj-123');
      expect(back.types, 'mention');
      expect((back.raw['integrations'] as Map?)?['other'], isNotNull);
      expect(back.rules.length, 1);
      expect(back.rules.first.whenPathMatches, '^x/');
      expect(back.rules.first.suggestCreate, isTrue);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
