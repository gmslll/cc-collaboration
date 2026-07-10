import 'package:app/local/config.dart';
import 'package:app/local/session_manager.dart';
import 'package:app/local/session_overview.dart';
import 'package:app/local/worktrees.dart';
import 'package:flutter_test/flutter_test.dart';

ManagedSession managed(
  String id, {
  String name = 'session',
  String agent = 'codex',
  String workspace = 'ws-a',
  String project = 'repo-a',
  String projectPath = '/work/ws-a/repo-a',
  String worktree = '',
  String branch = '',
  SessionStatus status = SessionStatus.idle,
  DateTime? lastActivity,
  String preview = '',
  bool recentlyCompleted = false,
}) => ManagedSession(
  id: id,
  name: name,
  agent: agent,
  workspace: workspace,
  project: project,
  projectPath: projectPath,
  worktree: worktree,
  branch: branch,
  status: status,
  statusDetail: '',
  lastActivity: lastActivity,
  preview: preview,
  recentlyCompleted: recentlyCompleted,
);

void main() {
  group('resolveSessionProject', () {
    const workspaces = [
      WorkspaceCfg('alpha', '/work/alpha', 'codex', '', '', [
        ProjectCfg('api', '/work/alpha/api'),
        ProjectCfg('api-tools', '/work/alpha/api/tools'),
      ]),
      WorkspaceCfg('beta', '/work/beta', 'claude', '', '', [
        ProjectCfg('web', '/work/beta/web'),
        ProjectCfg('mobile', '/work/beta/mobile'),
      ]),
    ];

    test('main clone and worktrees resolve to the same owning project', () {
      final main = resolveSessionProject('/work/alpha/api', workspaces)!;
      final worktree = resolveSessionProject(
        '/work/alpha/api/.worktrees/feat-session-manager',
        workspaces,
      )!;

      expect(main.workspace.name, 'alpha');
      expect(worktree.workspace.name, 'alpha');
      expect(main.project.name, 'api');
      expect(worktree.project.name, 'api');
      expect(worktree.relativePath, '.worktrees/feat-session-manager');
    });

    test('longest project root wins and sibling workspaces stay separate', () {
      final nested = resolveSessionProject(
        '/work/alpha/api/tools/.worktrees/refactor',
        workspaces,
      )!;
      final beta = resolveSessionProject('/work/beta/mobile', workspaces)!;

      expect(nested.project.name, 'api-tools');
      expect(beta.workspace.name, 'beta');
      expect(beta.project.name, 'mobile');
      expect(resolveSessionProject('/tmp/orphan', workspaces), isNull);
    });
  });

  test('worktree resolver uses longest matching worktree path', () {
    final resolved = resolveSessionWorktree(
      '/work/alpha/api/.worktrees/feature/nested',
      const [
        Worktree('/work/alpha/api', 'main'),
        Worktree('/work/alpha/api/.worktrees/feature', 'feat/feature'),
      ],
    );

    expect(resolved?.branch, 'feat/feature');
  });

  test('groups Workspace -> Project and does not promote worktrees', () {
    final groups = groupManagedSessions([
      managed('main'),
      managed('worktree', worktree: 'feat-x', branch: 'feat/x'),
      managed(
        'other-project',
        project: 'repo-b',
        projectPath: '/work/ws-a/repo-b',
      ),
      managed(
        'other-workspace',
        workspace: 'ws-b',
        project: 'repo-c',
        projectPath: '/work/ws-b/repo-c',
      ),
    ]);

    expect(groups.map((group) => group.name), ['ws-a', 'ws-b']);
    expect(groups.first.projects, hasLength(2));
    final repoA = groups.first.projects.singleWhere(
      (project) => project.name == 'repo-a',
    );
    expect(
      repoA.sessions.map((session) => session.id),
      containsAll(['main', 'worktree']),
    );
    expect(
      groups.expand((group) => group.projects).map((project) => project.name),
      isNot(contains('feat-x')),
    );
  });

  test('unknown membership is retained under 其他会话', () {
    final groups = groupManagedSessions([
      managed('orphan', workspace: '', project: '', projectPath: ''),
    ]);

    expect(groups.single.name, '其他会话');
    expect(groups.single.isOther, isTrue);
    expect(groups.single.projects.single.name, '未归属');
    expect(groups.single.projects.single.sessions.single.id, 'orphan');
  });

  test(
    'configured default workspace is not mistaken for unknown ownership',
    () {
      final groups = groupManagedSessions([
        managed(
          'default',
          workspace: '',
          project: 'repo',
          projectPath: '/work/default/repo',
        ),
      ]);

      expect(groups.single.name, '(默认)');
      expect(groups.single.isOther, isFalse);
      expect(groups.single.projects.single.name, 'repo');
    },
  );

  test('status priority then recent activity controls project ordering', () {
    final now = DateTime(2026, 7, 10, 12);
    final sorted = [
      managed('completed', recentlyCompleted: true, lastActivity: now),
      managed('idle-old', lastActivity: now.subtract(const Duration(hours: 2))),
      managed('running', status: SessionStatus.working, lastActivity: now),
      managed('attention', status: SessionStatus.toolFailed),
      managed('idle-new', lastActivity: now),
    ]..sort(compareManagedSessions);

    expect(sorted.map((session) => session.id), [
      'attention',
      'running',
      'idle-new',
      'idle-old',
      'completed',
    ]);
  });

  test('duplicate 总管 labels gain project then branch/id qualifiers', () {
    final names = disambiguatedSessionNames([
      managed('a', name: '总管', project: 'api'),
      managed('b', name: '总管', project: 'web', projectPath: '/work/ws-a/web'),
      managed('c', name: '总管', project: 'api', branch: 'feat/c'),
      managed('d', name: 'worker'),
    ]);

    expect(names['b'], 'web · 总管');
    expect(names['a'], startsWith('api · 总管'));
    expect(names['c'], contains('feat/c'));
    expect(names.values.toSet(), hasLength(4));
    expect(names['d'], 'worker');
  });

  test('search covers session, hierarchy, branch, agent and preview', () {
    final item = managed(
      'searchable',
      name: 'reviewer',
      workspace: 'Kunlun',
      project: 'Frontend',
      branch: 'feat/session-manager',
      worktree: 'wt-manager',
      agent: 'Claude',
      preview: 'Permission required for build',
    );

    for (final query in [
      'review',
      'kunlun',
      'front',
      'session-manager',
      'wt-manager',
      'claude',
      'permission',
    ]) {
      expect(managedSessionMatches(item, query), isTrue, reason: query);
    }
    expect(managedSessionMatches(item, 'unrelated'), isFalse);
  });

  test('pin toggle and preference representation are stable', () {
    final pinned = togglePinnedSession({'a'}, 'b');
    expect(pinned, {'a', 'b'});
    expect(togglePinnedSession(pinned, 'a'), {'b'});

    final encoded = sessionManagerSetPrefValue({'ts9', 'ts2'});
    expect(encoded, '["ts2","ts9"]');
    expect(sessionManagerSetFromPref(encoded), {'ts2', 'ts9'});
    expect(sessionManagerSetFromPref('broken'), isEmpty);
  });

  test(
    'top workset separates current project, pinned and attention sessions',
    () {
      final sessions = [
        managed('current-a'),
        managed('current-b'),
        managed(
          'pinned-cross',
          project: 'repo-b',
          projectPath: '/work/ws-a/repo-b',
        ),
        managed(
          'attention-cross',
          workspace: 'ws-b',
          project: 'repo-c',
          projectPath: '/work/ws-b/repo-c',
          status: SessionStatus.waitingPermission,
        ),
        managed(
          'plain-cross',
          project: 'repo-d',
          projectPath: '/work/ws-a/repo-d',
        ),
      ];

      final workset = topSessionWorkset(
        sessions: sessions,
        activeId: 'current-a',
        pinnedIds: {'pinned-cross'},
      );

      expect(workset.projectIds, ['current-a', 'current-b']);
      expect(workset.pinnedIds, ['pinned-cross']);
      expect(workset.attentionIds, ['attention-cross']);
      expect(workset.allIds, isNot(contains('plain-cross')));
    },
  );

  test('explicitly hidden tabs stay hidden even if pinned', () {
    final workset = topSessionWorkset(
      sessions: [
        managed('active'),
        managed('pinned', project: 'other', projectPath: '/other'),
      ],
      activeId: 'active',
      pinnedIds: {'pinned'},
      explicitlyHiddenIds: {'pinned'},
    );

    expect(workset.projectIds, ['active']);
    expect(workset.pinnedIds, isEmpty);
  });

  test(
    'workspace focus filters without mutating order and toggles cleanly',
    () {
      const names = ['alpha', 'beta', 'gamma'];
      expect(visibleWorkspaceNames(names, null), names);
      expect(visibleWorkspaceNames(names, 'beta'), ['beta']);
      expect(
        workspaceFocusAfterDoubleClick(
          workspaceNames: names,
          currentFocus: null,
          tappedWorkspace: 'beta',
        ),
        'beta',
      );
      expect(
        workspaceFocusAfterDoubleClick(
          workspaceNames: names,
          currentFocus: 'beta',
          tappedWorkspace: 'beta',
        ),
        isNull,
      );
      expect(
        workspaceFocusAfterDoubleClick(
          workspaceNames: const ['only'],
          currentFocus: null,
          tappedWorkspace: 'only',
        ),
        isNull,
      );
    },
  );
}
