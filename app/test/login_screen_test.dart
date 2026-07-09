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
