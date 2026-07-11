import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/api/models.dart';
import 'package:app/api/relay_client.dart';
import 'package:app/local/config.dart';
import 'package:app/local/session_overview.dart';
import 'package:app/screens/capsule_plaza_page.dart';
import 'package:app/theme.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('capsule load target menus are viewport constrained', () {
    final source = File(
      'lib/screens/capsule_plaza_page.dart',
    ).readAsStringSync();
    final loadDialog = source.substring(
      source.indexOf('class _CapsuleLoadDialogState'),
      source.indexOf('// bundledSkillNames lists'),
    );

    expect(loadDialog, contains('MediaQuery.sizeOf(context)'));
    expect(loadDialog, contains('onPressed: _submitting'));
    expect(loadDialog, contains('canPop: !_submitting'));
    expect(source, contains('barrierDismissible: false'));
    expect(loadDialog, contains('capsuleLoadMenuMaxHeight'));
    expect(loadDialog, isNot(contains('menuMaxHeight: 320')));
    expect(
      loadDialog,
      isNot(
        contains(
          'DropdownMenuItem(value: x.name as String, child: Text(x.name as String))',
        ),
      ),
    );
    expect(loadDialog, contains('_stringItems(_workspaceNames)'));
    expect(loadDialog, contains('_stringItems(_projectNames)'));
    expect(loadDialog, contains('overflow: TextOverflow.ellipsis'));
  });

  test('capsule plaza labels public cards as team shared', () {
    final source = File(
      'lib/screens/capsule_plaza_page.dart',
    ).readAsStringSync();

    expect(source, contains('团队共享'));
    expect(source, isNot(contains('团队所有人能在广场看到')));
    expect(source, isNot(contains('设为公开,就会出现在这里')));
  });

  test('capsule readonly preview height is responsive', () {
    expect(capsuleReadonlyPreviewMaxHeight(const Size(1200, 900)), 130);
    expect(
      capsuleReadonlyPreviewMaxHeight(const Size(320, 480)),
      closeTo(96, 0.001),
    );
    expect(capsuleReadonlyPreviewMaxHeight(const Size(320, 300)), 82);
  });

  test('capsule load target menus are responsive', () {
    expect(capsuleLoadMenuMaxHeight(const Size(1200, 900)), 320);
    expect(
      capsuleLoadMenuMaxHeight(const Size(320, 420)),
      closeTo(193.2, 0.001),
    );
    expect(capsuleLoadMenuMaxHeight(const Size(320, 220)), 160);
  });

  test('capsule load dialog size fits compact screens', () {
    expect(capsuleLoadDialogSize(const Size(1200, 900)), const Size(480, 720));
    expect(capsuleLoadDialogSize(const Size(360, 420)), const Size(328, 372));
    expect(capsuleLoadDialogSize(const Size(220, 220)), const Size(188, 172));
  });

  test('capsule delete dialog width fits compact screens', () {
    expect(capsuleDeleteDialogWidth(const Size(1200, 900)), 420);
    expect(capsuleDeleteDialogWidth(const Size(320, 700)), 288);
    expect(capsuleDeleteDialogWidth(const Size(20, 700)), 420);
  });

  test('capsule edit dialog size fits compact screens', () {
    expect(capsuleEditDialogSize(const Size(1200, 900)), const Size(460, 640));
    expect(capsuleEditDialogSize(const Size(360, 420)), const Size(328, 372));
    expect(capsuleEditDialogSize(const Size(220, 220)), const Size(188, 172));
  });

  test('capsule delete confirmation uses responsive content', () {
    final source = File(
      'lib/screens/capsule_plaza_page.dart',
    ).readAsStringSync();
    final deleteDialog = source.substring(
      source.indexOf('Future<void> _deleteCapsule('),
      source.indexOf('Future<void> _editCapsule('),
    );

    expect(deleteDialog, contains('MediaQuery.sizeOf(ctx)'));
    expect(deleteDialog, contains('insetPadding: const EdgeInsets.symmetric'));
    expect(deleteDialog, contains('maxLines: 1'));
    expect(deleteDialog, contains('overflow: TextOverflow.ellipsis'));
    expect(deleteDialog, contains('capsuleDeleteDialogWidth(size)'));
    expect(deleteDialog, contains('SingleChildScrollView'));
    expect(deleteDialog, isNot(contains('content: Text(')));
  });

  test('capsule readonly previews avoid fixed height', () {
    final source = File(
      'lib/screens/capsule_plaza_page.dart',
    ).readAsStringSync();
    final editDialog = source.substring(
      source.indexOf('class _CapsuleEditDialogState'),
    );

    expect(editDialog, contains('capsuleReadonlyPreviewMaxHeight'));
    expect(editDialog, isNot(contains('BoxConstraints(maxHeight: 130)')));
  });

  test('capsule edit dialog uses viewport based bounds', () {
    final source = File(
      'lib/screens/capsule_plaza_page.dart',
    ).readAsStringSync();
    final editDialog = source.substring(
      source.indexOf('class _CapsuleEditDialogState'),
      source.length,
    );

    expect(editDialog, contains('capsuleEditDialogSize'));
    expect(editDialog, contains('MediaQuery.sizeOf(context)'));
    expect(editDialog, contains('insetPadding: const EdgeInsets.symmetric'));
    expect(editDialog, isNot(contains('maxWidth: 460')));
    expect(editDialog, isNot(contains('maxHeight: 640')));
  });

  test('capsule load and edit dialogs guard stale plaza context', () {
    final source = File(
      'lib/screens/capsule_plaza_page.dart',
    ).readAsStringSync();
    final loadDialog = source.substring(
      source.indexOf('class _CapsuleLoadDialogState'),
      source.indexOf('// bundledSkillNames lists'),
    );
    final editDialog = source.substring(
      source.indexOf('class _CapsuleEditDialog extends StatefulWidget'),
      source.length,
    );

    expect(loadDialog, contains('bool _closeIfStaleContext()'));
    expect(loadDialog, contains('if (_closeIfStaleContext()) return;'));
    expect(loadDialog, contains('if (!mounted) return;'));
    expect(editDialog, contains('required this.isCurrentContext'));
    expect(editDialog, contains('if (!widget.isCurrentContext())'));
    expect(editDialog, contains('Navigator.of(context).pop(false)'));
  });

  test('capsule load dialog uses viewport based bounds', () {
    final source = File(
      'lib/screens/capsule_plaza_page.dart',
    ).readAsStringSync();
    final loadDialog = source.substring(
      source.indexOf('class _CapsuleLoadDialogState'),
      source.indexOf('// bundledSkillNames lists'),
    );

    expect(loadDialog, contains('capsuleLoadDialogSize'));
    expect(loadDialog, contains('MediaQuery.sizeOf(context)'));
    expect(loadDialog, contains('insetPadding: const EdgeInsets.symmetric'));
    expect(loadDialog, contains('SingleChildScrollView'));
    expect(loadDialog, contains('maxLines: 2'));
    expect(loadDialog, contains('overflow: TextOverflow.ellipsis'));
    expect(loadDialog, isNot(contains('maxWidth: 480')));
  });

  test('capsule load forwards selected relay project id to local spawn', () {
    final source = File(
      'lib/screens/capsule_plaza_page.dart',
    ).readAsStringSync();
    final loadDialog = source.substring(
      source.indexOf('class _CapsuleLoadDialogState'),
      source.indexOf('// bundledSkillNames lists'),
    );

    expect(loadDialog, contains('projectId: _targetProjectId'));
  });

  test('capsule grid column count is stable across desktop widths', () {
    expect(capsuleGridColumnCount(420), 1);
    expect(capsuleGridColumnCount(720), 2);
    expect(capsuleGridColumnCount(1200), 3);
  });

  test('capsule summary preview removes the repeated headline', () {
    expect(
      capsuleSummaryPreview(
        _capsule(
          'summary',
          headline: 'Release helper',
          summary: 'Release helper\nTracks the release and verifies artifacts.',
        ),
      ),
      'Tracks the release and verifies artifacts.',
    );
    expect(
      capsuleSummaryPreview(_capsule('fallback', headline: 'Only one line')),
      '暂无补充摘要',
    );
  });

  test('capsule list metadata remains compatible with older responses', () {
    final capsule = CapsuleListItem.fromJson({
      'id': 'legacy',
      'owner': 'me@x',
      'visibility': 'private',
      'source_agent': 'codex',
      'headline': 'Legacy capsule',
      'created_at': '2026-01-01T00:00:00Z',
    });

    expect(capsule.summary, 'Legacy capsule');
    expect(capsule.skillPackCount, 0);
    expect(capsule.projectId, isEmpty);
    expect(capsule.updatedAt, capsule.createdAt);
  });

  testWidgets('desktop capsule plaza uses a three-column card grid', (
    tester,
  ) async {
    await _setSurfaceSize(tester, const Size(1200, 900));
    final client = _ImmediateCapsulesClient([
      for (var i = 0; i < 4; i++) _capsule('grid-$i', headline: 'Capsule $i'),
    ]);

    await _pumpPlaza(tester, client: client, isDesktop: true);

    final grid = tester.widget<GridView>(
      find.byKey(const ValueKey('capsule-grid')),
    );
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 3);
    expect(delegate.mainAxisExtent, 280);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('capsule-card-grid-0'))).dy,
      tester.getTopLeft(find.byKey(const ValueKey('capsule-card-grid-2'))).dy,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow capsule plaza uses one column without text overflow', (
    tester,
  ) async {
    await _setSurfaceSize(tester, const Size(360, 780));
    final longTitle = List.filled(12, '超长胶囊标题').join('');
    final longRepo = List.filled(10, 'very-long-repository-name').join('-');
    final client = _ImmediateCapsulesClient([
      _capsule(
        'long',
        headline: longTitle,
        summary: '$longTitle\n${List.filled(20, '摘要内容').join('')}',
        repoName: longRepo,
        hasPersona: true,
        skillPackCount: 3,
      ),
      _capsule('second', headline: 'Second capsule'),
    ]);

    await _pumpPlaza(tester, client: client, isDesktop: true);

    final grid = tester.widget<GridView>(
      find.byKey(const ValueKey('capsule-grid')),
    );
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 1);
    final title = tester.widget<Text>(
      find.byKey(const ValueKey('capsule-title-long')),
    );
    expect(title.maxLines, 2);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('capsule-card-second'))).dy,
      greaterThan(
        tester.getTopLeft(find.byKey(const ValueKey('capsule-card-long'))).dy,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('search and visibility filters distinguish no results', (
    tester,
  ) async {
    await _setSurfaceSize(tester, const Size(900, 760));
    final client = _ImmediateCapsulesClient([
      _capsule(
        'mine-private',
        headline: 'Private release notes',
        owner: 'me@x',
        visibility: 'private',
        repoName: 'mobile-app',
      ),
      _capsule(
        'mine-shared',
        headline: 'Shared deployment helper',
        owner: 'me@x',
        repoName: 'backend',
      ),
      _capsule(
        'team-shared',
        headline: 'Team QA role',
        owner: 'teammate@x',
        repoName: 'qa-tools',
      ),
    ]);
    await _pumpPlaza(tester, client: client, isDesktop: true);

    await tester.enterText(
      find.byKey(const ValueKey('capsule-search')),
      'qa-tools',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('capsule-card-team-shared')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('capsule-card-mine-private')),
      findsNothing,
    );

    await tester.enterText(
      find.byKey(const ValueKey('capsule-search')),
      'not-found',
    );
    await tester.pump();
    expect(find.text('没有匹配的胶囊'), findsOneWidget);
    expect(find.text('还没有胶囊'), findsNothing);

    await tester.tap(find.widgetWithText(OutlinedButton, '清除筛选'));
    await tester.pump();
    final scopeFilter = find.byKey(const ValueKey('capsule-visibility-filter'));
    await tester.tap(
      find.descendant(of: scopeFilter, matching: find.text('团队共享')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('capsule-card-mine-private')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('capsule-card-mine-shared')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('capsule-card-team-shared')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('source menu filters agents without persistent filter buttons', (
    tester,
  ) async {
    await _setSurfaceSize(tester, const Size(900, 760));
    final client = _ImmediateCapsulesClient([
      _capsule('codex', headline: 'Codex capsule', repoName: 'codex-repo'),
      _capsule(
        'claude',
        headline: 'Claude capsule',
        sourceAgent: 'claude',
        repoName: 'claude-repo',
      ),
    ]);
    await _pumpPlaza(tester, client: client, isDesktop: true);

    await tester.tap(find.byTooltip('筛选来源和项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('capsule-agent-claude')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('capsule-card-claude')), findsOneWidget);
    expect(find.byKey(const ValueKey('capsule-card-codex')), findsNothing);

    await tester.tap(find.byTooltip('筛选来源和项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('capsule-agent-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('筛选来源和项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('capsule-repo-codex-repo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('capsule-card-codex')), findsOneWidget);
    expect(find.byKey(const ValueKey('capsule-card-claude')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only owned capsules expose edit and delete in overflow', (
    tester,
  ) async {
    await _setSurfaceSize(tester, const Size(900, 760));
    final client = _ImmediateCapsulesClient([
      _capsule('mine', headline: 'Mine', owner: 'me@x'),
      _capsule('theirs', headline: 'Theirs', owner: 'teammate@x'),
    ]);
    await _pumpPlaza(tester, client: client, isDesktop: true);

    expect(find.byKey(const ValueKey('capsule-actions-mine')), findsOneWidget);
    expect(find.byKey(const ValueKey('capsule-actions-theirs')), findsNothing);
    expect(find.text('编辑'), findsNothing);
    expect(find.text('删除'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('capsule-actions-mine')));
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate capsule delete is disabled while request is pending', (
    tester,
  ) async {
    await _setSurfaceSize(tester, const Size(900, 760));
    final client = _PendingDeleteClient([
      _capsule('delete-once', headline: 'Delete once', owner: 'me@x'),
    ]);
    await _pumpPlaza(tester, client: client, isDesktop: true);

    await _chooseOwnerAction(tester, 'delete-once', '删除');
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    expect(client.deletedIds, ['delete-once']);

    await tester.tap(find.byKey(const ValueKey('capsule-actions-delete-once')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final pendingDeleteItem = tester.widget<Widget>(
      find.byKey(const ValueKey('capsule-action-delete-delete-once')),
    );
    expect((pendingDeleteItem as dynamic).enabled, isFalse);
    expect(client.deletedIds, ['delete-once']);

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    client.completeDelete();
    await tester.pumpAndSettle();
    expect(client.deletedIds, ['delete-once']);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('capsule plaza has distinct loading empty and error states', (
    tester,
  ) async {
    await _setSurfaceSize(tester, const Size(800, 700));
    final delayed = _DelayedCapsulesClient();
    await _pumpPlaza(tester, client: delayed, settle: false);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    delayed.completeNext([]);
    await tester.pumpAndSettle();
    expect(find.text('还没有胶囊'), findsOneWidget);

    final failing = _ImmediateCapsulesClient(
      const [],
      error: Exception('relay unavailable'),
    );
    await _pumpPlaza(tester, client: failing);
    expect(find.textContaining('relay unavailable'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '重试'), findsOneWidget);
    expect(find.text('还没有胶囊'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale capsule plaza load cannot overwrite a newer refresh', (
    tester,
  ) async {
    final client = _DelayedCapsulesClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: CapsulePlazaPage(
            client: client,
            identity: ' Me@X ',
            overviewStore: SessionOverviewStore(),
            config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
            isDesktop: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(client.requestCount, 1);

    client.completeNext([_capsule('old', headline: 'Old capsule')]);
    await tester.pumpAndSettle();
    expect(find.text('Old capsule'), findsOneWidget);

    await tester.tap(find.byTooltip('刷新胶囊'));
    await tester.pump();
    expect(client.requestCount, 2);

    await _chooseOwnerAction(tester, 'old', '删除');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    expect(client.deletedIds, ['old']);
    expect(client.requestCount, 3);

    client.completeLatest([_capsule('new', headline: 'New capsule')]);
    await tester.pumpAndSettle();
    expect(find.text('New capsule'), findsOneWidget);
    expect(find.text('Older capsule'), findsNothing);

    client.completeNext([_capsule('older', headline: 'Older capsule')]);
    await tester.pumpAndSettle();
    expect(find.text('New capsule'), findsOneWidget);
    expect(find.text('Older capsule'), findsNothing);

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('capsule plaza account switch ignores stale capsules', (
    tester,
  ) async {
    final oldClient = _DelayedCapsulesClient();
    final newClient = _DelayedCapsulesClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: CapsulePlazaPage(
            client: oldClient,
            identity: 'old@x',
            overviewStore: SessionOverviewStore(),
            config: AppConfig('http://127.0.0.1:1', 'old', 'old@x', const {}),
            isDesktop: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(oldClient.requestCount, 1);

    await tester.enterText(
      find.byKey(const ValueKey('capsule-search')),
      'old-account-only',
    );
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: CapsulePlazaPage(
            client: newClient,
            identity: 'new@x',
            overviewStore: SessionOverviewStore(),
            config: AppConfig('http://127.0.0.1:1', 'new', 'new@x', const {}),
            isDesktop: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(newClient.requestCount, 1);

    newClient.completeNext([
      _capsule('new', headline: 'New private capsule', owner: 'new@x'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('New private capsule'), findsOneWidget);

    oldClient.completeNext([
      _capsule('old', headline: 'Old private capsule', owner: 'old@x'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('New private capsule'), findsOneWidget);
    expect(find.text('Old private capsule'), findsNothing);
  });

  testWidgets('capsule delete confirmation after account switch is ignored', (
    tester,
  ) async {
    final oldClient = _DelayedCapsulesClient();
    final newClient = _DelayedCapsulesClient();
    final overviewStore = SessionOverviewStore();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: CapsulePlazaPage(
            client: oldClient,
            identity: 'old@x',
            overviewStore: overviewStore,
            config: AppConfig('http://127.0.0.1:1', 'old', 'old@x', const {}),
            isDesktop: false,
          ),
        ),
      ),
    );
    await tester.pump();
    oldClient.completeNext([
      _capsule('old', headline: 'Old capsule', owner: 'old@x'),
    ]);
    await tester.pumpAndSettle();

    await _chooseOwnerAction(tester, 'old', '删除');
    await tester.pumpAndSettle();
    expect(find.text('删除胶囊?'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: CapsulePlazaPage(
            client: newClient,
            identity: 'new@x',
            overviewStore: overviewStore,
            config: AppConfig('http://127.0.0.1:1', 'new', 'new@x', const {}),
            isDesktop: false,
          ),
        ),
      ),
    );
    await tester.pump();
    newClient.completeNext([
      _capsule('new', headline: 'New capsule', owner: 'new@x'),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(oldClient.deletedIds, isEmpty);
    expect(newClient.deletedIds, isEmpty);
    expect(find.text('New capsule'), findsOneWidget);
    expect(find.text('Old capsule'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('capsule edit save after account switch is ignored', (
    tester,
  ) async {
    final oldClient = _DelayedCapsulesClient();
    final newClient = _DelayedCapsulesClient();
    final overviewStore = SessionOverviewStore();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: CapsulePlazaPage(
            client: oldClient,
            identity: 'old@x',
            overviewStore: overviewStore,
            config: AppConfig('http://127.0.0.1:1', 'old', 'old@x', const {}),
            isDesktop: false,
          ),
        ),
      ),
    );
    await tester.pump();
    oldClient.completeNext([
      _capsule('old', headline: 'Old capsule', owner: 'old@x'),
    ]);
    await tester.pumpAndSettle();

    await _chooseOwnerAction(tester, 'old', '编辑');
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('capsule-edit-summary')),
      'Old edited capsule',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    expect(oldClient.patchCalls, 1);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: CapsulePlazaPage(
            client: newClient,
            identity: 'new@x',
            overviewStore: overviewStore,
            config: AppConfig('http://127.0.0.1:1', 'new', 'new@x', const {}),
            isDesktop: false,
          ),
        ),
      ),
    );
    await tester.pump();
    newClient.completeNext([
      _capsule('new', headline: 'New capsule', owner: 'new@x'),
    ]);
    await tester.pump();
    await tester.pump();

    oldClient.completePatch();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(newClient.patchCalls, 0);
    expect(find.text('New capsule'), findsOneWidget);
    expect(find.text('Old capsule'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('capsule edit cannot start a stale-account mutation', (
    tester,
  ) async {
    final oldClient = _DelayedCapsulesClient();
    final newClient = _DelayedCapsulesClient();
    final overviewStore = SessionOverviewStore();

    Widget page(RelayClient client, String identity, String token) =>
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(
            body: CapsulePlazaPage(
              client: client,
              identity: identity,
              overviewStore: overviewStore,
              config: AppConfig(
                'http://127.0.0.1:1',
                token,
                identity,
                const {},
              ),
              isDesktop: false,
            ),
          ),
        );

    await tester.pumpWidget(page(oldClient, 'old@x', 'old'));
    await tester.pump();
    oldClient.completeNext([
      _capsule('old-stale', headline: 'Old capsule', owner: 'old@x'),
    ]);
    await tester.pumpAndSettle();
    await _chooseOwnerAction(tester, 'old-stale', '编辑');
    await tester.pumpAndSettle();

    await tester.pumpWidget(page(newClient, 'new@x', 'new'));
    await tester.pump();
    newClient.completeNext([
      _capsule('new-current', headline: 'New capsule', owner: 'new@x'),
    ]);
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(oldClient.patchCalls, 0);
    expect(newClient.patchCalls, 0);
    expect(find.text('New capsule'), findsOneWidget);
    expect(find.text('编辑胶囊'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('capsule edit ignores duplicate save taps', (tester) async {
    final client = _DelayedCapsulesClient();
    final overviewStore = SessionOverviewStore();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: CapsulePlazaPage(
            client: client,
            identity: 'me@x',
            overviewStore: overviewStore,
            config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
            isDesktop: false,
          ),
        ),
      ),
    );
    await tester.pump();
    client.completeNext([
      _capsule('cap-edit', headline: 'Edit capsule', owner: 'me@x'),
    ]);
    await tester.pumpAndSettle();

    await _chooseOwnerAction(tester, 'cap-edit', '编辑');
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('capsule-edit-summary')),
      'Edited once',
    );

    final save = find.widgetWithText(FilledButton, '保存');
    await tester.tap(save);
    await tester.tap(save);
    await tester.pump();

    expect(client.patchCalls, 1);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('capsule-edit-summary')))
          .enabled,
      isFalse,
    );

    client.completePatch();
    await tester.pump();
    client.completeLatest([
      _capsule('cap-edit', headline: 'Edited once', owner: 'me@x'),
    ]);
    await tester.pumpAndSettle();

    expect(client.patchCalls, 1);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
    'capsule load keeps dialog open when opening prompt dispatch fails',
    (tester) async {
      final client = _DelayedCapsulesClient();
      final overview = SessionOverviewStore();
      var spawnCalls = 0;
      var dispatchCalls = 0;
      overview.spawnHandler =
          ({
            required workspace,
            required project,
            required kind,
            projectId,
            newWorktreeBranch,
            worktreeStart,
            resumeAgentSessionId,
            workdir,
          }) async {
            spawnCalls++;
            return ('sid-new', null);
          };
      overview.dispatchHandler = (_) {
        dispatchCalls++;
        return 'bus down';
      };
      final config = AppConfig(
        'http://127.0.0.1:1',
        'tok',
        'me@x',
        const {},
        const [
          WorkspaceCfg('ws', '/tmp', 'codex', '', '', [
            ProjectCfg('proj', '/tmp/project', '', 'relay-proj-1'),
          ]),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(
            body: CapsulePlazaPage(
              client: client,
              identity: 'me@x',
              overviewStore: overview,
              config: config,
              isDesktop: true,
            ),
          ),
        ),
      );
      await tester.pump();
      client.completeNext([
        _capsule(
          'cap-load',
          headline: 'Load me',
          hasTranscript: false,
          hasPersona: true,
        ),
      ]);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, '载入'));
      await tester.pumpAndSettle();
      expect(find.text('载入胶囊'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '起会话'));
      await tester.pumpAndSettle();

      expect(spawnCalls, 1);
      expect(dispatchCalls, 1);
      expect(find.text('载入胶囊'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '起会话'), findsOneWidget);
      expect(find.textContaining('会话已起,但投递开场失败: bus down'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(seconds: 5));
    },
  );

  testWidgets('capsule load ignores duplicate submit taps', (tester) async {
    final client = _DelayedCapsulesClient();
    final overview = SessionOverviewStore();
    final spawn = Completer<(String?, String?)>();
    var spawnCalls = 0;
    var dispatchCalls = 0;
    overview.spawnHandler =
        ({
          required workspace,
          required project,
          required kind,
          projectId,
          newWorktreeBranch,
          worktreeStart,
          resumeAgentSessionId,
          workdir,
        }) {
          spawnCalls++;
          return spawn.future;
        };
    overview.dispatchHandler = (_) {
      dispatchCalls++;
      return null;
    };
    final config = AppConfig(
      'http://127.0.0.1:1',
      'tok',
      'me@x',
      const {},
      const [
        WorkspaceCfg('ws', '/tmp', 'codex', '', '', [
          ProjectCfg('proj', '/tmp/project', '', 'relay-proj-1'),
        ]),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: CapsulePlazaPage(
            client: client,
            identity: 'me@x',
            overviewStore: overview,
            config: config,
            isDesktop: true,
          ),
        ),
      ),
    );
    await tester.pump();
    client.completeNext([
      _capsule(
        'cap-load-once',
        headline: 'Load once',
        hasTranscript: false,
        hasPersona: true,
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '载入'));
    await tester.pumpAndSettle();

    final submit = find.widgetWithText(FilledButton, '起会话');
    await tester.tap(submit);
    await tester.tap(submit);
    for (var i = 0; i < 10 && spawnCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(spawnCalls, 1);

    spawn.complete(('sid-new', null));
    await tester.pumpAndSettle();

    expect(spawnCalls, 1);
    expect(dispatchCalls, 1);
    expect(find.text('载入胶囊'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('bound capsule prefers the matching local repo environment', (
    tester,
  ) async {
    final client = _DelayedCapsulesClient();
    final overview = SessionOverviewStore();
    overview.resolveCapsuleEnvironmentHandler = (_) => const [
      CapsuleEnvironmentTarget(
        workspace: 'team',
        project: 'other-repo',
        projectId: 'relay-project',
        workdir: '/tmp/team/other',
      ),
      CapsuleEnvironmentTarget(
        workspace: 'team',
        project: 'cc-collaboration',
        projectId: 'relay-project',
        workdir: '/tmp/team/cc-collaboration',
      ),
    ];
    String? spawnedWorkspace, spawnedProject, spawnedProjectId;
    overview.spawnHandler =
        ({
          required workspace,
          required project,
          required kind,
          projectId,
          newWorktreeBranch,
          worktreeStart,
          resumeAgentSessionId,
          workdir,
        }) async {
          spawnedWorkspace = workspace;
          spawnedProject = project;
          spawnedProjectId = projectId;
          return ('sid-bound', null);
        };
    overview.dispatchHandler = (_) => null;
    final config = AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {});

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: CapsulePlazaPage(
            client: client,
            identity: 'me@x',
            overviewStore: overview,
            config: config,
            isDesktop: true,
          ),
        ),
      ),
    );
    await tester.pump();
    client.completeNext([
      _capsule(
        'bound-local',
        headline: 'Bound local',
        projectId: 'relay-project',
        hasTranscript: false,
        hasPersona: true,
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '载入'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('capsule-environment-ready')), findsOne);
    expect(find.textContaining('team / cc-collaboration'), findsWidgets);

    final submit = find.widgetWithText(FilledButton, '起会话');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(spawnedWorkspace, 'team');
    expect(spawnedProject, 'cc-collaboration');
    expect(spawnedProjectId, 'relay-project');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
    'missing bound project prepares environment before spawning the session',
    (tester) async {
      final client = _ProjectCapsulesClient();
      final overview = SessionOverviewStore();
      overview.resolveCapsuleEnvironmentHandler = (_) => const [
        CapsuleEnvironmentTarget(
          workspace: 'existing',
          project: 'backend-only',
          projectId: 'relay-project',
          workdir: '/tmp/existing/backend-only',
        ),
      ];
      CapsuleEnvironmentRequest? prepared;
      overview.prepareCapsuleEnvironmentHandler = (request) async {
        prepared = request;
        return (
          const CapsuleEnvironmentResult(
            targets: [
              CapsuleEnvironmentTarget(
                workspace: 'relay-project',
                project: 'cc-collaboration',
                projectId: 'relay-project',
                workdir: '/tmp/relay-project/cc-collaboration',
              ),
            ],
          ),
          null,
        );
      };
      String? spawnedProjectId;
      overview.spawnHandler =
          ({
            required workspace,
            required project,
            required kind,
            projectId,
            newWorktreeBranch,
            worktreeStart,
            resumeAgentSessionId,
            workdir,
          }) async {
            spawnedProjectId = projectId;
            return ('sid-prepared', null);
          };
      overview.dispatchHandler = (_) => null;
      final config = AppConfig(
        'http://127.0.0.1:1',
        'tok',
        'me@x',
        const {},
        const [],
        '',
        '/tmp',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(
            body: CapsulePlazaPage(
              client: client,
              identity: 'me@x',
              overviewStore: overview,
              config: config,
              isDesktop: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '载入'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('capsule-environment-missing')),
        findsOne,
      );

      final submit = find.widgetWithText(FilledButton, '载入环境并起会话');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(prepared?.projectId, 'relay-project');
      expect(
        prepared?.repos.map((repo) => repo.name),
        contains('cc-collaboration'),
      );
      expect(spawnedProjectId, 'relay-project');
      expect(find.text('载入胶囊'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    },
  );

  testWidgets(
    'environment preparation never falls back to a different project repo',
    (tester) async {
      final client = _ProjectCapsulesClient();
      final overview = SessionOverviewStore();
      overview.resolveCapsuleEnvironmentHandler = (_) => const [
        CapsuleEnvironmentTarget(
          workspace: 'existing',
          project: 'backend-only',
          projectId: 'relay-project',
          workdir: '/tmp/existing/backend-only',
        ),
      ];
      overview.prepareCapsuleEnvironmentHandler = (_) async => (
        const CapsuleEnvironmentResult(
          targets: [
            CapsuleEnvironmentTarget(
              workspace: 'existing',
              project: 'backend-only',
              projectId: 'relay-project',
              workdir: '/tmp/existing/backend-only',
            ),
          ],
          errors: ['cc-collaboration: clone failed'],
        ),
        null,
      );
      var spawnCalls = 0;
      overview.spawnHandler =
          ({
            required workspace,
            required project,
            required kind,
            projectId,
            newWorktreeBranch,
            worktreeStart,
            resumeAgentSessionId,
            workdir,
          }) async {
            spawnCalls++;
            return ('should-not-spawn', null);
          };
      final config = AppConfig(
        'http://127.0.0.1:1',
        'tok',
        'me@x',
        const {},
        const [],
        '',
        '/tmp',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ccTheme(),
          home: Scaffold(
            body: CapsulePlazaPage(
              client: client,
              identity: 'me@x',
              overviewStore: overview,
              config: config,
              isDesktop: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '载入'));
      await tester.pumpAndSettle();
      final submit = find.widgetWithText(FilledButton, '载入环境并起会话');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(spawnCalls, 0);
      expect(find.text('载入胶囊'), findsOne);
      expect(find.textContaining('来源仓库 cc-collaboration 未成功载入'), findsOne);
      await tester.pump(const Duration(seconds: 5));
    },
  );
}

Future<void> _setSurfaceSize(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<void> _pumpPlaza(
  WidgetTester tester, {
  required RelayClient client,
  bool isDesktop = false,
  bool settle = true,
  String identity = 'me@x',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ccTheme(),
      home: Scaffold(
        body: CapsulePlazaPage(
          client: client,
          identity: identity,
          overviewStore: SessionOverviewStore(),
          config: AppConfig('http://127.0.0.1:1', 'tok', identity, const {}),
          isDesktop: isDesktop,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _chooseOwnerAction(
  WidgetTester tester,
  String capsuleId,
  String action,
) async {
  await tester.tap(find.byKey(ValueKey('capsule-actions-$capsuleId')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  final actionKey = action == '编辑' ? 'edit' : 'delete';
  await tester.tap(
    find.byKey(ValueKey('capsule-action-$actionKey-$capsuleId')),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

class _ImmediateCapsulesClient extends RelayClient {
  final List<CapsuleListItem> items;
  final Object? error;

  _ImmediateCapsulesClient(this.items, {this.error})
    : super('http://127.0.0.1', 'tok');

  @override
  Future<List<CapsuleListItem>> capsules() async {
    if (error != null) throw error!;
    return items;
  }

  @override
  Future<List<Organization>> organizations() async => const [];

  @override
  Future<List<Project>> projects() async => const [];
}

class _PendingDeleteClient extends _ImmediateCapsulesClient {
  final _delete = Completer<void>();
  final List<String> deletedIds = [];

  _PendingDeleteClient(super.items);

  @override
  Future<void> deleteCapsule(String id) {
    deletedIds.add(id);
    return _delete.future;
  }

  void completeDelete() => _delete.complete();
}

class _DelayedCapsulesClient extends RelayClient {
  final _requests = <Completer<List<CapsuleListItem>>>[];
  final _patches = <Completer<void>>[];

  _DelayedCapsulesClient() : super('http://127.0.0.1', 'tok');

  int get requestCount => _requests.length;
  int get patchCalls => _patches.length;

  @override
  Future<List<CapsuleListItem>> capsules() {
    final completer = Completer<List<CapsuleListItem>>();
    _requests.add(completer);
    return completer.future;
  }

  @override
  Future<List<Organization>> organizations() async => const [];

  @override
  Future<List<Project>> projects() async => const [];

  final deletedIds = <String>[];

  @override
  Future<void> deleteCapsule(String id) async {
    deletedIds.add(id);
  }

  @override
  Future<Package> get(String id) async {
    final persona = utf8.encode('persona body');
    return Package.fromJson({
      'id': id,
      'kind': 'capsule',
      'sender': 'owner@x',
      'recipient': 'viewer@x',
      'urgency': 'normal',
      'summary_md': 'capsule package',
      'repo': {'name': 'cc-collaboration', 'branch': 'main'},
      'attachments': <Map<String, dynamic>>[
        {
          'name': 'persona.md',
          'sha256': sha256.convert(persona).toString(),
          'size': persona.length,
        },
      ],
    });
  }

  @override
  Future<List<int>> attachment(
    String id,
    String name, {
    String? expectedSha256,
    int? expectedSize,
  }) async {
    if (name == 'persona.md') return utf8.encode('persona body');
    throw Exception('missing attachment');
  }

  @override
  Future<void> patchCapsule(
    String id, {
    String? visibility,
    String? summary,
    String? orgId,
    String? projectId,
  }) {
    final completer = Completer<void>();
    _patches.add(completer);
    return completer.future;
  }

  void completeNext(List<CapsuleListItem> items) {
    final request = _requests.firstWhere((c) => !c.isCompleted);
    request.complete(items);
  }

  void completeLatest(List<CapsuleListItem> items) {
    final request = _requests.lastWhere((c) => !c.isCompleted);
    request.complete(items);
  }

  void completePatch() {
    final request = _patches.firstWhere((c) => !c.isCompleted);
    request.complete();
  }
}

class _ProjectCapsulesClient extends _DelayedCapsulesClient {
  @override
  Future<List<CapsuleListItem>> capsules() async => [
    _capsule(
      'bound-missing',
      headline: 'Bound missing',
      projectId: 'relay-project',
      hasTranscript: false,
      hasPersona: true,
    ),
  ];

  @override
  Future<ProjectDetail> project(String id) async => ProjectDetail.fromJson({
    'project': {
      'id': id,
      'org_id': 'org-team',
      'name': 'Relay project',
      'owner_identity': 'me@x',
      'role': 'member',
    },
    'repo_bindings': [
      {
        'repo_name': 'cc-collaboration',
        'clone_url': 'https://github.com/example/cc-collaboration.git',
      },
    ],
    'members': const [],
    'invitations': const [],
  });
}

CapsuleListItem _capsule(
  String id, {
  required String headline,
  String owner = 'me@x',
  String visibility = 'public',
  String sourceAgent = 'codex',
  String repoName = 'cc-collaboration',
  String? summary,
  bool hasTranscript = true,
  bool hasPersona = false,
  int skillPackCount = 0,
  String orgId = '',
  String projectId = '',
}) => CapsuleListItem.fromJson({
  'id': id,
  'owner': owner,
  'visibility': visibility,
  'source_agent': sourceAgent,
  'origin_session_id': 's-$id',
  'org_id': orgId,
  'project_id': projectId,
  'headline': headline,
  'summary': summary ?? headline,
  'repo_name': repoName,
  'has_transcript': hasTranscript,
  'has_persona': hasPersona,
  'skill_pack_count': skillPackCount,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-02T00:00:00Z',
});
