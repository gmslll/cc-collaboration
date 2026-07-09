import 'dart:io';

import 'package:app/api/models.dart';
import 'package:app/local/config.dart';
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

  test('online send selectable users can be limited to project members', () {
    final users = onlineSendSelectableUsers(
      [
        OnlineUser.fromJson({'identity': 'owner@x', 'online': true}),
        OnlineUser.fromJson({'identity': 'member@x', 'online': true}),
        OnlineUser.fromJson({'identity': 'outside@x', 'online': true}),
        OnlineUser.fromJson({'identity': 'offline@x', 'online': false}),
      ],
      'owner@x',
      allowedIdentities: [' Owner@X ', 'member@x'],
    );

    expect([for (final user in users) user.identity], ['member@x']);
  });

  test('online send project recipients include owner and members', () {
    final detail = ProjectDetail.fromJson({
      'project': {
        'id': 'p1',
        'org_id': 'o1',
        'name': 'backend',
        'owner_identity': ' owner@x ',
      },
      'members': [
        {'identity': 'member@x', 'role': 'member'},
        {'identity': '   ', 'role': 'member'},
      ],
    });

    expect(onlineSendProjectRecipientIdentities(detail), {
      'owner@x',
      'member@x',
    });
  });

  test('online send project reach includes team owners and admins', () {
    final detail = ProjectDetail.fromJson({
      'project': {
        'id': 'p1',
        'org_id': 'o1',
        'name': 'backend',
        'owner_identity': ' owner@x ',
      },
      'members': [
        {'identity': 'direct@x', 'role': 'member'},
      ],
    });
    final organization = OrganizationDetail.fromJson({
      'organization': {
        'id': 'o1',
        'name': 'Team',
        'owner_identity': 'org-owner@x',
      },
      'members': [
        {'identity': 'org-owner@x', 'role': 'owner'},
        {'identity': 'org-admin@x', 'role': 'admin'},
        {'identity': 'org-member@x', 'role': 'member'},
        {'identity': 'org-guest@x', 'role': 'guest'},
        {'identity': '   ', 'role': 'admin'},
      ],
    });

    expect(
      onlineSendProjectReachableIdentities(detail, organization: organization),
      {'owner@x', 'direct@x', 'org-owner@x', 'org-admin@x'},
    );
  });

  test('online send project scope prefers configured relay project id', () {
    final roles = [
      ProjectRole.fromJson({
        'id': 'relay-a',
        'org_id': 'org-a',
        'name': 'backend',
        'role': 'member',
      }),
      ProjectRole.fromJson({
        'id': 'relay-b',
        'org_id': 'org-b',
        'name': 'backend',
        'role': 'member',
      }),
    ];
    const localProject = ProjectCfg('backend', '/repo/backend', '', 'relay-b');

    expect(onlineSendProjectNameIsAmbiguous(roles, 'backend'), isTrue);
    expect(onlineSendProjectIdForLocalProject(roles, localProject), 'relay-b');
  });

  test('online send project scope blocks ambiguous project names', () {
    final roles = [
      ProjectRole.fromJson({
        'id': 'relay-a',
        'org_id': 'org-a',
        'name': 'backend',
        'role': 'member',
      }),
      ProjectRole.fromJson({
        'id': 'relay-b',
        'org_id': 'org-b',
        'name': 'backend',
        'role': 'member',
      }),
    ];
    const localProject = ProjectCfg('backend', '/repo/backend');

    expect(onlineSendProjectNameIsAmbiguous(roles, 'backend'), isTrue);
    expect(onlineSendProjectIdForLocalProject(roles, localProject), isNull);
  });

  test(
    'remote spawn project matching requires configured relay project id',
    () {
      const unbound = ProjectCfg('backend', '/repo/backend');
      const bound = ProjectCfg(
        'backend',
        '/repo/backend-team',
        '',
        'relay-backend',
      );

      expect(remoteSpawnProjectMatchesRequestedId(unbound, null), isTrue);
      expect(remoteSpawnProjectMatchesRequestedId(unbound, ''), isTrue);
      expect(
        remoteSpawnProjectMatchesRequestedId(unbound, 'relay-backend'),
        isFalse,
      );
      expect(
        remoteSpawnProjectMatchesRequestedId(bound, ' relay-backend '),
        isTrue,
      );
      expect(
        remoteSpawnProjectMatchesRequestedId(bound, 'relay-frontend'),
        isFalse,
      );
    },
  );

  test('online send sessions prefer relay project id and fallback to name', () {
    final sessions = [
      RemoteSession.fromJson({
        'id': 's1',
        'label': 'Backend exact',
        'project': 'backend',
        'project_id': 'relay-backend',
      }),
      RemoteSession.fromJson({
        'id': 's2',
        'label': 'Backend legacy',
        'project': 'backend',
      }),
      RemoteSession.fromJson({
        'id': 's3',
        'label': 'Frontend',
        'project': 'frontend',
        'project_id': 'relay-frontend',
      }),
    ];

    expect(
      [
        for (final s in onlineSendSessionsForProject(
          sessions,
          projectId: 'relay-backend',
          projectName: 'backend',
        ))
          s.id,
      ],
      ['s1', 's2'],
    );
    expect(
      [
        for (final s in onlineSendSessionsForProject(
          sessions,
          projectName: 'backend',
        ))
          s.id,
      ],
      ['s1', 's2'],
    );
  });

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

  test('incoming peer message project matching prefers ids and falls back', () {
    expect(
      incomingMessageSessionMatchesProject(
        sessionProjectId: 'relay-backend',
        sessionProjectName: 'Backend',
        messageProjectId: 'relay-backend',
        messageProjectName: 'Backend',
      ),
      isTrue,
    );
    expect(
      incomingMessageSessionMatchesProject(
        sessionProjectId: 'relay-frontend',
        sessionProjectName: 'Backend',
        messageProjectId: 'relay-backend',
        messageProjectName: 'Backend',
      ),
      isFalse,
    );
    expect(
      incomingMessageSessionMatchesProject(
        sessionProjectId: '',
        sessionProjectName: 'Backend',
        messageProjectId: 'relay-backend',
        messageProjectName: 'Backend',
      ),
      isTrue,
    );
    expect(
      incomingMessageSessionMatchesProject(
        sessionProjectId: '',
        sessionProjectName: 'Frontend',
        messageProjectId: 'relay-backend',
        messageProjectName: 'Backend',
      ),
      isFalse,
    );
    expect(
      incomingMessageSessionMatchesProject(
        sessionProjectId: 'anything',
        sessionProjectName: 'Anything',
        messageProjectId: '',
        messageProjectName: '',
      ),
      isTrue,
    );
  });

  test('online send action is synchronized with relay availability', () {
    expect(source, contains('void _syncOnlineSendAction()'));
    expect(source, contains('onSendToOnline = _canSendToOnline'));
    expect(source, contains('sourcePath: activeTerm >= 0'));
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
      source.indexOf('_showSendToOnlineUser'),
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
      source.indexOf('_showSendToOnlineUser'),
      source.indexOf('Future<void> _loadTasks()'),
    );

    expect(relay, contains('identical(client, widget.client)'));
    expect(dialog, contains('if (!_isCurrentRelayClient(client)) return;'));
    expect(dialog, contains('await _onlineSendAllowedIdentities'));
    expect(dialog, contains('organization = await client.organization(orgId)'));
    expect(dialog, contains('} catch (_) {}'));
    expect(dialog, contains('on _OnlineSendProjectScopeError'));
    expect(dialog, contains('onlineSendSessionsForProject'));
    expect(dialog, contains('当前项目未绑定唯一团队项目,无法选择团队在线用户'));
    expect(dialog, contains('!_isCurrentRelayClient(client) ||'));
    expect(dialog, contains("账号已切换,请重新选择在线用户"));
    expect(
      dialog.indexOf('await _onlineSendAllowedIdentities'),
      lessThan(dialog.indexOf('if (!_isCurrentRelayClient(client)) return;')),
    );
    expect(
      dialog.indexOf('await client.onlineUsers()'),
      lessThan(
        dialog.indexOf(
          'if (!_isCurrentRelayClient(client)) return;',
          dialog.indexOf('await client.onlineUsers()'),
        ),
      ),
    );
    expect(
      dialog.indexOf('await client.sendMessage'),
      lessThan(
        dialog.lastIndexOf('if (!_isCurrentRelayClient(client)) return;'),
      ),
    );
  });

  test('online send file and session actions keep source context', () {
    expect(source, contains('sourcePath: f.path'));
    expect(source, contains('sourcePath: e.s.workdir'));
  });

  test('incoming peer message dialog uses responsive session labels', () {
    expect(source, contains('preferred: 460'));
    expect(source, contains('onlineSendSessionMenuMaxHeight'));
    expect(source, contains('menuMaxHeight:'));
    expect(source, contains('incomingMessageTargetIsOpen'));
    expect(source, contains('incomingMessageSessionMatchesProject'));
    expect(source, contains('final candidates = ['));
    expect(source, contains('for (final s in candidates)'));
    expect(source, contains("message: '没有匹配项目的会话,已挂起'"));
    expect(source, contains("message: '目标会话已关闭或项目不匹配,已挂起'"));
    expect(source, contains("final project = (m['project'] ?? '').toString()"));
    expect(
      source,
      contains("final projectId = (m['project_id'] ?? '').toString()"),
    );
    expect(source, contains("'project': project"));
    expect(source, contains("'project_id': projectId"));
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

  test('online send forwards selected remote session project context', () {
    final dialog = source.substring(
      source.indexOf('_showSendToOnlineUser'),
      source.indexOf('Future<void> _loadTasks()'),
    );

    expect(dialog, contains('project: s.project'));
    expect(dialog, contains('projectId: s.projectId'));
  });
}
