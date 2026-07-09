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
    await tester.enterText(find.byType(TextField), '  not now  ');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(client.retractCalls, 0);
    expect(find.byType(TextField), findsNothing);
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
  int retractCalls = 0;
  String? retractReason;
  String? reassignedTo;
  String? reassignedReason;

  _ActionDetailClient(this.package) : super('http://127.0.0.1', 'tok');

  @override
  Future<Package> get(String id) async => package;

  @override
  Future<List<Comment>> comments(String id) async => const [];

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
  Future<void> retract(String id, String reason) async {
    retractCalls++;
    retractReason = reason;
  }

  @override
  Future<void> reassign(String id, String to, String reason) async {
    reassignedTo = to;
    reassignedReason = reason;
  }
}
