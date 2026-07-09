import 'dart:io';

import 'package:app/api/models.dart';
import 'package:app/screens/workspace_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/screens/workspace_page.dart').readAsStringSync();

  test('online send selectable users exclude self by normalized identity', () {
    final users = onlineSendSelectableUsers([
      OnlineUser.fromJson({'identity': ' Me@X ', 'online': true}),
      OnlineUser.fromJson({'identity': 'teammate@x', 'online': true}),
      OnlineUser.fromJson({'identity': 'offline@x', 'online': false}),
    ], 'me@x');

    expect([for (final user in users) user.identity], ['teammate@x']);
  });

  test(
    'online send selectable users skip blanks and normalized duplicates',
    () {
      final users = onlineSendSelectableUsers([
        OnlineUser.fromJson({'identity': 'teammate@x', 'online': true}),
        OnlineUser.fromJson({'identity': ' Teammate@X ', 'online': true}),
        OnlineUser.fromJson({'identity': '   ', 'online': true}),
        OnlineUser.fromJson({'identity': 'ops@x', 'online': true}),
      ], 'me@x');

      expect(
        [for (final user in users) user.identity],
        ['teammate@x', 'ops@x'],
      );
    },
  );

  test('online send selected user comparison is identity-normalized', () {
    expect(onlineSendIdentitySelected(' Dev@X ', 'dev@x'), isTrue);
    expect(onlineSendIdentitySelected(null, 'dev@x'), isFalse);
    expect(onlineSendIdentitySelected('dev@x', 'ops@x'), isFalse);
  });

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
    expect(source, contains('onlineSendUserListMaxHeight'));
    expect(source, contains('SingleChildScrollView'));
    expect(source, contains('maxLines: 1'));
    expect(source, contains('overflow: TextOverflow.ellipsis'));
  });

  test('online send ignores stale session loads after switching users', () {
    final dialog = source.substring(
      source.indexOf('Future<void> _showSendToOnlineUser(String text)'),
      source.indexOf('Future<void> _loadTasks()'),
    );
    expect(dialog, contains('var loadSeq = 0;'));
    expect(dialog, contains('final seq = ++loadSeq;'));
    expect(dialog, contains('seq != loadSeq'));
    expect(dialog, contains('!onlineSendIdentitySelected(selected, identity)'));
  });

  test('incoming peer message dialog uses responsive session labels', () {
    expect(source, contains('preferred: 460'));
    expect(source, contains('onlineSendSessionMenuMaxHeight'));
    expect(source, contains('menuMaxHeight:'));
    expect(source, isNot(contains("title: Text('\$from 发来内容')")));
    expect(source, contains("'\$from 发来内容',\n              maxLines: 1"));
    expect(source, contains('overflow: TextOverflow.ellipsis'));
    expect(
      source,
      isNot(contains('DropdownMenuItem(value: s, child: Text(s.label))')),
    );
  });

  test('parked peer message list uses responsive labels and actions', () {
    expect(source, contains("title: Text('待处理 (\${_parked.length})')"));
    expect(source, isNot(contains('width: 460')));
    expect(source, contains('onlineSendParkedListMaxHeight'));
    expect(source, contains('width: 92'));
    expect(source, contains('maxLines: 1'));
    expect(source, contains('overflow: TextOverflow.ellipsis'));
  });
}
