import 'dart:io';

import 'package:app/api/github_client.dart';
import 'package:app/api/models.dart';
import 'package:app/local/diff_parse.dart';
import 'package:app/local/remote_prefs.dart';
import 'package:app/local/repo_config.dart';
import 'package:app/voice/stt.dart';
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
  test('account page does not expose internal build markers', () {
    final source = File('lib/screens/account_page.dart').readAsStringSync();

    expect(source, isNot(contains('kBuildMarker')));
    expect(source, isNot(contains('构建 \$kBuildMarker')));
  });

  test('remote session content previews default to hidden', () {
    expect(kRemoteShowSessionContentDefault, isFalse);

    final account = File('lib/screens/account_page.dart').readAsStringSync();
    final remote = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();
    expect(account, contains('def: kRemoteShowSessionContentDefault'));
    expect(remote, contains('def: kRemoteShowSessionContentDefault'));
    expect(
      account,
      isNot(contains('kRemoteShowSessionContentPref,\n    def: true')),
    );
    expect(
      remote,
      isNot(contains('kRemoteShowSessionContentPref,\n          def: true')),
    );
  });

  test('remote new-session dropdown labels are width constrained', () {
    final remote = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();

    expect(remote, contains('overflow: TextOverflow.ellipsis'));
    expect(
      remote,
      isNot(contains('DropdownMenuItem(value: r, child: Text(r.name))')),
    );
    expect(remote, contains("'主仓 (\${project.name})'"));
    expect(
      remote,
      contains('w.branch.isEmpty ? pathBaseName(w.path) : w.branch'),
    );
  });

  test('remote project list titles are width constrained', () {
    final remote = File(
      'lib/screens/remote_workspace_page.dart',
    ).readAsStringSync();

    expect(remote, isNot(contains('title: Text(r.name),')));
    expect(remote, contains('maxLines: 1'));
    expect(remote, contains('overflow: TextOverflow.ellipsis'));
  });

  test('workspace session rows paint selected backgrounds on Material', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final sessionMenu = source.substring(source.indexOf('final sessionMenu ='));
    final tileBlock = sessionMenu.substring(
      sessionMenu.indexOf('return _ctxMenu('),
      sessionMenu.indexOf('sessionMenu,'),
    );

    expect(tileBlock, contains('Material('));
    expect(tileBlock, contains('CcColors.accent.withValues(alpha: 0.08)'));
    expect(
      tileBlock,
      isNot(
        contains('decoration: BoxDecoration(\n              color: active'),
      ),
    );
  });

  test('workspace name dialog uses owned controller widget', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final dialog = source.substring(
      source.indexOf('Future<String?> _nameDialog('),
      source.indexOf('void _refreshFileTrees'),
    );

    expect(dialog, contains('showDialog<String>'));
    expect(dialog, contains('FileNameDialog('));
    expect(dialog, isNot(contains('TextEditingController')));
    expect(dialog, isNot(contains('showDialog<bool>')));
  });

  test('workspace fields dialog owns generated controllers', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final helper = source.substring(
      source.indexOf('Future<List<String>?> _fieldsDialog('),
      source.indexOf('@override\n  Future<bool> _confirm'),
    );

    expect(helper, contains('showDialog<List<String>>'));
    expect(helper, contains('WorkspaceFieldsDialog('));
    expect(helper, isNot(contains('TextEditingController')));
    expect(helper, isNot(contains('showDialog<bool>')));
  });

  test('workspace session rename uses owned controller widget', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    final helper = source.substring(
      source.indexOf('Future<void> _renameSession('),
      source.indexOf('List<Widget> _worktreeNodes'),
    );

    expect(helper, contains('showDialog<String>'));
    expect(helper, contains('WorkspaceSessionRenameDialog('));
    expect(helper, isNot(contains('TextEditingController')));
    expect(helper, isNot(contains('showDialog<bool>')));
  });

  test('speech recognizer debug logging is off by default', () {
    expect(kSpeechDebugLogging, isFalse);
  });

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
      'delivery_target': {
        'project_id': ' project-1 ',
        'org_id': 'org-1',
        'member': ' dev@team ',
      },
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
    expect(p.deliveryTarget?.projectId, 'project-1');
    expect(p.deliveryTarget?.orgId, 'org-1');
    expect(p.deliveryTarget?.member, 'dev@team');
    expect(
      deliveryTargetLabel(p.deliveryTarget!),
      '项目 project-1 · 团队 org-1 · 成员 dev@team',
    );
    expect(p.modulePaths, ['a/b']);
    expect(p.attachments.single.name, 'f.txt');
    expect(p.attachments.single.size, 12);
    expect(p.git!.commits.single.sha, 'abc');
    expect(p.git!.changedPaths, ['x.go']);
    expect(p.apiDelta!.added.single.method, 'GET');
    expect(p.apiDelta!.isEmpty, isFalse);
  });

  test('Package.fromJson ignores blank delivery_target', () {
    final p = Package.fromJson({
      'id': 'h_blank_target',
      'sender': 'a',
      'recipient': 'b',
      'repo': {'name': 'r'},
      'delivery_target': {'project_id': ' ', 'org_id': '', 'member': null},
    });
    expect(p.deliveryTarget, isNull);
  });

  test('Me.fromJson + ProjectRole', () {
    final me = Me.fromJson({
      'identity': 'a',
      'is_admin': true,
      'organizations': [
        {'id': 'o1', 'name': 'Org', 'role': 'admin'},
      ],
      'projects': [
        {'id': 'p1', 'name': 'P', 'role': 'owner'},
      ],
    });
    expect(me.isAdmin, isTrue);
    expect(me.organizations.single.role, 'admin');
    expect(me.projects.single.role, 'owner');
  });

  test('Organization.fromJson carries fresh caller role', () {
    final org = Organization.fromJson({
      'id': 'o1',
      'name': 'Org',
      'owner_identity': 'alice',
      'role': 'owner',
    });
    expect(org.role, 'owner');
  });

  test('multi-tenant models trim ids identities names and roles', () {
    final me = Me.fromJson({
      'identity': ' alice ',
      'organizations': [
        {'id': ' org-a ', 'name': ' Team A ', 'role': ' admin '},
      ],
      'projects': [
        {
          'id': ' p1 ',
          'org_id': ' org-a ',
          'name': ' Project A ',
          'role': ' owner ',
        },
      ],
    });
    final org = Organization.fromJson({
      'id': ' org-a ',
      'name': ' Team A ',
      'owner_identity': ' alice ',
      'role': ' owner ',
    });
    final project = Project.fromJson({
      'id': ' p1 ',
      'org_id': ' org-a ',
      'name': ' Project A ',
      'owner_identity': ' alice ',
      'role': ' member ',
    });
    final online = OnlineUser.fromJson({'identity': ' alice ', 'online': true});
    final user = User.fromJson({
      'identity': ' alice ',
      'display_name': ' Alice ',
    });

    expect(me.identity, 'alice');
    expect(me.organizations.single.id, 'org-a');
    expect(me.organizations.single.name, 'Team A');
    expect(me.organizations.single.role, 'admin');
    expect(me.projects.single.id, 'p1');
    expect(me.projects.single.orgId, 'org-a');
    expect(me.projects.single.name, 'Project A');
    expect(me.projects.single.role, 'owner');
    expect(org.id, 'org-a');
    expect(org.name, 'Team A');
    expect(org.ownerIdentity, 'alice');
    expect(org.role, 'owner');
    expect(project.id, 'p1');
    expect(project.orgId, 'org-a');
    expect(project.name, 'Project A');
    expect(project.ownerIdentity, 'alice');
    expect(project.role, 'member');
    expect(online.identity, 'alice');
    expect(user.identity, 'alice');
    expect(user.displayName, 'Alice');
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
            'other': {'enabled': true},
          },
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
