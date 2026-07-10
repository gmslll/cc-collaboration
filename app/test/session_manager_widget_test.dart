import 'package:app/local/session_manager.dart';
import 'package:app/local/session_overview.dart';
import 'package:app/screens/session_manager.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ManagedSession item(
  String id, {
  String name = 'worker',
  String workspace = 'alpha',
  String project = 'api',
  String projectPath = '/work/alpha/api',
  String branch = '',
  String worktree = '',
  SessionStatus status = SessionStatus.idle,
  String preview = '',
  bool recentlyCompleted = false,
}) => ManagedSession(
  id: id,
  name: name,
  agent: 'codex',
  workspace: workspace,
  project: project,
  projectPath: projectPath,
  worktree: worktree,
  branch: branch,
  status: status,
  statusDetail: '',
  lastActivity: DateTime(2026, 7, 10, 12),
  preview: preview,
  recentlyCompleted: recentlyCompleted,
);

Future<void> pumpDialog(
  WidgetTester tester, {
  required List<ManagedSession> sessions,
  ValueChanged<String>? onOpen,
  void Function(String, bool)? onPinned,
  Future<String?> Function(String)? onRename,
  Future<bool> Function(String)? onClose,
  Future<Set<String>> Function(Set<String>)? onCloseCompleted,
  void Function(String, bool)? onCollapsed,
  Set<String> pinned = const {},
  Set<String> collapsed = const {},
  List<ManagedSession> Function()? sessionProvider,
  Size size = const Size(1000, 760),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ccTheme(),
      home: Scaffold(
        body: SessionManagerDialog(
          sessions: sessions,
          sessionProvider: sessionProvider,
          activeId: sessions.firstOrNull?.id,
          pinnedIds: pinned,
          collapsedKeys: collapsed,
          onOpen: onOpen ?? (_) {},
          onPinnedChanged: onPinned ?? (_, _) {},
          onRename: onRename ?? (_) async => null,
          onClose: onClose ?? (_) async => false,
          onCloseCompleted: onCloseCompleted ?? (_) async => {},
          onCollapsedChanged: onCollapsed ?? (_, _) {},
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  test('dialog bounds remain inside very small viewports', () {
    expect(sessionManagerDialogWidth(const Size(220, 220)), 196);
    expect(sessionManagerDialogHeight(const Size(220, 220)), 188);
    expect(sessionManagerDialogWidth(const Size(1024, 800)), 480);
  });

  testWidgets('toolbar session entry is clickable', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: Center(
            child: SessionManagerEntry(count: 10, onPressed: () => taps++),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('session-manager-entry')));
    expect(taps, 1);
    expect(find.text('10 sessions'), findsOneWidget);
  });

  testWidgets('manager renders Workspace -> Project -> session and collapses', (
    tester,
  ) async {
    String? collapsedKey;
    await pumpDialog(
      tester,
      sessions: [
        item('s1'),
        item('s2', branch: 'feat/x'),
      ],
      onCollapsed: (key, collapsed) {
        if (collapsed) collapsedKey = key;
      },
    );

    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('api'), findsWidgets);
    expect(find.byKey(const ValueKey('session-row-s1')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('session-project-alpha::/work/alpha/api')),
    );
    await tester.pump();

    expect(collapsedKey, 'project:alpha::/work/alpha/api');
    expect(find.byKey(const ValueKey('session-row-s1')), findsNothing);
  });

  testWidgets('session row switches without creating another session', (
    tester,
  ) async {
    String? opened;
    await pumpDialog(
      tester,
      sessions: [item('s1'), item('s2')],
      onOpen: (id) => opened = id,
    );

    await tester.tap(find.byKey(const ValueKey('session-row-s2')));
    await tester.pump();

    expect(opened, 's2');
  });

  testWidgets('pin, rename, and close actions update the manager', (
    tester,
  ) async {
    final pinEvents = <(String, bool)>[];
    await pumpDialog(
      tester,
      sessions: [item('s1')],
      onPinned: (id, pinned) => pinEvents.add((id, pinned)),
      onRename: (_) async => 'renamed',
      onClose: (_) async => true,
    );

    await tester.tap(find.byKey(const ValueKey('session-pin-s1')));
    await tester.pump();
    expect(pinEvents, [('s1', true)]);

    await tester.tap(find.byKey(const ValueKey('session-menu-s1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    expect(find.text('renamed'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('session-menu-s1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('结束会话'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-row-s1')), findsNothing);
  });

  testWidgets(
    'group close completed excludes active work and removes returned ids',
    (tester) async {
      Set<String>? requested;
      await pumpDialog(
        tester,
        sessions: [
          item('done', recentlyCompleted: true),
          item('not-completed'),
        ],
        onCloseCompleted: (ids) async {
          requested = ids;
          return ids;
        },
      );

      await tester.tap(find.byKey(const ValueKey('session-group-menu-api')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭已完成'));
      await tester.pumpAndSettle();

      expect(requested, {'done'});
      expect(find.byKey(const ValueKey('session-row-done')), findsNothing);
      expect(
        find.byKey(const ValueKey('session-row-not-completed')),
        findsOneWidget,
      );
    },
  );

  testWidgets('search matches branch and preview', (tester) async {
    await pumpDialog(
      tester,
      sessions: [
        item('branch', branch: 'feat/session-manager'),
        item('preview', preview: 'permission required'),
        item('other'),
      ],
    );

    await tester.enterText(
      find.byKey(const ValueKey('session-manager-search')),
      'session-manager',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('session-row-branch')), findsOneWidget);
    expect(find.byKey(const ValueKey('session-row-other')), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('session-manager-search')),
      'permission',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('session-row-preview')), findsOneWidget);
  });

  testWidgets('status filter narrows to recently completed sessions', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      sessions: [item('idle'), item('done', recentlyCompleted: true)],
    );

    await tester.tap(find.byKey(const ValueKey('session-manager-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最近完成').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('session-row-done')), findsOneWidget);
    expect(find.byKey(const ValueKey('session-row-idle')), findsNothing);
  });

  testWidgets('open manager refreshes live session status without reopening', (
    tester,
  ) async {
    var current = item('live', status: SessionStatus.idle);
    await pumpDialog(
      tester,
      sessions: [current],
      sessionProvider: () => [current],
    );
    expect(find.text('空闲'), findsOneWidget);

    current = item('live', status: SessionStatus.waitingInput);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('等待输入'), findsOneWidget);
    expect(find.byKey(const ValueKey('session-row-live')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'narrow manager is near full width and long text does not overflow',
    (tester) async {
      await pumpDialog(
        tester,
        size: const Size(320, 480),
        sessions: [
          item(
            'long',
            name: 'very-long-session-name-' * 8,
            workspace: 'very-long-workspace-name-' * 5,
            project: 'very-long-project-name-' * 6,
            branch: 'feature/a-very-long-branch-name-' * 5,
            preview: 'long preview ' * 20,
          ),
        ],
      );

      final size = tester.getSize(
        find.byKey(const ValueKey('session-manager-dialog')),
      );
      expect(size.width, lessThanOrEqualTo(320));
      expect(size.width, greaterThanOrEqualTo(296));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wide manager stays within the 420-520px target', (tester) async {
    await pumpDialog(tester, sessions: [item('s1')]);
    final width = tester
        .getSize(find.byKey(const ValueKey('session-manager-dialog')))
        .width;
    expect(width, inInclusiveRange(420, 520));
  });

  testWidgets('very small viewport does not force a minimum-width overflow', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      size: const Size(220, 220),
      sessions: [item('tiny', name: 'very-long-session-name-' * 8)],
    );
    final size = tester.getSize(
      find.byKey(const ValueKey('session-manager-dialog')),
    );
    expect(size, const Size(196, 188));
    expect(tester.takeException(), isNull);
  });

  testWidgets('workspace focus title toggles and Escape exits focus', (
    tester,
  ) async {
    var toggles = 0;
    var exits = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: WorkspaceFocusSurface(
            focused: true,
            onExit: () => exits++,
            child: WorkspaceFocusTitle(
              enabled: true,
              onToggle: () => toggles++,
              child: const SizedBox(
                key: ValueKey('workspace-title'),
                width: 220,
                height: 42,
                child: Text(
                  'workspace-with-a-very-long-name-that-needs-ellipsis',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(WorkspaceFocusTitle));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byType(WorkspaceFocusTitle));
    await tester.pump();
    expect(toggles, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 100));
    expect(exits, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single workspace focus title ignores double click', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WorkspaceFocusTitle(
          enabled: false,
          onToggle: () => toggles++,
          child: const SizedBox(
            key: ValueKey('only-workspace'),
            width: 200,
            height: 42,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(WorkspaceFocusTitle));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byType(WorkspaceFocusTitle));
    await tester.pump();
    expect(toggles, 0);
  });
}
