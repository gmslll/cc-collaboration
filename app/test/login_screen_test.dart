import 'dart:io';

import 'package:app/local/session.dart';
import 'package:app/screens/login_screen.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('login submit and saved account switch are busy-guarded', () {
    final source = File('lib/screens/login_screen.dart').readAsStringSync();
    final submit = source.substring(
      source.indexOf('Future<void> _submit() async'),
      source.indexOf('Future<void> _useSaved'),
    );
    final useSaved = source.substring(
      source.indexOf('Future<void> _useSaved'),
      source.indexOf('@override\n  Widget build'),
    );

    expect(submit, contains('if (_busy) return;'));
    expect(useSaved, contains('if (_busy) return;'));
  });

  test('login mode copy explains team provisioning on register', () {
    expect(loginModeTitle(false), '登录');
    expect(loginModeTitle(true), '注册新账号');
    expect(loginModeSubtitle(false), contains('同步团队'));
    expect(loginModeSubtitle(true), contains('自动创建你的团队工作区'));
    expect(loginModeSwitchLabel(false), '没有账号?去注册');
    expect(loginModeSwitchLabel(true), '已有账号?去登录');
  });

  testWidgets('register mode shows default team guidance', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: LoginScreen(
          initialRelayUrl: 'http://127.0.0.1:1',
          initialIdentity: 'dev@x',
          onLoggedIn: (Session _) async {},
        ),
      ),
    );

    expect(find.textContaining('默认团队'), findsNothing);

    await tester.tap(find.text('没有账号?去注册'));
    await tester.pump();

    expect(find.text('注册新账号'), findsOneWidget);
    expect(find.textContaining('自动创建你的团队工作区'), findsOneWidget);
    expect(find.textContaining('默认团队'), findsOneWidget);
    expect(find.textContaining('邀请成员'), findsOneWidget);
  });

  testWidgets('register form scrolls on compact heights', (tester) async {
    tester.view.physicalSize = const Size(360, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: LoginScreen(
          initialRelayUrl: 'http://127.0.0.1:1',
          initialIdentity: 'dev@x',
          showCancel: true,
          onLoggedIn: (Session _) async {},
        ),
      ),
    );

    await tester.ensureVisible(find.text('没有账号?去注册'));
    await tester.pump();
    await tester.tap(find.text('没有账号?去注册'));
    await tester.pump();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    await tester.ensureVisible(find.text('注册新账号'));
    await tester.pump();
    expect(find.text('注册新账号'), findsOneWidget);
    expect(find.textContaining('默认团队'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('login failure after unmount does not call setState', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: LoginScreen(
          initialRelayUrl: 'http://127.0.0.1:1',
          initialIdentity: 'dev@x',
          onLoggedIn: (Session _) async {},
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(2), 'password');
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
