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

  test('online send dialog constrains long users and session labels', () {
    expect(source, contains('onlineSendDialogWidth'));
    expect(source, contains('onlineSendUserChipWidth'));
    expect(source, contains('maxLines: 1'));
    expect(source, contains('overflow: TextOverflow.ellipsis'));
  });

  test('incoming peer message dialog uses responsive session labels', () {
    expect(source, contains('preferred: 460'));
    expect(
      source,
      isNot(contains('DropdownMenuItem(value: s, child: Text(s.label))')),
    );
  });
}
