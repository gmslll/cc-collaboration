import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/screens/workspace_page.dart').readAsStringSync();

  test('tree, manager and top workset share the session project resolver', () {
    final managerProjection = source.substring(
      source.indexOf('ManagedSession _managedSessionFor'),
      source.indexOf('List<ManagedSession> get _managedSessions'),
    );
    final projectSessions = source.substring(
      source.indexOf('List<({int idx, TerminalSession s})> _sessionsFor('),
      source.indexOf('// _sessionsForDir'),
    );
    final dirSessions = source.substring(
      source.indexOf('List<({int idx, TerminalSession s})> _sessionsForDir('),
      source.indexOf('// [project]/[preLaunch]'),
    );

    expect(managerProjection, contains('resolveSessionProject'));
    expect(projectSessions, contains('resolveSessionProject'));
    expect(dirSessions, contains('resolveSessionProject'));
    expect(source, contains('TopSessionWorkset get _topSessionWorkset'));
  });

  test('project tree uses explicit compact hierarchy and small repo icon', () {
    final projectTile = source.substring(
      source.indexOf('Widget _projectTile('),
      source.indexOf('// 统一处理 VCS'),
    );
    final sessionNodes = source.substring(
      source.indexOf('List<Widget> _sessionNodesForDir('),
      source.indexOf('// Recent-output fallback'),
    );

    expect(projectTile, contains('size: 15'));
    expect(projectTile, contains('left: 30'));
    expect(projectTile, contains('minTileHeight: 36'));
    expect(projectTile, contains('TextOverflow.ellipsis'));
    expect(projectTile, contains('Tooltip('));
    expect(sessionNodes, contains('left: showHeader ? 28 : 14'));
    expect(sessionNodes, contains('TextOverflow.ellipsis'));
    expect(source, contains('showHeader: false'));
  });

  test('workspace focus is transient and exposes all exit paths', () {
    expect(source, contains('String? _focusedWorkspaceName;'));
    expect(source, isNot(contains("Prefs.setString('ws.focusedWorkspace")));
    expect(source, contains('WorkspaceFocusTitle('));
    expect(source, contains('WorkspaceFocusSurface('));
    expect(source, contains("tooltip: '显示全部工作区 (Esc)'"));
    expect(source, contains("'专注此工作区'"));
    expect(source, contains("'退出工作区专注'"));
    expect(
      source,
      contains('const SingleActivator(LogicalKeyboardKey.escape)'),
    );
  });

  test('session search does not steal the existing Cmd/Ctrl+K binding', () {
    expect(
      source,
      contains('const SingleActivator(LogicalKeyboardKey.keyK, meta: true)'),
    );
    expect(
      source,
      contains('const SingleActivator(LogicalKeyboardKey.keyK, control: true)'),
    );
    expect(source, isNot(contains('keyK, meta: true): _showSessionManager')));
    expect(
      source,
      isNot(contains('keyK, control: true): _showSessionManager')),
    );
  });

  test('running close and completed bulk close reuse existing closeTerm', () {
    final close = source.substring(
      source.indexOf('Future<bool> _requestCloseSession'),
      source.indexOf('void _activateManagedSession'),
    );
    expect(close, contains('if (session.busy)'));
    expect(close, contains("_confirm(\n        '结束运行中的会话'"));
    expect(close, contains('closeTerm(current)'));
    expect(close, contains('closeTerm(index)'));
    expect(close, isNot(contains('dispose()')));
  });

  test('stale pinned ids are pruned only after session restore completes', () {
    expect(source, contains('restoreTerms().then((_) {'));
    expect(source, contains('_pruneRestoredSessionPins();'));
    expect(source, isNot(contains('onTermsChanged = () {\n      _prune')));
  });

  test('opening a hidden session exits focus and reuses the restored tab', () {
    final activation = source.substring(
      source.indexOf('void _activateManagedSession'),
      source.indexOf('Future<void> _showSessionManager'),
    );

    expect(activation, contains('membership == null ||'));
    expect(activation, contains('_setWorkspaceFocus(null)'));
    expect(activation, contains('reopenTermView(index)'));
    expect(activation, isNot(contains('addTerm(')));
  });

  test('workspace collapse state is independent from transient focus', () {
    expect(source, contains('_workspaceCtlFor(ws.name)'));
    expect(source, contains("'ws.wsCollapsed.\${ws.name}'"));
    expect(source, isNot(contains("'ws.focusedWorkspace'")));
  });
}
