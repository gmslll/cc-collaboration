import 'dart:async';

import 'package:app/api/models.dart';
import 'package:app/api/relay_client.dart';
import 'package:app/local/config.dart';
import 'package:app/screens/handoffs_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

ListItem _handoff(String id) => ListItem.fromJson({
  'id': id,
  'kind': 'delivery',
  'sender': 'sender@x',
  'recipient': 'dev@x',
  'urgency': 'normal',
  'state': 'pending',
  'repo_name': 'cc-collaboration',
  'headline': 'Review the workspace handoff',
  'created_at': '2026-01-01T00:00:00Z',
});
