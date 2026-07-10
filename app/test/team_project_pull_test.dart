import 'dart:async';
import 'dart:io';

import 'package:app/api/models.dart';
import 'package:app/screens/workspace_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDetail _detail({int repos = 2}) => ProjectDetail.fromJson({
  'project': {'id': 'p1', 'name': 'Kunlun / Platform'},
  'repo_bindings': [
    {
      'repo_name': 'backend',
      'clone_url': 'https://github.com/acme/backend.git',
    },
    if (repos > 1)
      {
        'repo_name': 'frontend',
        'clone_url': 'git@github.com:acme/frontend.git',
      },
  ],
});

void main() {
  test(
    'team workspace names and dialog size stay filesystem and viewport safe',
    () {
      expect(safeTeamWorkspaceName(' Kunlun / Platform '), 'Kunlun-Platform');
      expect(validTeamWorkspaceName('Kunlun-Platform'), isTrue);
      expect(validTeamWorkspaceName('../Kunlun'), isFalse);
      expect(safeTeamWorkspaceName('CON'), 'team-CON');
      expect(validTeamWorkspaceName('LPT1'), isFalse);
      expect(workspaceTeamProjectDialogSize(const Size(320, 500)).width, 288);
      expect(workspaceTeamProjectDialogSize(const Size(1200, 900)).width, 560);
    },
  );

  test('pull context rejects account or relay changes', () {
    final client = Object();
    expect(
      teamProjectPullContextMatches(
        expectedClient: client,
        currentClient: client,
        expectedRelay: 'https://relay',
        currentRelay: 'https://relay',
        expectedToken: 'old',
        currentToken: 'new',
        expectedIdentity: 'dev@x',
        currentIdentity: 'dev@x',
      ),
      isFalse,
    );
    expect(
      teamProjectPullContextMatches(
        expectedClient: client,
        currentClient: client,
        expectedRelay: 'https://relay',
        currentRelay: 'https://relay',
        expectedToken: 'token',
        currentToken: 'token',
        expectedIdentity: 'dev@x',
        currentIdentity: 'dev@x',
      ),
      isTrue,
    );
  });

  test(
    'clone orchestration retains successes and reports each failure',
    () async {
      final draft = TeamProjectPullDraft(
        project: _detail(),
        workspaceName: 'Kunlun',
        parentDirectory: '/workspaces',
        repoNames: const {'backend', 'frontend'},
      );
      final calls = <String>[];
      final streamed = <TeamProjectPullResult>[];
      final results = await orchestrateTeamProjectPull(draft, ({
        required workspaceName,
        required workspacePath,
        required repoName,
        required cloneUrl,
        required projectId,
      }) async {
        calls.add('$repoName@$workspacePath');
        if (repoName == 'frontend') {
          throw Exception('Permission denied (publickey)');
        }
        return {'status': 'cloned'};
      }, onResult: streamed.add);

      expect(calls, [
        'backend@${joinTeamProjectPath('/workspaces', 'Kunlun')}',
        'frontend@${joinTeamProjectPath('/workspaces', 'Kunlun')}',
      ]);
      expect(results, hasLength(2));
      expect(results.first.success, isTrue);
      expect(results.last.success, isFalse);
      expect(results.last.message, contains('Permission denied'));
      expect(streamed, results);
    },
  );

  testWidgets('pull dialog exposes loading and empty states', (tester) async {
    final completer = Completer<List<ProjectDetail>>();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => TeamProjectPullDialog(
                  loadProjects: () => completer.future,
                  pickDirectory: () async => null,
                  initialParentDirectory: '/workspaces',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('team-project-pull-loading')),
      findsOneWidget,
    );

    completer.complete(const []);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('team-project-pull-empty')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('pull dialog reports relay errors and retries', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => TeamProjectPullDialog(
                  loadProjects: () async {
                    calls++;
                    if (calls == 1) throw Exception('relay unavailable');
                    return [_detail()];
                  },
                  pickDirectory: () async => null,
                  initialParentDirectory: '/workspaces',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('team-project-pull-error')),
      findsOneWidget,
    );
    expect(find.textContaining('relay unavailable'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(
      find.byKey(const ValueKey('team-project-pull-project')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pull dialog selects repositories and returns a draft on narrow windows',
    (tester) async {
      tester.view.physicalSize = const Size(360, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TeamProjectPullDraft? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<TeamProjectPullDraft>(
                    context: context,
                    builder: (_) => TeamProjectPullDialog(
                      loadProjects: () async => [_detail()],
                      pickDirectory: () async => '/chosen',
                      initialParentDirectory: '/workspaces',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('拉取团队项目'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('team-project-pull-repo-frontend')),
      );
      await tester.pump();
      await tester.tap(find.text('开始拉取'));
      await tester.pumpAndSettle();

      expect(result?.workspaceName, 'Kunlun-Platform');
      expect(result?.repoNames, {'backend'});
      expect(result?.parentDirectory, '/workspaces');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pull dialog narrow visual regression', (tester) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => TeamProjectPullDialog(
                  loadProjects: () async => [_detail()],
                  pickDirectory: () async => null,
                  initialParentDirectory: '/Users/dev/workspaces',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(AlertDialog),
      matchesGoldenFile('goldens/team_project_pull_narrow.png'),
    );
  });

  testWidgets('partial-result progress dialog fits a 320px window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final draft = TeamProjectPullDraft(
      project: _detail(),
      workspaceName: 'Kunlun',
      parentDirectory: '/workspaces',
      repoNames: const {'backend', 'frontend'},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => TeamProjectPullProgressDialog(
                  draft: draft,
                  clone:
                      ({
                        required workspaceName,
                        required workspacePath,
                        required repoName,
                        required cloneUrl,
                        required projectId,
                      }) async {
                        if (repoName == 'frontend') {
                          throw Exception('Permission denied (publickey)');
                        }
                        return {'status': 'cloned'};
                      },
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('backend'), findsOneWidget);
    expect(find.text('frontend'), findsOneWidget);
    expect(find.textContaining('Permission denied'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '完成'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  test('workspace source exposes the exact right-click entry', () {
    final source = File('lib/screens/workspace_page.dart').readAsStringSync();
    expect(source, contains("label: '拉取团队项目'"));
    expect(source, contains("case 'pull-team':"));
    expect(source, contains('_showWorkspaceAreaMenu'));
  });
}
