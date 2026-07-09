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
