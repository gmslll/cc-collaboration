import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/api/models.dart';
import 'package:app/api/relay_client.dart';
import 'package:app/local/config.dart';
import 'package:app/local/session_overview.dart';
import 'package:app/screens/capsule_plaza_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('capsule load target menus are width constrained', () {
    final source = File(
      'lib/screens/capsule_plaza_page.dart',
    ).readAsStringSync();
    final loadDialog = source.substring(
      source.indexOf('class _CapsuleLoadDialogState'),
      source.indexOf('// bundledSkillNames lists'),
    );

    expect(loadDialog, contains('menuMaxHeight: 320'));
    expect(
      loadDialog,
      isNot(
        contains(
          'DropdownMenuItem(value: x.name as String, child: Text(x.name as String))',
        ),
      ),
    );
    expect(loadDialog, contains('x.name as String,\n          maxLines: 1'));
    expect(loadDialog, contains('overflow: TextOverflow.ellipsis'));
  });

  test('capsule plaza describes public visibility as team shared', () {
    final source = File(
      'lib/screens/capsule_plaza_page.dart',
    ).readAsStringSync();

    expect(source, contains('团队共享'));
    expect(source, contains('同团队成员能在广场看到'));
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
    expect(loadDialog, contains('if (!mounted || !widget.isCurrentContext())'));
    expect(editDialog, contains('required this.isCurrentContext'));
    expect(editDialog, contains('if (!mounted || !widget.isCurrentContext())'));
  });

  test('capsule load forwards selected relay project id to local spawn', () {
    final source = File(
      'lib/screens/capsule_plaza_page.dart',
    ).readAsStringSync();
    final loadDialog = source.substring(
      source.indexOf('class _CapsuleLoadDialogState'),
      source.indexOf('// bundledSkillNames lists'),
    );

    expect(loadDialog, contains('projectId: _selectedProject?.projectId'));
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

    await tester.tap(find.byTooltip('刷新'));
    await tester.pump();
    expect(client.requestCount, 2);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
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

    await tester.tap(find.widgetWithText(TextButton, '删除'));
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

    await tester.tap(find.widgetWithText(TextButton, '编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Old edited capsule');
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

      await tester.tap(find.widgetWithText(OutlinedButton, '载入'));
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

  final deletedIds = <String>[];

  @override
  Future<void> deleteCapsule(String id) async {
    deletedIds.add(id);
  }

  @override
  Future<Package> get(String id) async => Package.fromJson({
    'id': id,
    'kind': 'capsule',
    'sender': 'owner@x',
    'recipient': 'viewer@x',
    'urgency': 'normal',
    'summary_md': 'capsule package',
    'repo': {'name': 'cc-collaboration', 'branch': 'main'},
    'attachments': <Map<String, dynamic>>[],
  });

  @override
  Future<List<int>> attachment(String id, String name) async {
    if (name == 'persona.md') return utf8.encode('persona body');
    throw Exception('missing attachment');
  }

  @override
  Future<void> patchCapsule(String id, {String? visibility, String? summary}) {
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

CapsuleListItem _capsule(
  String id, {
  required String headline,
  String owner = 'me@x',
  bool hasTranscript = true,
  bool hasPersona = false,
}) => CapsuleListItem.fromJson({
  'id': id,
  'owner': owner,
  'visibility': 'public',
  'source_agent': 'codex',
  'origin_session_id': 's-$id',
  'headline': headline,
  'repo_name': 'cc-collaboration',
  'has_transcript': hasTranscript,
  'has_persona': hasPersona,
  'created_at': '2026-01-01T00:00:00Z',
});
