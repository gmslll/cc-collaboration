import 'dart:async';
import 'dart:io';

import 'package:app/api/models.dart';
import 'package:app/api/relay_client.dart';
import 'package:app/local/config.dart';
import 'package:app/screens/handoffs_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'handoff refresh selection keeps fresh item and clears removed item',
    () {
      final old = _handoff('h1', headline: 'Old handoff');
      final fresh = _handoff('h1', headline: 'Fresh handoff');
      final other = _handoff('h2', headline: 'Other handoff');

      expect(refreshedSelectedHandoff(null, [fresh]), isNull);
      expect(refreshedSelectedHandoff(old, [other, fresh]), same(fresh));
      expect(refreshedSelectedHandoff(old, [other]), isNull);
    },
  );

  test('handoff online roster height is responsive', () {
    expect(handoffOnlineRosterMaxHeight(const Size(1200, 900)), 130);
    expect(
      handoffOnlineRosterMaxHeight(const Size(320, 420)),
      closeTo(92.4, 0.001),
    );
    expect(handoffOnlineRosterMaxHeight(const Size(320, 260)), 82);
  });

  test('handoff online roster avoids fixed height', () {
    final source = File('lib/screens/handoffs_page.dart').readAsStringSync();
    final roster = source.substring(source.indexOf('Widget _onlineRoster'));

    expect(roster, contains('handoffOnlineRosterMaxHeight'));
    expect(roster, isNot(contains('BoxConstraints(maxHeight: 130)')));
  });

  testWidgets('handoff refresh completion after unmount is ignored', (
    tester,
  ) async {
    final client = _DelayedHandoffsClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: HandoffsPage(
            client: client,
            config: AppConfig('http://127.0.0.1:1', 'tok', 'dev@x', const {}),
            showTerminal: false,
            enableEvents: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(client.handoffsStarted, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    client.completeHandoffs(const []);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('selected handoff row renders without ListTile assertion', (
    tester,
  ) async {
    final client = _ImmediateHandoffsClient([_handoff('h1')]);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: HandoffsPage(
            client: client,
            config: AppConfig('http://127.0.0.1:1', 'tok', 'dev@x', const {}),
            showTerminal: false,
            enableEvents: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('sender@x'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Review the workspace handoff'), findsWidgets);
  });

  testWidgets('stale handoff list refresh cannot overwrite selected view', (
    tester,
  ) async {
    final client = _ViewDelayedHandoffsClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: HandoffsPage(
            client: client,
            config: AppConfig('http://127.0.0.1:1', 'tok', 'dev@x', const {}),
            showTerminal: false,
            enableEvents: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(client.startedViews, contains('recipient'));

    await tester.tap(find.text('已发'));
    await tester.pump();
    expect(client.startedViews, contains('sender'));

    client.complete('sender', [
      _handoff('sent', sender: 'me@x', headline: 'Sent handoff'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('me@x'), findsOneWidget);
    expect(find.text('old@x'), findsNothing);

    client.complete('recipient', [
      _handoff('old', sender: 'old@x', headline: 'Old inbox handoff'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('me@x'), findsOneWidget);
    expect(find.text('old@x'), findsNothing);
  });

  testWidgets('empty inbox shows actionable empty state', (tester) async {
    final client = _ImmediateHandoffsClient(const []);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: HandoffsPage(
            client: client,
            config: AppConfig('http://127.0.0.1:1', 'tok', 'dev@x', const {}),
            showTerminal: false,
            enableEvents: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('任务队列为空'), findsOneWidget);
    expect(find.text('收到新的协作交接后会自动刷新。'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '刷新'), findsOneWidget);
  });

  testWidgets('empty team handoff view explains project sharing', (
    tester,
  ) async {
    final client = _ViewDelayedHandoffsClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: HandoffsPage(
            client: client,
            config: AppConfig('http://127.0.0.1:1', 'tok', 'dev@x', const {}),
            showTerminal: false,
            enableEvents: false,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('团队'));
    await tester.pump();
    client.complete('project', const []);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('还没有团队协作任务'), findsOneWidget);
    expect(find.text('项目成员共享的协作任务会出现在这里。'), findsOneWidget);
  });

  testWidgets('team handoff view lists project-shared handoffs', (
    tester,
  ) async {
    final client = _ViewDelayedHandoffsClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: HandoffsPage(
            client: client,
            config: AppConfig('http://127.0.0.1:1', 'tok', 'dev@x', const {}),
            showTerminal: false,
            enableEvents: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(client.startedViews, contains('recipient'));

    await tester.tap(find.text('团队'));
    await tester.pump();
    expect(client.startedViews, contains('project'));

    client.complete('project', [
      _handoff('team', sender: 'lead@x', headline: 'Team project handoff'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('lead@x'), findsOneWidget);
    expect(find.text('Team project handoff'), findsOneWidget);

    client.complete('recipient', [
      _handoff('old', sender: 'old@x', headline: 'Old inbox handoff'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('lead@x'), findsOneWidget);
    expect(find.text('old@x'), findsNothing);
  });

  testWidgets('handoff account switch ignores stale list and online users', (
    tester,
  ) async {
    final oldClient = _SwitchDelayedHandoffsClient();
    final newClient = _SwitchDelayedHandoffsClient();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: HandoffsPage(
            client: oldClient,
            config: AppConfig('http://127.0.0.1:1', 'old', 'old@x', const {}),
            showTerminal: false,
            enableEvents: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(oldClient.handoffsStarted, isTrue);
    expect(oldClient.onlineStarted, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: HandoffsPage(
            client: newClient,
            config: AppConfig('http://127.0.0.1:1', 'new', 'new@x', const {}),
            showTerminal: false,
            enableEvents: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(newClient.handoffsStarted, isTrue);
    expect(newClient.onlineStarted, isTrue);

    newClient.completeHandoffs([
      _handoff('new', sender: 'new-sender@x', headline: 'New inbox handoff'),
    ]);
    newClient.completeOnline(['new-online@x']);
    await tester.pumpAndSettle();
    expect(find.text('new-sender@x'), findsOneWidget);
    expect(find.text('new-online@x'), findsOneWidget);

    oldClient.completeHandoffs([
      _handoff('old', sender: 'old-sender@x', headline: 'Old inbox handoff'),
    ]);
    oldClient.completeOnline(['old-online@x']);
    await tester.pumpAndSettle();

    expect(find.text('new-sender@x'), findsOneWidget);
    expect(find.text('new-online@x'), findsOneWidget);
    expect(find.text('old-sender@x'), findsNothing);
    expect(find.text('old-online@x'), findsNothing);
  });

  testWidgets('handoff list search matches team recipients', (tester) async {
    final client = _ImmediateHandoffsClient([
      _handoff(
        'team',
        sender: 'sender@x',
        headline: 'Team handoff',
        recipients: const ['dev@x', 'ops@x'],
      ),
      _handoff('solo', sender: 'other@x', headline: 'Solo handoff'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: HandoffsPage(
            client: client,
            config: AppConfig('http://127.0.0.1:1', 'tok', 'dev@x', const {}),
            showTerminal: false,
            enableEvents: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ops@x');
    await tester.pump();

    expect(find.text('Team handoff'), findsOneWidget);
    expect(find.text('Solo handoff'), findsNothing);

    await tester.enterText(find.byType(TextField), 'missing-recipient');
    await tester.pump();

    expect(find.text('没有匹配结果'), findsOneWidget);
    expect(find.text('换一个关键词或清空搜索后再看。'), findsOneWidget);
  });
}

class _DelayedHandoffsClient extends RelayClient {
  _DelayedHandoffsClient() : super('http://127.0.0.1', 'tok');

  final _handoffsCompleter = Completer<List<ListItem>>();
  bool handoffsStarted = false;

  @override
  Future<List<ListItem>> handoffs({String as = 'recipient'}) {
    handoffsStarted = true;
    return _handoffsCompleter.future;
  }

  @override
  Future<List<OnlineUser>> onlineUsers() async => const [];

  void completeHandoffs(List<ListItem> items) {
    if (!_handoffsCompleter.isCompleted) {
      _handoffsCompleter.complete(items);
    }
  }
}

class _ImmediateHandoffsClient extends RelayClient {
  final List<ListItem> items;

  _ImmediateHandoffsClient(this.items) : super('http://127.0.0.1', 'tok');

  @override
  Future<List<ListItem>> handoffs({String as = 'recipient'}) async => items;

  @override
  Future<List<OnlineUser>> onlineUsers() async => const [];

  @override
  Future<Package> get(String id) async => Package.fromJson({
    'id': id,
    'sender': 'sender@x',
    'recipient': 'dev@x',
    'urgency': 'normal',
    'summary_md': 'Review the workspace handoff',
    'repo': {'name': 'cc-collaboration', 'branch': 'main'},
  });

  @override
  Future<String> prompt(String id) async => '';

  @override
  Future<Status> status(String id) async => Status.fromJson({
    'state': 'pending',
    'sender': 'sender@x',
    'recipient': 'dev@x',
    'created_at': '2026-01-01T00:00:00Z',
  });

  @override
  Future<List<Comment>> comments(String id) async => const [];
}

class _ViewDelayedHandoffsClient extends RelayClient {
  final _requests = <String, Completer<List<ListItem>>>{};
  final startedViews = <String>[];

  _ViewDelayedHandoffsClient() : super('http://127.0.0.1', 'tok');

  @override
  Future<List<ListItem>> handoffs({String as = 'recipient'}) {
    startedViews.add(as);
    final completer = Completer<List<ListItem>>();
    _requests[as] = completer;
    return completer.future;
  }

  @override
  Future<List<ListItem>> projectHandoffs({String? project, int limit = 100}) {
    startedViews.add('project');
    final completer = Completer<List<ListItem>>();
    _requests['project'] = completer;
    return completer.future;
  }

  @override
  Future<List<OnlineUser>> onlineUsers() async => const [];

  void complete(String view, List<ListItem> items) {
    final request = _requests[view];
    if (request != null && !request.isCompleted) request.complete(items);
  }
}

class _SwitchDelayedHandoffsClient extends RelayClient {
  _SwitchDelayedHandoffsClient() : super('http://127.0.0.1', 'tok');

  final _handoffsCompleter = Completer<List<ListItem>>();
  final _onlineCompleter = Completer<List<OnlineUser>>();
  bool handoffsStarted = false;
  bool onlineStarted = false;

  @override
  Future<List<ListItem>> handoffs({String as = 'recipient'}) {
    handoffsStarted = true;
    return _handoffsCompleter.future;
  }

  @override
  Future<List<OnlineUser>> onlineUsers() {
    onlineStarted = true;
    return _onlineCompleter.future;
  }

  void completeHandoffs(List<ListItem> items) {
    if (!_handoffsCompleter.isCompleted) {
      _handoffsCompleter.complete(items);
    }
  }

  void completeOnline(List<String> identities) {
    if (_onlineCompleter.isCompleted) return;
    _onlineCompleter.complete([
      for (final identity in identities)
        OnlineUser.fromJson({'identity': identity, 'online': true}),
    ]);
  }
}

ListItem _handoff(
  String id, {
  String sender = 'sender@x',
  String headline = 'Review the workspace handoff',
  List<String> recipients = const [],
}) => ListItem.fromJson({
  'id': id,
  'kind': 'delivery',
  'sender': sender,
  'recipient': 'dev@x',
  if (recipients.isNotEmpty) 'recipients': recipients,
  'urgency': 'normal',
  'state': 'pending',
  'repo_name': 'cc-collaboration',
  'headline': headline,
  'created_at': '2026-01-01T00:00:00Z',
});
