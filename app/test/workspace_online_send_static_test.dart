import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/screens/workspace_page.dart').readAsStringSync();

  test('online send action is synchronized with relay availability', () {
    expect(source, contains('void _syncOnlineSendAction()'));
    expect(
      source,
      contains(
        'onSendToOnline = _canSendToOnline ? _showSendToOnlineUser : null;',
      ),
    );
  });

  test('file and session menus hide online send when relay is unavailable', () {
    expect(
      RegExp(
        r"if \(_canSendToOnline\)\s+ccMenuItem\(\s+value: 'online'",
      ).hasMatch(source),
      isTrue,
    );
    expect(
      RegExp(
        r"if \(_canSendToOnline\)\s+ccMenuItem\(\s+value: 'send-online'",
      ).hasMatch(source),
      isTrue,
    );
  });
}
