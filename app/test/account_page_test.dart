import 'dart:async';

import 'package:app/api/models.dart';
import 'package:app/api/relay_client.dart';
import 'package:app/screens/account_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('account dropdown menus are capped for compact screens', () {
    expect(accountMenuMaxHeight(const Size(1024, 900)), 320);
    expect(accountMenuMaxHeight(const Size(320, 420)), closeTo(243.6, 0.001));
    expect(accountMenuMaxHeight(const Size(320, 220)), 160);
    expect(accountMenuMaxHeight(Size.zero), 320);
  });

  testWidgets('password change completion after unmount is ignored', (
    tester,
  ) async {
    final client = _DelayedAccountPageFakeClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: AccountPage(client: client, identity: 'dev@x'),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(_fieldWithLabel('当前密码'), 'old-password');
    await tester.enterText(_fieldWithLabel('新密码(≥8 位)'), 'new-password');
    await tester.tap(find.widgetWithText(FilledButton, '更新密码'));
    await tester.pump();
    expect(client.passwordChangeStarted, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    client.completePasswordChange();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('token creation completion after unmount is ignored', (
    tester,
  ) async {
    final client = _DelayedAccountPageFakeClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: AccountPage(client: client, identity: 'dev@x'),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(_fieldWithHint('标签(如 laptop)'), 'laptop');
    final generateButton = find.widgetWithText(TextButton, '生成');
    await tester.ensureVisible(generateButton);
    await tester.tap(generateButton);
    await tester.pump();
    expect(client.tokenCreateStarted, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    client.completeTokenCreate('raw-token');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}

Finder _fieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Finder _fieldWithHint(String hint) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.hintText == hint,
);

class _DelayedAccountPageFakeClient extends RelayClient {
  _DelayedAccountPageFakeClient() : super('http://127.0.0.1', 'tok');

  final _passwordCompleter = Completer<void>();
  final _tokenCompleter = Completer<String>();
  bool passwordChangeStarted = false;
  bool tokenCreateStarted = false;

  @override
  Future<List<MachineToken>> tokens() async => const [];

  @override
  Future<void> changePassword(String oldPw, String newPw) {
    passwordChangeStarted = true;
    return _passwordCompleter.future;
  }

  @override
  Future<String> createToken(String label) {
    tokenCreateStarted = true;
    return _tokenCompleter.future;
  }

  void completePasswordChange() {
    if (!_passwordCompleter.isCompleted) {
      _passwordCompleter.complete();
    }
  }

  void completeTokenCreate(String token) {
    if (!_tokenCompleter.isCompleted) {
      _tokenCompleter.complete(token);
    }
  }
}
