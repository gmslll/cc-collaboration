import 'dart:io';

import 'package:app/api/models.dart';
import 'package:app/screens/terminal_pane.dart';
import 'package:app/screens/workspace_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('incoming peer message target check uses the live session list', () {
    final open = TerminalSession('/repo', 'codex', agent: 'codex');
    final closed = TerminalSession('/repo', 'claude', agent: 'claude');
    addTearDown(open.dispose);
    addTearDown(closed.dispose);

    expect(incomingMessageTargetIsOpen([open], open), isTrue);
    expect(incomingMessageTargetIsOpen([open], closed), isFalse);
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

  test('online send ignores stale relay clients after account switches', () {
    final relay = source.substring(
      source.indexOf('bool _isCurrentRelayClient('),
      source.indexOf('// _publishSessions advertises'),
    );
    final dialog = source.substring(
      source.indexOf('Future<void> _showSendToOnlineUser(String text)'),
      source.indexOf('Future<void> _loadTasks()'),
    );

    expect(relay, contains('identical(client, widget.client)'));
    expect(dialog, contains('if (!_isCurrentRelayClient(client)) return;'));
    expect(dialog, contains('!_isCurrentRelayClient(client) ||'));
    expect(dialog, contains("账号已切换,请重新选择在线用户"));
    expect(
      dialog.indexOf('await client.onlineUsers()'),
      lessThan(dialog.indexOf('if (!_isCurrentRelayClient(client)) return;')),
    );
    expect(
      dialog.indexOf('await client.sendMessage'),
      lessThan(
        dialog.lastIndexOf('if (!_isCurrentRelayClient(client)) return;'),
      ),
    );
  });

  test('incoming peer message dialog uses responsive session labels', () {
    expect(source, contains('preferred: 460'));
    expect(source, contains('onlineSendSessionMenuMaxHeight'));
    expect(source, contains('menuMaxHeight:'));
    expect(source, contains('incomingMessageTargetIsOpen'));
    expect(source, contains("message: '目标会话已关闭,已挂起'"));
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
