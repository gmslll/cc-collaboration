import 'dart:async';
import 'dart:io';

import 'package:app/api/models.dart';
import 'package:app/api/relay_client.dart';
import 'package:app/local/config.dart';
import 'package:app/screens/handoff_detail_view.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('handoff reassign candidates follow project and team scope', () {
    final package = _package(
      'team-bug',
      'qa@x',
      'team bug',
      kind: 'bug',
      deliveryTarget: const {'project_id': 'proj1', 'org_id': 'org1'},
    );
    final candidates = handoffReassignCandidates(
      package: package,
      currentIdentity: 'dev@x',
      project: _projectDetail('proj1', 'org1'),
      organization: _organizationDetail('org1'),
    );

    expect(candidates, [
      (identity: 'owner@x', label: 'owner@x'),
      (identity: 'ops@x', label: 'Ops · ops@x'),
      (identity: 'admin@x', label: 'Admin · admin@x'),
    ]);
  });

  test('handoff reassign target validation follows loaded candidates', () {
    final candidates = [
      (identity: 'ops@x', label: 'Ops · ops@x'),
      (identity: 'Admin@X', label: 'Admin · Admin@X'),
    ];

    expect(handoffReassignTargetAllowed(' OPS@X ', candidates), isTrue);
    expect(handoffReassignTargetAllowed('admin@x', candidates), isTrue);
    expect(handoffReassignTargetAllowed('outsider@x', candidates), isFalse);
    expect(handoffReassignTargetAllowed('outsider@x', const []), isTrue);
  });

  test('handoff reassign candidate list height is responsive', () {
    expect(handoffReassignCandidateListMaxHeight(const Size(1024, 900)), 112);
    expect(
      handoffReassignCandidateListMaxHeight(const Size(320, 420)),
      closeTo(109.2, 0.001),
    );
    expect(handoffReassignCandidateListMaxHeight(const Size(320, 220)), 88);
  });

  test('handoff action dialog width fits compact screens', () {
    expect(handoffActionDialogWidth(const Size(320, 760)), 288);
    expect(handoffActionDialogWidth(const Size(1024, 760)), 440);
    expect(handoffActionDialogWidth(const Size(360, 760), preferred: 460), 328);
  });

  test('handoff reassign dialog avoids fixed candidate height', () {
    final source = File(
      'lib/screens/handoff_detail_view.dart',
    ).readAsStringSync();
    final dialog = source.substring(source.indexOf('class _ReassignDialog'));

    expect(dialog, contains('handoffReassignCandidateListMaxHeight'));
    expect(dialog, contains('handoffActionDialogWidth'));
    expect(dialog, contains('SingleChildScrollView'));
    expect(dialog, isNot(contains('BoxConstraints(maxHeight: 112)')));
  });

  test('handoff init dialog uses responsive content', () {
    final source = File(
      'lib/screens/handoff_detail_view.dart',
    ).readAsStringSync();
    final dialog = source.substring(
      source.indexOf('Future<bool> _confirmInit('),
      source.indexOf('Future<void> _retract('),
    );

    expect(dialog, contains('handoffActionDialogWidth(size)'));
    expect(dialog, contains('insetPadding: const EdgeInsets.symmetric'));
    expect(dialog, contains('SingleChildScrollView'));
    expect(dialog, contains('maxLines: 2'));
    expect(dialog, contains('overflow: TextOverflow.ellipsis'));
    expect(dialog, contains('partner ='));
    expect(dialog, contains('path,'));
    expect(dialog, isNot(contains('content: Text(')));
  });

  test('handoff file tab dynamic labels are width constrained', () {
    final source = File(
      'lib/screens/handoff_detail_view.dart',
    ).readAsStringSync();
    final fileTab = source.substring(
      source.indexOf('Widget _tabFiles('),
      source.indexOf('Widget _filesHeader('),
    );
    final fileRow = source.substring(
      source.indexOf('Widget _fileRow('),
      source.indexOf('Widget _commentsSection('),
    );

    expect(fileTab, isNot(contains('title: Text(a.name),')));
    expect(
      fileTab,
      contains(
        'title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis)',
      ),
    );
    expect(fileTab, contains('overflow: TextOverflow.ellipsis'));
    expect(fileRow, contains('s,\n            maxLines: 1'));
    expect(fileRow, contains('overflow: TextOverflow.ellipsis'));
  });

  test('handoff attachment download path flattens nested unsafe names', () {
    expect(
      handoffAttachmentTempPath('/tmp/cc', 'logs/a #1.txt'),
      '/tmp/cc/logs_a #1.txt',
    );
    expect(
      handoffAttachmentTempPath('/tmp/cc/', '../secrets/../../token?.txt'),
      '/tmp/cc/secrets_token_.txt',
    );
    expect(
      handoffAttachmentTempPath('/tmp/cc', ' ../.. '),
      '/tmp/cc/attachment',
    );
  });

  testWidgets('stale handoff detail load cannot overwrite a newer handoff', (
    tester,
  ) async {
    final client = _DelayedDetailClient();
    final first = _item('h1', 'alice@x', 'first handoff');
    final second = _item('h2', 'bob@x', 'second handoff');

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
          item: first,
        ),
      ),
    );
    await tester.pump();
    expect(client.requestedPackages, ['h1']);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
          item: second,
        ),
      ),
    );
    await tester.pump();
    expect(client.requestedPackages, ['h1', 'h2']);

    client.completePackage('h2', _package('h2', 'bob@x', 'second handoff'));
    await tester.pumpAndSettle();
    expect(find.text('bob@x → me@x'), findsOneWidget);
    expect(find.text('alice@x → me@x'), findsNothing);

    client.completePackage('h1', _package('h1', 'alice@x', 'first handoff'));
    await tester.pumpAndSettle();
    expect(find.text('bob@x → me@x'), findsOneWidget);
    expect(find.text('alice@x → me@x'), findsNothing);
  });

  testWidgets('handoff detail account switch ignores stale same-id load', (
    tester,
  ) async {
    final oldClient = _DelayedDetailClient();
    final newClient = _DelayedDetailClient();
    final item = _item('same-handoff', 'sender@x', 'same handoff');

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: oldClient,
          config: AppConfig(
            'http://127.0.0.1:1',
            'old-token',
            'old@x',
            const {},
          ),
          item: item,
        ),
      ),
    );
    await tester.pump();
    expect(oldClient.requestedPackages, ['same-handoff']);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: newClient,
          config: AppConfig(
            'http://127.0.0.1:1',
            'new-token',
            'new@x',
            const {},
          ),
          item: item,
        ),
      ),
    );
    await tester.pump();
    expect(newClient.requestedPackages, ['same-handoff']);

    newClient.completePackage(
      'same-handoff',
      _package('same-handoff', 'new-sender@x', 'new account handoff'),
    );
    await tester.pumpAndSettle();
    expect(find.text('new-sender@x → me@x'), findsOneWidget);
    expect(find.text('old-sender@x → me@x'), findsNothing);

    oldClient.completePackage(
      'same-handoff',
      _package('same-handoff', 'old-sender@x', 'old account handoff'),
    );
    await tester.pumpAndSettle();
    expect(find.text('new-sender@x → me@x'), findsOneWidget);
    expect(find.text('old-sender@x → me@x'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('handoff retract dialog cancel closes cleanly', (tester) async {
    final client = _ActionDetailClient(
      _package('h1', ' Me@X ', 'owned handoff'),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
          item: _item('h1', ' Me@X ', 'owned handoff'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '撤回'));
    await tester.pumpAndSettle();

    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    final contentScroll = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SingleChildScrollView),
      ),
    );

    expect(
      dialog.insetPadding,
      const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    );
    expect(contentScroll.scrollDirection, Axis.vertical);

    await tester.enterText(find.byType(TextField), '  not now  ');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(client.retractCalls, 0);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('handoff retract disables button while dialog is open', (
    tester,
  ) async {
    final client = _ActionDetailClient(
      _package('h1', ' Me@X ', 'owned handoff'),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
          item: _item('h1', ' Me@X ', 'owned handoff'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '撤回'));
    await tester.pumpAndSettle();

    final lockedButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '撤回'),
    );
    expect(lockedButton.onPressed, isNull);
    expect(find.widgetWithText(OutlinedButton, '撤回中…'), findsNothing);
    expect(find.text('撤回 handoff'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(client.retractCalls, 0);
    expect(find.widgetWithText(OutlinedButton, '撤回'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('handoff reassign dialog submits trimmed values', (tester) async {
    final client = _ActionDetailClient(
      _package('bug1', 'qa@x', 'bug handoff', kind: 'bug'),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
          item: _item('bug1', 'qa@x', 'bug handoff'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '转交'));
    await tester.pumpAndSettle();

    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    final contentScroll = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SingleChildScrollView),
      ),
    );

    expect(
      dialog.insetPadding,
      const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    );
    expect(contentScroll.scrollDirection, Axis.vertical);

    await tester.enterText(
      find.widgetWithText(TextField, '转交给(identity)'),
      '  dev@x  ',
    );
    await tester.enterText(find.widgetWithText(TextField, '原因'), '  fix it  ');
    await tester.tap(find.widgetWithText(FilledButton, '转交'));
    await tester.pumpAndSettle();

    expect(client.reassignedTo, 'dev@x');
    expect(client.reassignedReason, 'fix it');
    expect(find.byType(TextField), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('handoff reassign dialog keeps input when fields are missing', (
    tester,
  ) async {
    final client = _ActionDetailClient(
      _package('bug1', 'qa@x', 'bug handoff', kind: 'bug'),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
          item: _item('bug1', 'qa@x', 'bug handoff'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '转交'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '转交给(identity)'),
      '  dev@x  ',
    );
    await tester.tap(find.widgetWithText(FilledButton, '转交'));
    await tester.pumpAndSettle();

    expect(client.reassignedTo, isNull);
    expect(find.text('需填转交对象和原因'), findsOneWidget);
    expect(find.widgetWithText(TextField, '转交给(identity)'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '原因'), '  fix it  ');
    await tester.tap(find.widgetWithText(FilledButton, '转交'));
    await tester.pumpAndSettle();

    expect(client.reassignedTo, 'dev@x');
    expect(client.reassignedReason, 'fix it');
    expect(find.byType(TextField), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('handoff reassign dialog can pick a team member candidate', (
    tester,
  ) async {
    final client = _ActionDetailClient(
      _package(
        'team-bug',
        'qa@x',
        'team bug',
        kind: 'bug',
        deliveryTarget: const {'project_id': 'proj1', 'org_id': 'org1'},
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
          item: _item('team-bug', 'qa@x', 'team bug'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '转交'));
    await tester.pumpAndSettle();

    expect(find.text('团队候选'), findsOneWidget);
    await tester.tap(find.text('Ops · ops@x'));
    await tester.enterText(find.widgetWithText(TextField, '原因'), '  fix it  ');
    await tester.tap(find.widgetWithText(FilledButton, '转交'));
    await tester.pumpAndSettle();

    expect(client.reassignedTo, 'ops@x');
    expect(client.reassignedReason, 'fix it');
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('handoff reassign ignores duplicate taps while loading team', (
    tester,
  ) async {
    final client = _ActionDetailClient(
      _package(
        'team-bug-once',
        'qa@x',
        'team bug',
        kind: 'bug',
        deliveryTarget: const {'project_id': 'proj1', 'org_id': 'org1'},
      ),
      delayProject: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
          item: _item('team-bug-once', 'qa@x', 'team bug'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '转交'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, '准备转交…'));
    await tester.pump();

    expect(client.projectCalls, 1);
    expect(find.widgetWithText(OutlinedButton, '准备转交…'), findsOneWidget);

    client.completeProject('proj1');
    await tester.pumpAndSettle();

    expect(client.projectCalls, 1);
    expect(find.text('团队候选'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, '转交'), findsOneWidget);
  });

  testWidgets('handoff reassign dialog rejects non-candidate team identities', (
    tester,
  ) async {
    final client = _ActionDetailClient(
      _package(
        'team-bug',
        'qa@x',
        'team bug',
        kind: 'bug',
        deliveryTarget: const {'project_id': 'proj1', 'org_id': 'org1'},
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
          item: _item('team-bug', 'qa@x', 'team bug'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '转交'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '转交给(identity)'),
      'outsider@x',
    );
    await tester.enterText(find.widgetWithText(TextField, '原因'), 'fix it');
    await tester.tap(find.widgetWithText(FilledButton, '转交'));
    await tester.pumpAndSettle();

    expect(client.reassignedTo, isNull);
    expect(find.text('请选择团队候选，或输入候选里的成员 identity'), findsOneWidget);
    expect(find.widgetWithText(TextField, '转交给(identity)'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, '转交给(identity)'),
      'ADMIN@X',
    );
    await tester.tap(find.widgetWithText(FilledButton, '转交'));
    await tester.pumpAndSettle();

    expect(client.reassignedTo, 'ADMIN@X');
    expect(client.reassignedReason, 'fix it');
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  test('pickup init and terminal launch guard host context', () {
    final source = File(
      'lib/screens/handoff_detail_view.dart',
    ).readAsStringSync();
    final pickup = source.substring(
      source.indexOf('Future<void> _pickup('),
      source.indexOf('// _confirmInit prompts'),
    );
    final confirmInit = source.substring(
      source.indexOf('Future<bool> _confirmInit('),
      source.indexOf('Future<void> _retract('),
    );

    expect(pickup, contains('final generation = _loadGeneration;'));
    expect(pickup, contains('final client = _client;'));
    expect(
      pickup,
      contains(
        'if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity))',
      ),
    );
    expect(
      pickup.indexOf(
        'if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity))',
      ),
      lessThan(pickup.indexOf('setState(() => _picking = true)')),
    );
    expect(
      pickup.indexOf(
        'if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity))',
        pickup.indexOf('final r = await Cli.pickup'),
      ),
      lessThan(pickup.indexOf('widget.onOpenTerminal')),
    );
    expect(confirmInit, contains('final generation = _loadGeneration;'));
    expect(
      confirmInit.indexOf(
        'if (!_isCurrentLoad(generation, client, id, relayUrl, token, identity))',
      ),
      lessThan(confirmInit.indexOf('RepoConfig(')),
    );
  });

  testWidgets('team handoff detail shows fanout recipients and pickup slots', (
    tester,
  ) async {
    final client = _ActionDetailClient(
      _package(
        'team1',
        'qa@x',
        'team handoff',
        recipients: const ['dev@x', 'ops@x'],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
          item: _item('team1', 'qa@x', 'team handoff'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('qa@x → 2 人'), findsOneWidget);
    expect(find.text('团队接收状态'), findsOneWidget);
    expect(find.text('dev@x · picked'), findsOneWidget);
    expect(find.text('ops@x · pending'), findsOneWidget);
    expect(find.text('qa@x → me@x'), findsNothing);
  });

  testWidgets('team handoff detail hides receive actions for non-recipient', (
    tester,
  ) async {
    final client = _ActionDetailClient(
      _package(
        'team-readonly',
        'qa@x',
        'team handoff',
        kind: 'bug',
        recipients: const ['dev@x', 'ops@x'],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'viewer@x', const {}),
          item: _item('team-readonly', 'qa@x', 'team handoff'),
          onOpenTerminal: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('qa@x → 2 人'), findsOneWidget);
    expect(find.text('团队接收状态'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '接收并开终端'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '标记接收'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '转交'), findsNothing);
    await tester.tap(find.text('评论'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '写评论…'), findsNothing);
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, '复制 pickup 命令'), findsNothing);
  });

  testWidgets('team handoff detail keeps receive actions for slot recipient', (
    tester,
  ) async {
    final client = _ActionDetailClient(
      _package(
        'team-recipient',
        'qa@x',
        'team handoff',
        kind: 'bug',
        recipients: const ['dev@x', 'ops@x'],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'dev@x', const {}),
          item: _item('team-recipient', 'qa@x', 'team handoff'),
          onOpenTerminal: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, '接收并开终端'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '标记接收'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '转交'), findsOneWidget);
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, '复制 pickup 命令'), findsOneWidget);
  });

  testWidgets('project member can comment on team handoff without receiving', (
    tester,
  ) async {
    final client = _ActionDetailClient(
      _package(
        'team-comment',
        'qa@x',
        'team handoff',
        recipients: const ['dev@x'],
        deliveryTarget: const {'project_id': 'proj1', 'org_id': 'org1'},
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'member@x', const {}),
          me: _me(
            'member@x',
            projects: const [
              {
                'id': 'proj1',
                'org_id': 'org1',
                'name': 'svc',
                'role': 'member',
              },
            ],
          ),
          item: _item('team-comment', 'qa@x', 'team handoff'),
          onOpenTerminal: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, '接收并开终端'), findsNothing);
    await tester.tap(find.text('评论'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '写评论…'), findsOneWidget);
  });

  testWidgets('handoff comments clamp long team member identities', (
    tester,
  ) async {
    final client = _ActionDetailClient(
      _package('long-commenter', 'qa@x', 'team handoff'),
      comments: [
        _comment(
          'very-long-team-member-identity-that-would-overflow@example.com',
          'comment body',
        ),
      ],
    );

    await tester.binding.setSurfaceSize(const Size(220, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
          item: _item('long-commenter', 'qa@x', 'team handoff'),
          onOpenTerminal: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(TabBarView), const Offset(-220, 0));
      await tester.pumpAndSettle();
    }

    expect(find.text('comment body'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('handoff comment submit ignores duplicate taps while posting', (
    tester,
  ) async {
    final client = _ActionDetailClient(
      _package('comment-once', 'qa@x', 'team handoff'),
      delayPostComment: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
          item: _item('comment-once', 'qa@x', 'team handoff'),
          onOpenTerminal: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('评论'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ship it');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    await tester.tap(find.byType(IconButton).last);
    await tester.pump();

    expect(client.postedComments, ['comment-once:ship it']);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    client.completePost('comment-once', 'ship it');
    await tester.pumpAndSettle();

    expect(client.postedComments, ['comment-once:ship it']);
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
  });

  testWidgets('handoff ack ignores duplicate taps while posting', (
    tester,
  ) async {
    final client = _ActionDetailClient(
      _package('ack-once', 'qa@x', 'team handoff'),
      delayAck: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
          item: _item('ack-once', 'qa@x', 'team handoff'),
          onOpenTerminal: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '标记接收'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, '标记中…'));
    await tester.pump();

    expect(client.ackCalls, 1);
    expect(find.widgetWithText(OutlinedButton, '标记中…'), findsOneWidget);

    client.completeAck('ack-once');
    await tester.pumpAndSettle();

    expect(client.ackCalls, 1);
    expect(find.widgetWithText(OutlinedButton, '标记接收'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}

ListItem _item(String id, String sender, String headline) => ListItem.fromJson({
  'id': id,
  'kind': 'delivery',
  'sender': sender,
  'recipient': 'me@x',
  'urgency': 'normal',
  'state': 'pending',
  'repo_name': 'repo',
  'headline': headline,
  'created_at': '2026-01-01T00:00:00Z',
});

Package _package(
  String id,
  String sender,
  String summary, {
  String kind = 'delivery',
  List<String> recipients = const [],
  Map<String, dynamic>? deliveryTarget,
}) {
  final json = <String, dynamic>{
    'id': id,
    'kind': kind,
    'sender': sender,
    'recipient': 'me@x',
    if (recipients.isNotEmpty) 'recipients': recipients,
    'urgency': 'normal',
    'summary_md': summary,
    'repo': {'name': 'repo', 'branch': 'main'},
    'attachments': <Map<String, dynamic>>[],
  };
  if (deliveryTarget != null) {
    json['delivery_target'] = deliveryTarget;
  }
  return Package.fromJson(json);
}

ProjectDetail _projectDetail(String id, String orgId) =>
    ProjectDetail.fromJson({
      'project': {
        'id': id,
        'org_id': orgId,
        'name': 'svc',
        'owner_identity': 'owner@x',
        'role': 'member',
      },
      'members': [
        {'identity': 'dev@x', 'role': 'member', 'display_name': 'Dev'},
        {'identity': 'ops@x', 'role': 'member', 'display_name': 'Ops'},
      ],
    });

OrganizationDetail _organizationDetail(String id) =>
    OrganizationDetail.fromJson({
      'organization': {
        'id': id,
        'name': 'Team',
        'owner_identity': 'owner@x',
        'role': 'member',
      },
      'members': [
        {'identity': 'owner@x', 'role': 'owner', 'display_name': 'Owner'},
        {'identity': 'admin@x', 'role': 'admin', 'display_name': 'Admin'},
        {'identity': 'team-member@x', 'role': 'member', 'display_name': 'Team'},
      ],
      'projects': const [],
    });

Comment _comment(String sender, String body) => Comment.fromJson({
  'sender': sender,
  'body': body,
  'created_at': '2026-01-01T00:00:00Z',
});

Me _me(
  String identity, {
  bool isAdmin = false,
  List<Map<String, dynamic>> projects = const [],
}) => Me.fromJson({
  'identity': identity,
  'is_admin': isAdmin,
  'projects': projects,
});

class _DelayedDetailClient extends RelayClient {
  _DelayedDetailClient() : super('http://127.0.0.1', 'tok');

  final requestedPackages = <String>[];
  final _packages = <String, Completer<Package>>{};

  @override
  Future<Package> get(String id) {
    requestedPackages.add(id);
    final completer = Completer<Package>();
    _packages[id] = completer;
    return completer.future;
  }

  @override
  Future<List<Comment>> comments(String id) async => const [];

  @override
  Future<String> prompt(String id) async => 'prompt for $id';

  @override
  Future<Status> status(String id) async => Status.fromJson({
    'state': 'pending',
    'sender': 'sender@$id',
    'recipient': 'me@x',
    'created_at': '2026-01-01T00:00:00Z',
    'comment_count': 0,
  });

  void completePackage(String id, Package package) {
    _packages[id]!.complete(package);
  }
}

class _ActionDetailClient extends RelayClient {
  final Package package;
  final bool delayPostComment;
  final bool delayAck;
  final bool delayProject;
  final List<Comment> commentItems;
  int ackCalls = 0;
  int projectCalls = 0;
  int retractCalls = 0;
  String? retractReason;
  String? reassignedTo;
  String? reassignedReason;
  final postedComments = <String>[];
  final _posts = <String, Completer<Comment>>{};
  final _acks = <String, Completer<void>>{};
  final _projects = <String, Completer<ProjectDetail>>{};

  _ActionDetailClient(
    this.package, {
    this.delayPostComment = false,
    this.delayAck = false,
    this.delayProject = false,
    List<Comment> comments = const [],
  }) : commentItems = comments,
       super('http://127.0.0.1', 'tok');

  @override
  Future<Package> get(String id) async => package;

  @override
  Future<List<Comment>> comments(String id) async => commentItems;

  @override
  Future<String> prompt(String id) async => 'prompt for $id';

  @override
  Future<Status> status(String id) async => Status.fromJson({
    'state': 'pending',
    'sender': package.sender,
    'recipient': 'me@x',
    if (package.recipients.isNotEmpty) 'recipients': package.recipients,
    if (package.recipients.isNotEmpty)
      'pickup_by': {
        package.recipients.first: {
          'state': 'picked',
          'picked_at': '2026-01-01T00:01:00Z',
        },
        for (final r in package.recipients.skip(1)) r: {'state': 'pending'},
      },
    'created_at': '2026-01-01T00:00:00Z',
    'comment_count': 0,
  });

  @override
  Future<ProjectDetail> project(String id) {
    projectCalls++;
    if (!delayProject) return Future.value(_projectDetail(id, 'org1'));
    final completer = Completer<ProjectDetail>();
    _projects[id] = completer;
    return completer.future;
  }

  void completeProject(String id) {
    _projects[id]!.complete(_projectDetail(id, 'org1'));
  }

  @override
  Future<OrganizationDetail> organization(String id) async =>
      _organizationDetail(id);

  @override
  Future<void> ack(String id) {
    ackCalls++;
    if (!delayAck) return Future.value();
    final completer = Completer<void>();
    _acks[id] = completer;
    return completer.future;
  }

  void completeAck(String id) {
    _acks[id]!.complete();
  }

  @override
  Future<void> retract(String id, String reason) async {
    retractCalls++;
    retractReason = reason;
  }

  @override
  Future<void> reassign(String id, String to, String reason) async {
    reassignedTo = to;
    reassignedReason = reason;
  }

  @override
  Future<Comment> postComment(String id, String body) {
    postedComments.add('$id:$body');
    if (!delayPostComment) return Future.value(_comment('me@x', body));
    final completer = Completer<Comment>();
    _posts['$id:$body'] = completer;
    return completer.future;
  }

  void completePost(String id, String body) {
    _posts['$id:$body']!.complete(_comment('me@x', body));
  }
}
