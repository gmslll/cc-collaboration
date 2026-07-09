import 'dart:async';

import 'package:app/api/models.dart';
import 'package:app/api/relay_client.dart';
import 'package:app/local/config.dart';
import 'package:app/screens/handoff_detail_view.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  testWidgets('handoff retract dialog cancel closes cleanly', (tester) async {
    final client = _ActionDetailClient(_package('h1', 'me@x', 'owned handoff'));

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: HandoffDetailView(
          client: client,
          config: AppConfig('http://127.0.0.1:1', 'tok', 'me@x', const {}),
          item: _item('h1', 'me@x', 'owned handoff'),
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
}) => Package.fromJson({
  'id': id,
  'kind': kind,
  'sender': sender,
  'recipient': 'me@x',
  'urgency': 'normal',
  'summary_md': summary,
  'repo': {'name': 'repo', 'branch': 'main'},
  'attachments': <Map<String, dynamic>>[],
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
