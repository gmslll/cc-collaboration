import 'dart:async';

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
  Future<List<OnlineUser>> onlineUsers() async => const [];

  void complete(String view, List<ListItem> items) {
    final request = _requests[view];
    if (request != null && !request.isCompleted) request.complete(items);
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
