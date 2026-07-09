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

  testWidgets('password change ignores duplicate submit taps', (tester) async {
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
    final button = find.widgetWithText(FilledButton, '更新密码');
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();

    expect(client.passwordChangeCalls, 1);
    expect(find.text('更新中'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed,
      isNull,
    );

    client.completePasswordChange();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
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

  testWidgets('token creation ignores duplicate submit taps', (tester) async {
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
    final button = find.widgetWithText(TextButton, '生成');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();

    expect(client.tokenCreateCalls, 1);
    expect(find.text('生成中'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '生成中'))
          .onPressed,
      isNull,
    );

    client.completeTokenCreate('raw-token');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('machine token deletion requires confirmation', (tester) async {
    final client = _TokenDeleteAccountPageFakeClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: AccountPage(client: client, identity: 'dev@x'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final deleteButton = find.byWidgetPredicate(
      (w) => w is IconButton && w.tooltip == '删除机器 token',
    );
    tester.widget<IconButton>(deleteButton).onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('删除机器 token'), findsOneWidget);
    expect(client.deleteTokenCalls, 0);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('删除机器 token'), findsNothing);
    expect(client.deleteTokenCalls, 0);

    tester.widget<IconButton>(deleteButton).onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(client.deleteTokenCalls, 1);
    expect(client.deletedTokenId, 'tok-1');
    expect(find.text('laptop'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('machine token deletion locks while request is pending', (
    tester,
  ) async {
    final client = _DelayedTokenDeleteAccountPageFakeClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: Scaffold(
          body: AccountPage(client: client, identity: 'dev@x'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final deleteButton = find.byWidgetPredicate(
      (w) => w is IconButton && w.tooltip == '删除机器 token',
    );
    tester.widget<IconButton>(deleteButton).onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();

    expect(client.deleteTokenCalls, 1);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(tester.widget<IconButton>(deleteButton).onPressed, isNull);

    client.completeDeleteToken();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('laptop'), findsNothing);
    expect(client.deleteTokenCalls, 1);
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
  int passwordChangeCalls = 0;
  int tokenCreateCalls = 0;

  @override
  Future<List<MachineToken>> tokens() async => const [];

  @override
  Future<void> changePassword(String oldPw, String newPw) {
    passwordChangeStarted = true;
    passwordChangeCalls++;
    return _passwordCompleter.future;
  }

  @override
  Future<String> createToken(String label) {
    tokenCreateStarted = true;
    tokenCreateCalls++;
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

class _TokenDeleteAccountPageFakeClient extends RelayClient {
  _TokenDeleteAccountPageFakeClient() : super('http://127.0.0.1', 'tok');

  bool _deleted = false;
  int deleteTokenCalls = 0;
  String? deletedTokenId;

  @override
  Future<List<MachineToken>> tokens() async => _deleted
      ? const []
      : [
          MachineToken.fromJson({
            'id': 'tok-1',
            'label': 'laptop',
            'created_at': '2026-01-01T00:00:00Z',
          }),
        ];

  @override
  Future<void> deleteToken(String id) async {
    deleteTokenCalls++;
    deletedTokenId = id;
    _deleted = true;
  }
}

class _DelayedTokenDeleteAccountPageFakeClient extends RelayClient {
  _DelayedTokenDeleteAccountPageFakeClient() : super('http://127.0.0.1', 'tok');

  final _deleteCompleter = Completer<void>();
  bool _deleted = false;
  int deleteTokenCalls = 0;

  @override
  Future<List<MachineToken>> tokens() async => _deleted
      ? const []
      : [
          MachineToken.fromJson({
            'id': 'tok-1',
            'label': 'laptop',
            'created_at': '2026-01-01T00:00:00Z',
          }),
        ];

  @override
  Future<void> deleteToken(String id) async {
    deleteTokenCalls++;
    await _deleteCompleter.future;
    _deleted = true;
  }

  void completeDeleteToken() {
    if (!_deleteCompleter.isCompleted) {
      _deleteCompleter.complete();
    }
  }
}
