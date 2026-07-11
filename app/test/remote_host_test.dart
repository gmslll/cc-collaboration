import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/local/hook_activity.dart';
import 'package:app/local/session_overview.dart';
import 'package:app/remote/pty_transport.dart';
import 'package:app/remote/remote_host.dart';
import 'package:app/screens/terminal_pane.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestRemoteHost extends RemoteHost {
  _TestRemoteHost({
    required List<TerminalSession> sessions,
    List<RemoteRoot> roots = const [],
    super.ptyTransportMode,
    super.ptyPeerFactory,
    super.onConfigAction,
    super.onAssignTodo,
    this.pretendConnected = false,
  }) : _sessions = sessions,
       super(
         relayUrl: 'http://relay.test',
         token: 'token',
         sessions: (() => sessions),
         roots: (() => roots),
       );

  final List<TerminalSession> _sessions;
  final bool pretendConnected;
  final sent = <Map<String, dynamic>>[];

  @override
  bool get connected => pretendConnected || super.connected;

  @override
  void send(Map<String, dynamic> frame) {
    sent.add(Map<String, dynamic>.from(frame));
  }

  void disposeSessions() {
    for (final s in _sessions) {
      s.dispose();
    }
  }
}

class _FakePtyPeerFactory implements PtyPeerFactory {
  final List<_FakePtyPeer> peers = [];

  @override
  Future<PtyPeer> create({
    required int peerId,
    required bool initiator,
    required PtyPeerCallbacks callbacks,
  }) async {
    final peer = _FakePtyPeer(peerId, initiator, callbacks);
    peers.add(peer);
    return peer;
  }
}

class _FakePtyPeer implements PtyPeer {
  _FakePtyPeer(this.peerId, this.initiator, this.callbacks);

  final int peerId;
  final bool initiator;
  final PtyPeerCallbacks callbacks;
  final List<List<Uint8List>> sent = [];
  bool sendResult = true;
  bool closed = false;
  final List<Completer<void>> sendGates = [];
  int sendCalls = 0;

  @override
  Future<PtyDescription> createOffer() async =>
      const PtyDescription(type: 'offer', sdp: 'offer-sdp');

  @override
  Future<PtyDescription> acceptOffer(PtyDescription offer) async =>
      const PtyDescription(type: 'answer', sdp: 'answer-sdp');

  @override
  Future<void> acceptAnswer(PtyDescription answer) async {}

  @override
  Future<void> addIce(PtyIceCandidate candidate) async {}

  @override
  Future<bool> sendPackets(List<Uint8List> packets) async {
    sendCalls++;
    if (sendGates.isNotEmpty) await sendGates.removeAt(0).future;
    if (!sendResult) return false;
    sent.add([for (final packet in packets) Uint8List.fromList(packet)]);
    return true;
  }

  @override
  Future<void> close() async => closed = true;

  void open() => callbacks.onState(PtyPeerState.p2p, null);

  void sendFrame(Map<String, dynamic> frame, {int messageId = 1}) {
    for (final packet in PtyPacketCodec.encode(frame, messageId: messageId)) {
      callbacks.onPacket(packet);
    }
  }

  List<Map<String, dynamic>> decodedFrames() {
    final frames = <Map<String, dynamic>>[];
    for (final batch in sent) {
      final frame = _decodePtyBatch(batch);
      if (frame != null) frames.add(frame);
    }
    return frames;
  }
}

Map<String, dynamic>? _decodePtyBatch(List<Uint8List> packets) {
  final reassembler = PtyPacketReassembler();
  Map<String, dynamic>? frame;
  for (final packet in packets) {
    frame = reassembler.add(packet) ?? frame;
  }
  return frame;
}

Future<_FakePtyPeer> _connectP2P(
  _TestRemoteHost host,
  _FakePtyPeerFactory factory,
  int peerId,
) async {
  host.onPeer(peerId, 'client', true);
  host.onFrame({
    't': ptySignalFrameType,
    'from': peerId,
    'kind': 'mode',
    'mode': 'p2p',
  });
  for (var i = 0; i < 20 && factory.peers.isEmpty; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  final peer = factory.peers.last;
  peer.open();
  await Future<void>.delayed(Duration.zero);
  return peer;
}

Future<void> _flushOutputBatcher() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('remote sessions and roots include relay project id', () {
    final session = TerminalSession('/repo/backend', 'claude');
    final host = _TestRemoteHost(
      sessions: [session],
      roots: const [RemoteRoot('backend', '/repo', 'team', 'relay-project')],
    );
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    host.onFrame({'t': 'list', 'from': 3});

    final sessions = host.sent.firstWhere((f) => f['t'] == 'sessions');
    final roots = host.sent.firstWhere((f) => f['t'] == 'roots');
    expect(sessions['items'], [containsPair('project_id', 'relay-project')]);
    expect(roots['items'], [containsPair('project_id', 'relay-project')]);
  });

  test('modern open for a missing session returns route failure', () async {
    final host = _TestRemoteHost(sessions: const []);
    addTearDown(host.dispose);
    host.onPeer(7, 'client', true);

    host.onFrame({
      't': 'term.open',
      'sid': 'missing',
      'from': 7,
      'routeId': 'missing-route',
      'transport': 'relay',
    });
    await Future<void>.delayed(Duration.zero);

    expect(
      host.sent,
      contains(
        allOf(
          containsPair('t', 'term.routeFailed'),
          containsPair('routeId', 'missing-route'),
          containsPair('reason', contains('不存在')),
        ),
      ),
    );
  });

  test('P2P open waits for the host DataChannel callback', () async {
    final session = TerminalSession('', '');
    final factory = _FakePtyPeerFactory();
    final host = _TestRemoteHost(
      sessions: [session],
      ptyTransportMode: PtyTransportMode.p2p,
      ptyPeerFactory: factory,
    );
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);
    host.onPeer(8, 'client', true);
    host.onFrame({
      't': ptySignalFrameType,
      'from': 8,
      'kind': 'mode',
      'mode': 'p2p',
    });
    for (var i = 0; i < 20 && factory.peers.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final peer = factory.peers.single;

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 8,
      'routeId': 'wait-open',
      'transport': 'p2p',
      'historyMode': 'none',
    });
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      host.sent.where((frame) => frame['t'] == 'term.routeFailed'),
      isEmpty,
    );
    expect(host.watching(session.id), isFalse);

    peer.open();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(host.watching(session.id), isTrue);
    expect(
      peer.decodedFrames(),
      contains(
        allOf(
          containsPair('t', 'term.ready'),
          containsPair('routeId', 'wait-open'),
        ),
      ),
    );
  });

  test('matching close cancels a pending P2P open', () async {
    final session = TerminalSession('', '');
    final factory = _FakePtyPeerFactory();
    final host = _TestRemoteHost(
      sessions: [session],
      ptyTransportMode: PtyTransportMode.p2p,
      ptyPeerFactory: factory,
    );
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);
    host.onPeer(8, 'client', true);
    host.onFrame({
      't': ptySignalFrameType,
      'from': 8,
      'kind': 'mode',
      'mode': 'p2p',
    });
    for (var i = 0; i < 20 && factory.peers.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final peer = factory.peers.single;

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 8,
      'routeId': 'cancelled-open',
      'transport': 'p2p',
      'historyMode': 'none',
    });
    host.onFrame({
      't': 'term.close',
      'sid': session.id,
      'from': 8,
      'routeId': 'cancelled-open',
    });
    peer.open();
    await Future<void>.delayed(Duration.zero);

    expect(host.watching(session.id), isFalse);
    expect(
      peer.decodedFrames().where((frame) => frame['t'] == 'term.ready'),
      isEmpty,
    );
  });

  test('stale close does not cancel a replacement pending P2P open', () async {
    final session = TerminalSession('', '');
    final factory = _FakePtyPeerFactory();
    final host = _TestRemoteHost(
      sessions: [session],
      ptyTransportMode: PtyTransportMode.p2p,
      ptyPeerFactory: factory,
    );
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);
    host.onPeer(8, 'client', true);
    host.onFrame({
      't': ptySignalFrameType,
      'from': 8,
      'kind': 'mode',
      'mode': 'p2p',
    });
    for (var i = 0; i < 20 && factory.peers.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final peer = factory.peers.single;

    for (final routeId in ['old-open', 'replacement-open']) {
      host.onFrame({
        't': 'term.open',
        'sid': session.id,
        'from': 8,
        'routeId': routeId,
        'transport': 'p2p',
        'historyMode': 'none',
      });
    }
    host.onFrame({
      't': 'term.close',
      'sid': session.id,
      'from': 8,
      'routeId': 'old-open',
    });
    peer.open();
    await Future<void>.delayed(Duration.zero);

    expect(host.watching(session.id), isTrue);
    expect(
      peer
          .decodedFrames()
          .where((frame) => frame['t'] == 'term.ready')
          .map((frame) => frame['routeId']),
      ['replacement-open'],
    );
  });

  test('strict host sanitizes overview for a Relay-mode client', () {
    final session = TerminalSession('', '');
    final host = _TestRemoteHost(
      sessions: [session],
      ptyTransportMode: PtyTransportMode.p2p,
    );
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);
    host.setOverview([
      SessionCard(
        sid: session.id,
        label: 'secret',
        agentKind: 'codex',
        isAgent: true,
        workspace: 'ws',
        project: 'proj',
        worktree: null,
        status: SessionStatus.working,
        statusDetail: 'private status',
        usageLabel: '10%',
        preview: 'private output',
        recentActivity: const [],
      ),
    ]);

    host.onFrame({'t': 'list', 'from': 9, 'ptyMode': 'relay'});

    final overview = host.sent.lastWhere((frame) => frame['t'] == 'overview');
    expect(overview['ptySafe'], isTrue);
    final item = (overview['items'] as List).single as Map;
    expect(item['preview'], '');
    expect(item['statusDetail'], '');
  });

  test('remote git file path gate rejects traversal and pathspec magic', () {
    expect(remoteGitFilePathAllowed('lib/main.dart'), isTrue);
    expect(remoteGitFilePathAllowed('dir.with.dots/file.txt'), isTrue);
    expect(remoteGitFilePathAllowed('../outside.txt'), isFalse);
    expect(remoteGitFilePathAllowed('/tmp/outside.txt'), isFalse);
    expect(remoteGitFilePathAllowed(r'C:\tmp\outside.txt'), isFalse);
    expect(remoteGitFilePathAllowed(':(top)outside.txt'), isFalse);
    expect(remoteGitFilePathAllowed('dir//file.txt'), isFalse);
  });

  test('remote git ref gates reject revision and pathspec syntax', () {
    expect(remoteGitRefNameAllowed('main'), isTrue);
    expect(remoteGitRefNameAllowed('feature/team-1'), isTrue);
    expect(remoteGitRefNameAllowed('bugfix/foo.bar'), isTrue);
    expect(remoteGitRefNameAllowed('origin/main'), isTrue);
    expect(remoteGitRefNameAllowed('feature..x'), isFalse);
    expect(remoteGitRefNameAllowed('bad@{1}'), isFalse);
    expect(remoteGitRefNameAllowed('HEAD'), isFalse);
    expect(remoteGitRefNameAllowed('-bad'), isFalse);
    expect(remoteGitRefNameAllowed('refs/heads/main'), isFalse);
    expect(remoteGitRefNameAllowed('.bad'), isFalse);
    expect(remoteGitRefNameAllowed('foo/.bad'), isFalse);
    expect(remoteGitRefNameAllowed('bad.lock'), isFalse);
    expect(remoteGitRefNameAllowed('bad.lock/name'), isFalse);
    expect(remoteGitRefNameAllowed('bad space'), isFalse);
    expect(remoteGitRefNameAllowed('bad//name'), isFalse);
    expect(remoteGitRefNameAllowed('bad:name'), isFalse);

    expect(remoteGitStartRefAllowed(null), isTrue);
    expect(remoteGitStartRefAllowed(''), isTrue);
    expect(remoteGitStartRefAllowed('origin/main'), isTrue);
    expect(remoteGitStartRefAllowed('05c4749'), isTrue);
    expect(remoteGitStartRefAllowed('HEAD~1'), isFalse);
    expect(remoteGitStartRefAllowed(r'main^{tree}'), isFalse);
    expect(remoteGitStartRefAllowed(':(top)x'), isFalse);

    expect(remoteGitStashRefAllowed(r'stash@{0}'), isTrue);
    expect(remoteGitStashRefAllowed(r'stash@{12}'), isTrue);
    expect(remoteGitStashRefAllowed(r'stash@{-1}'), isFalse);
    expect(remoteGitStashRefAllowed(r'stash@{0} --'), isFalse);
    expect(remoteGitStashRefAllowed('HEAD'), isFalse);
  });

  test('remote config mutation gate validates action-specific fields', () {
    expect(
      remoteConfigMutationAllowed('wt.add', {
        'project': 'backend',
        'workspace': '',
        'branch': 'feature/team-1',
        'start': 'origin/main',
      }),
      isTrue,
    );
    expect(
      remoteConfigMutationAllowed('wt.add', {
        'project': 'backend',
        'workspace': '   ',
        'branch': 'feature/team-1',
      }),
      isFalse,
    );
    expect(
      remoteConfigMutationAllowed('wt.add', {
        'project': 'backend',
        'workspace': 'team',
        'branch': 'feature..bad',
      }),
      isFalse,
    );
    expect(
      remoteConfigMutationAllowed('wt.add', {
        'project': 'backend',
        'branch': 'feature/team-1',
        'start': 'HEAD~1',
      }),
      isFalse,
    );
    expect(
      remoteConfigMutationAllowed('wt.add', {
        'project': 'backend',
        'workspace': 'team',
        'branch': 'feature/team-1',
        'start': '   ',
      }),
      isFalse,
    );
    expect(
      remoteConfigMutationAllowed('ws.new', {
        'name': 'mobile',
        'path': '/Users/me/cc-handoff-workspaces/mobile',
      }),
      isTrue,
    );
    expect(
      remoteConfigMutationAllowed('ws.new', {'name': 'bad\u0000name'}),
      isFalse,
    );
    expect(
      remoteConfigMutationAllowed('ws.new', {'name': 'mobile', 'path': '   '}),
      isFalse,
    );
    expect(
      remoteConfigMutationAllowed('proj.add', {
        'workspace': 'team',
        'source': 'https://github.com/org/repo.git',
      }),
      isTrue,
    );
    expect(
      remoteConfigMutationAllowed('proj.add', {
        'workspace': '',
        'source': 'https://github.com/org/repo.git',
      }),
      isTrue,
    );
    expect(
      remoteConfigMutationAllowed('proj.add', {
        'workspace': '   ',
        'source': 'https://github.com/org/repo.git',
      }),
      isFalse,
    );
    expect(
      remoteConfigMutationAllowed('proj.add', {
        'workspace': 'team',
        'source': '   ',
      }),
      isFalse,
    );
    expect(
      remoteConfigMutationAllowed('proj.remove', {
        'workspace': '',
        'project': 'backend',
      }),
      isTrue,
    );
    expect(remoteConfigMutationAllowed('unknown', {}), isFalse);
  });

  test(
    'remote fs.write rejects paths escaping root through symlinks',
    () async {
      final root = await Directory.systemTemp.createTemp('cc-remote-root');
      final outside = await Directory.systemTemp.createTemp(
        'cc-remote-outside',
      );
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => outside.delete(recursive: true));
      await Link('${root.path}/escape').create(outside.path);

      final host = _TestRemoteHost(
        sessions: const [],
        roots: [RemoteRoot('repo', root.path, 'ws')],
      );
      addTearDown(host.dispose);

      host.onFrame({
        't': 'fs.write',
        'from': 7,
        'path': '${root.path}/escape/owned.txt',
        'content': 'owned',
      });
      for (var i = 0; i < 20 && host.sent.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(host.sent, hasLength(1));
      expect(host.sent.single['t'], 'fs.write.err');
      expect(host.sent.single['to'], 7);
      expect(host.sent.single['msg'], 'forbidden');
      expect(File('${outside.path}/owned.txt').existsSync(), isFalse);
    },
  );

  test('remote git.stage rejects unsafe file path before git runs', () async {
    final root = await Directory.systemTemp.createTemp('cc-remote-git-root');
    addTearDown(() => root.delete(recursive: true));
    final host = _TestRemoteHost(
      sessions: const [],
      roots: [RemoteRoot('repo', root.path, 'ws')],
    );
    addTearDown(host.dispose);

    host.onFrame({
      't': 'git.stage',
      'from': 8,
      'path': root.path,
      'file': '../outside.txt',
    });
    for (var i = 0; i < 20 && host.sent.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(host.sent, [
      {'t': 'git.err', 'to': 8, 'msg': 'forbidden'},
    ]);
  });

  test('remote git.createBranch rejects unsafe refs before git runs', () async {
    final root = await Directory.systemTemp.createTemp('cc-remote-git-root');
    addTearDown(() => root.delete(recursive: true));
    final host = _TestRemoteHost(
      sessions: const [],
      roots: [RemoteRoot('repo', root.path, 'ws')],
    );
    addTearDown(host.dispose);

    host.onFrame({
      't': 'git.createBranch',
      'from': 8,
      'path': root.path,
      'branch': 'feature/test',
      'start': r'HEAD~1',
    });
    for (var i = 0; i < 20 && host.sent.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(host.sent, [
      {'t': 'git.err', 'to': 8, 'msg': 'forbidden'},
    ]);
  });

  test('remote git.stashPop rejects unsafe ref before git runs', () async {
    final root = await Directory.systemTemp.createTemp('cc-remote-git-root');
    addTearDown(() => root.delete(recursive: true));
    final host = _TestRemoteHost(
      sessions: const [],
      roots: [RemoteRoot('repo', root.path, 'ws')],
    );
    addTearDown(host.dispose);

    host.onFrame({
      't': 'git.stashPop',
      'from': 8,
      'path': root.path,
      'ref': r'stash@{0} --',
    });
    for (var i = 0; i < 20 && host.sent.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(host.sent, [
      {'t': 'git.err', 'to': 8, 'msg': 'forbidden'},
    ]);
  });

  test('remote config op rejects unsafe branch before handler runs', () async {
    var called = false;
    final host = _TestRemoteHost(
      sessions: const [],
      onConfigAction: (action, args) async {
        called = true;
      },
    );
    addTearDown(host.dispose);

    host.onFrame({
      't': 'wt.add',
      'from': 8,
      'workspace': 'team',
      'project': 'backend',
      'branch': r'bad@{1}',
    });
    for (var i = 0; i < 20 && host.sent.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(called, isFalse);
    expect(host.sent, [
      {'t': 'cfg.err', 'to': 8, 'msg': 'forbidden'},
    ]);
  });

  test(
    'remote config op rejects missing required fields before handler runs',
    () async {
      var called = false;
      final host = _TestRemoteHost(
        sessions: const [],
        onConfigAction: (action, args) async {
          called = true;
        },
      );
      addTearDown(host.dispose);

      host.onFrame({
        't': 'proj.add',
        'from': 8,
        'workspace': 'team',
        'source': '   ',
      });
      for (var i = 0; i < 20 && host.sent.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(called, isFalse);
      expect(host.sent, [
        {'t': 'cfg.err', 'to': 8, 'msg': 'forbidden'},
      ]);
    },
  );

  test('remote config op allows default workspace project add', () async {
    var called = false;
    String? actionSeen;
    final host = _TestRemoteHost(
      sessions: const [],
      onConfigAction: (action, args) async {
        called = true;
        actionSeen = action;
        expect(args['workspace'], '');
        expect(args['source'], 'https://github.com/org/repo.git');
      },
    );
    addTearDown(host.dispose);

    host.onFrame({
      't': 'proj.add',
      'from': 8,
      'workspace': '',
      'source': 'https://github.com/org/repo.git',
    });
    for (var i = 0; i < 20 && host.sent.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(called, isTrue);
    expect(actionSeen, 'proj.add');
    expect(host.sent, [
      {'t': 'cfg.ok', 'to': 8, 'op': 'proj.add'},
    ]);
  });

  test('legacy terminal clients keep unsequenced output on Relay', () async {
    final session = TerminalSession('', '');
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    host.onFrame({'t': 'term.open', 'sid': session.id, 'from': 1});
    await Future<void>.delayed(Duration.zero);
    host.sent.clear();
    session.remoteSink?.call('legacy');
    await _flushOutputBatcher();

    expect(host.sent, [
      {'t': 'term.output', 'to': 1, 'sid': session.id, 'd': 'legacy'},
    ]);
  });

  test('historyMode none sends ready without replaying backlog', () async {
    final session = TerminalSession('', '');
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);
    session.terminal.write('sensitive backlog');

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 2,
      'routeId': 'quick-reply',
      'transport': 'relay',
      'historyMode': 'none',
    });
    await Future<void>.delayed(Duration.zero);

    expect(host.sent.where((f) => f['t'] == 'term.ready'), hasLength(1));
    expect(host.sent.where((f) => f['t'] == 'term.output'), isEmpty);
  });

  test(
    'batch pending before open is not duplicated into history and live',
    () async {
      final session = TerminalSession('', '');
      final host = _TestRemoteHost(sessions: [session]);
      addTearDown(host.dispose);
      addTearDown(host.disposeSessions);

      host.onFrame({
        't': 'term.open',
        'sid': session.id,
        'from': 1,
        'routeId': 'first',
        'transport': 'relay',
        'historyMode': 'none',
      });
      await Future<void>.delayed(Duration.zero);
      host.sent.clear();

      session.terminal.write('once');
      session.remoteSink?.call('once');
      host.onFrame({
        't': 'term.open',
        'sid': session.id,
        'from': 2,
        'routeId': 'second',
        'transport': 'relay',
      });
      await _flushOutputBatcher();

      final second = host.sent
          .where((f) => f['to'] == 2 && f['t'] == 'term.output')
          .toList();
      expect(
        second.where((f) => (f['d'] as String).contains('once')),
        hasLength(1),
      );
    },
  );

  test(
    'routed screen reply and watched metadata share ordered Relay route',
    () async {
      final session = TerminalSession('', '');
      final host = _TestRemoteHost(sessions: [session], pretendConnected: true);
      addTearDown(host.dispose);
      addTearDown(host.disposeSessions);
      session.terminal.write('screen-content');

      host.onFrame({
        't': 'term.open',
        'sid': session.id,
        'from': 3,
        'routeId': 'routed',
        'transport': 'relay',
        'historyMode': 'none',
      });
      await Future<void>.delayed(Duration.zero);
      host.sent.clear();

      host.broadcastReply(session.id, 'reply-content');
      host.broadcastStatus(session.id, true, 'status-content');
      host.broadcastActivity(session.id, const []);
      host.onFrame({
        't': 'screen',
        'sid': session.id,
        'from': 3,
        'routeId': 'routed',
        'seq': 1,
        'requestId': 'routed-request',
      });
      await Future<void>.delayed(Duration.zero);

      final routed = host.sent
          .where(
            (f) => {'reply', 'status', 'activity', 'screen'}.contains(f['t']),
          )
          .toList();
      expect(routed.map((f) => f['seq']), [1, 2, 3, 4]);
      expect(routed.map((f) => f['routeId']).toSet(), {'routed'});
      expect(routed.map((f) => f['transport']).toSet(), {'relay'});
      expect(
        routed.singleWhere((f) => f['t'] == 'screen')['requestId'],
        'routed-request',
      );
    },
  );

  test('legacy screen reply echoes its request id', () {
    final session = TerminalSession('', '');
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    host.onFrame({
      't': 'screen',
      'sid': session.id,
      'from': 4,
      'requestId': 'legacy-request',
    });

    expect(
      host.sent.single,
      allOf(
        containsPair('t', 'screen'),
        containsPair('requestId', 'legacy-request'),
      ),
    );
  });

  test('strict client never receives an unbound Relay screen snapshot', () {
    final session = TerminalSession('', '');
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);
    session.terminal.write('must stay off relay');
    host.onFrame({'t': 'list', 'from': 9, 'ptyMode': 'p2p'});
    host.sent.clear();

    host.onFrame({'t': 'screen', 'sid': session.id, 'from': 9});

    expect(host.sent.where((f) => f['t'] == 'screen'), isEmpty);

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 9,
      'routeId': 'relay-forbidden',
      'transport': 'relay',
    });
    expect(host.watching(session.id), isFalse);
    expect(host.sent.where((f) => f['t'] == 'term.routeFailed'), hasLength(1));
  });

  test('strict list and broadcast sanitize terminal overview content', () {
    final host = _TestRemoteHost(sessions: const [], pretendConnected: true);
    addTearDown(host.dispose);
    host.setOverview([
      SessionCard(
        sid: 's1',
        label: 'agent',
        agentKind: 'claude',
        isAgent: true,
        workspace: 'ws',
        project: 'repo',
        worktree: null,
        status: SessionStatus.runningTool,
        statusDetail: 'secret command',
        usageLabel: '10 tok',
        preview: 'secret output',
        recentActivity: [
          HookActivity(
            at: DateTime.utc(2026),
            event: 'PostToolUse',
            toolInput: 'secret input',
          ),
        ],
      ),
    ]);

    host.onPeer(10, 'client', true);
    host.onPeer(11, 'client', true);
    host.onFrame({'t': 'list', 'from': 10, 'ptyMode': 'p2p'});
    host.onFrame({'t': 'list', 'from': 11, 'ptyMode': 'relay'});
    var strict = host.sent.lastWhere(
      (f) => f['t'] == 'overview' && f['to'] == 10,
    );
    var relay = host.sent.lastWhere(
      (f) => f['t'] == 'overview' && f['to'] == 11,
    );
    expect(strict['items'], [
      allOf(
        containsPair('preview', ''),
        containsPair('statusDetail', ''),
        containsPair('recentActivity', isEmpty),
      ),
    ]);
    expect(relay['items'], [
      allOf(
        containsPair('preview', 'secret output'),
        containsPair('statusDetail', 'secret command'),
        containsPair('recentActivity', isNotEmpty),
      ),
    ]);

    host.onPeer(
      12,
      'client',
      true,
    ); // mode not declared yet: broadcast skips it.
    host.sent.clear();
    host.broadcastOverview();
    expect(host.sent.where((f) => f['t'] == 'overview'), hasLength(2));
    strict = host.sent.singleWhere((f) => f['to'] == 10);
    relay = host.sent.singleWhere((f) => f['to'] == 11);
    expect((strict['items'] as List).single['preview'], '');
    expect((relay['items'] as List).single['preview'], 'secret output');
    expect(host.sent.where((f) => f['to'] == 0), isEmpty);

    host.onFrame({'t': 'list', 'from': 12}); // legacy client: full Relay view.
    final legacy = host.sent.lastWhere(
      (f) => f['t'] == 'overview' && f['to'] == 12,
    );
    expect((legacy['items'] as List).single['preview'], 'secret output');
  });

  test('P2P mode signal may arrive before the relay peer event', () async {
    final factory = _FakePtyPeerFactory();
    final host = _TestRemoteHost(sessions: const [], ptyPeerFactory: factory);
    addTearDown(host.dispose);

    host.onFrame({
      't': ptySignalFrameType,
      'from': 6,
      'kind': 'mode',
      'mode': 'auto',
    });
    for (var i = 0; i < 20 && factory.peers.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(factory.peers, hasLength(1));
    expect(factory.peers.single.peerId, 6);
    expect(factory.peers.single.initiator, isTrue);
  });

  test('P2P ready and monotonic output stay on the locked route', () async {
    final session = TerminalSession('', '');
    final factory = _FakePtyPeerFactory();
    final host = _TestRemoteHost(
      sessions: [session],
      ptyTransportMode: PtyTransportMode.p2p,
      ptyPeerFactory: factory,
    );
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);
    final peer = await _connectP2P(host, factory, 7);
    session.terminal.write('backlog');

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 7,
      'routeId': 'p2p-route',
      'transport': 'p2p',
    });
    await Future<void>.delayed(Duration.zero);
    final opened = peer.decodedFrames();
    expect(opened.first, containsPair('t', 'term.ready'));
    expect(
      opened.first,
      allOf(
        containsPair('routeId', 'p2p-route'),
        containsPair('transport', 'p2p'),
        isNot(contains('seq')),
      ),
    );
    expect(
      opened.skip(1),
      everyElement(
        allOf(
          containsPair('t', 'term.output'),
          containsPair('routeId', 'p2p-route'),
        ),
      ),
    );
    expect(opened.skip(1).map((frame) => frame['seq']), [1]);
    expect(opened.skip(1).single['d'], contains('backlog'));
    expect(host.sent.where((f) => f['t'] == 'term.ready'), isEmpty);

    peer.sent.clear();
    session.remoteSink?.call('one');
    await _flushOutputBatcher();
    session.remoteSink?.call('two');
    await _flushOutputBatcher();
    final output = peer
        .decodedFrames()
        .where((frame) => frame['t'] == 'term.output')
        .toList();
    expect(output.map((frame) => frame['seq']), [2, 3]);
    expect(output.map((frame) => frame['routeId']).toSet(), {'p2p-route'});
    expect(host.sent.where((f) => f['t'] == 'term.output'), isEmpty);

    // The DataChannel peer identity overrides a forged JSON `from` value.
    peer.sendFrame({
      't': 'term.resize',
      'sid': session.id,
      'from': 999,
      'routeId': 'p2p-route',
      'seq': 1,
      'rows': 31,
      'cols': 91,
    });
    expect(session.debugRemoteSize, (rows: 31, cols: 91));
  });

  test('P2P input gap reorders briefly instead of failing the route', () async {
    final session = TerminalSession('', '');
    final factory = _FakePtyPeerFactory();
    final host = _TestRemoteHost(
      sessions: [session],
      ptyTransportMode: PtyTransportMode.p2p,
      ptyPeerFactory: factory,
    );
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);
    final peer = await _connectP2P(host, factory, 8);
    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 8,
      'routeId': 'reordered',
      'transport': 'p2p',
      'historyMode': 'none',
    });
    await Future<void>.delayed(Duration.zero);
    peer.sent.clear();

    peer.sendFrame({
      't': 'term.resize',
      'sid': session.id,
      'routeId': 'reordered',
      'seq': 2,
      'rows': 42,
      'cols': 92,
    });
    expect(session.debugRemoteSize, isNull);
    expect(host.watching(session.id), isTrue);

    peer.sendFrame({
      't': 'term.resize',
      'sid': session.id,
      'routeId': 'reordered',
      'seq': 1,
      'rows': 41,
      'cols': 91,
    });
    expect(session.debugRemoteSize, (rows: 42, cols: 92));
    expect(host.watching(session.id), isTrue);
  });

  test('P2P close waits behind earlier input sequence', () async {
    final session = TerminalSession('', '');
    final factory = _FakePtyPeerFactory();
    final host = _TestRemoteHost(
      sessions: [session],
      ptyTransportMode: PtyTransportMode.p2p,
      ptyPeerFactory: factory,
    );
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);
    final peer = await _connectP2P(host, factory, 18);
    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 18,
      'routeId': 'ordered-close',
      'transport': 'p2p',
      'historyMode': 'none',
    });
    await Future<void>.delayed(Duration.zero);

    peer.sendFrame({
      't': 'term.close',
      'sid': session.id,
      'routeId': 'ordered-close',
      'seq': 2,
    });
    expect(host.watching(session.id), isTrue);
    peer.sendFrame({
      't': 'term.resize',
      'sid': session.id,
      'routeId': 'ordered-close',
      'seq': 1,
      'rows': 40,
      'cols': 90,
    }, messageId: 2);

    expect(host.watching(session.id), isFalse);
  });

  test('active route fails when its session disappears', () async {
    final session = TerminalSession('', '');
    final sessions = <TerminalSession>[session];
    final host = _TestRemoteHost(sessions: sessions);
    addTearDown(host.dispose);
    addTearDown(session.dispose);
    host.onPeer(19, 'client', true);
    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 19,
      'routeId': 'gone',
      'transport': 'relay',
      'historyMode': 'none',
    });
    await Future<void>.delayed(Duration.zero);
    sessions.clear();
    host.sent.clear();

    host.onFrame({
      't': 'term.input',
      'sid': session.id,
      'from': 19,
      'routeId': 'gone',
      'seq': 1,
      'd': 'must-not-disappear',
    });

    expect(host.watching(session.id), isFalse);
    expect(host.sent, contains(containsPair('t', 'term.routeFailed')));
  });

  test('remote PTY resize rejects oversized dimensions', () async {
    final session = TerminalSession('', '');
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);
    host.onPeer(20, 'client', true);
    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 20,
      'routeId': 'bounded-size',
      'transport': 'relay',
      'historyMode': 'none',
    });
    await Future<void>.delayed(Duration.zero);
    host.sent.clear();

    host.onFrame({
      't': 'term.resize',
      'sid': session.id,
      'from': 20,
      'routeId': 'bounded-size',
      'seq': 1,
      'rows': 501,
      'cols': 80,
    });

    expect(session.debugRemoteSize, isNull);
    expect(host.watching(session.id), isFalse);
    expect(host.sent, contains(containsPair('t', 'term.routeFailed')));
  });

  test(
    'missing P2P input sequence fails after bounded reorder timeout',
    () async {
      final session = TerminalSession('', '');
      final factory = _FakePtyPeerFactory();
      final host = _TestRemoteHost(
        sessions: [session],
        ptyTransportMode: PtyTransportMode.p2p,
        ptyPeerFactory: factory,
      );
      addTearDown(host.dispose);
      addTearDown(host.disposeSessions);
      final peer = await _connectP2P(host, factory, 9);
      host.onFrame({
        't': 'term.open',
        'sid': session.id,
        'from': 9,
        'routeId': 'timeout',
        'transport': 'p2p',
        'historyMode': 'none',
      });
      await Future<void>.delayed(Duration.zero);
      host.sent.clear();

      peer.sendFrame({
        't': 'term.resize',
        'sid': session.id,
        'routeId': 'timeout',
        'seq': 2,
        'rows': 42,
        'cols': 92,
      });
      await Future<void>.delayed(const Duration(milliseconds: 550));

      expect(host.watching(session.id), isFalse);
      expect(host.sent.where((f) => f['t'] == 'term.routeFailed'), isNotEmpty);
    },
  );

  test('large old history stops lazily when a P2P route is replaced', () async {
    final session = TerminalSession('', '');
    final factory = _FakePtyPeerFactory();
    final host = _TestRemoteHost(
      sessions: [session],
      ptyTransportMode: PtyTransportMode.p2p,
      ptyPeerFactory: factory,
    );
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);
    final peer = await _connectP2P(host, factory, 12);
    session.terminal.write(List.filled(20000, 'old-history-').join());
    final firstSend = Completer<void>();
    peer.sendGates.add(firstSend);

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 12,
      'routeId': 'old',
      'transport': 'p2p',
    });
    for (var i = 0; i < 20 && peer.sendCalls < 1; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(peer.sendCalls, 1);

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 12,
      'routeId': 'new',
      'transport': 'p2p',
      'historyMode': 'none',
    });
    for (var i = 0; i < 20 && peer.sendCalls < 2; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      peer.sendCalls,
      2,
      reason: 'new route must not wait for old history',
    );
    firstSend.complete();
    await Future<void>.delayed(Duration.zero);

    final frames = peer.decodedFrames();
    expect(
      frames.where((f) => f['routeId'] == 'old' && f['t'] == 'term.output'),
      isEmpty,
    );
    expect(
      frames.where((f) => f['routeId'] == 'new' && f['t'] == 'term.ready'),
      hasLength(1),
    );
  });

  test(
    'blocked P2P route fails at bounded queue without corrupting watchers',
    () async {
      final session = TerminalSession('', '');
      final factory = _FakePtyPeerFactory();
      final host = _TestRemoteHost(
        sessions: [session],
        ptyTransportMode: PtyTransportMode.p2p,
        ptyPeerFactory: factory,
        pretendConnected: true,
      );
      addTearDown(host.dispose);
      addTearDown(host.disposeSessions);
      final peer = await _connectP2P(host, factory, 21);
      final blocked = Completer<void>();
      peer.sendGates.add(blocked);
      host.onFrame({
        't': 'term.open',
        'sid': session.id,
        'from': 21,
        'routeId': 'bounded',
        'transport': 'p2p',
        'historyMode': 'none',
      });
      for (var i = 0; i < 20 && peer.sendCalls < 1; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      for (var i = 0; i < 80; i++) {
        host.broadcastStatus(session.id, true, 'queued-$i');
      }

      expect(host.watching(session.id), isFalse);
      expect(
        host.sent.where((f) => f['t'] == 'term.routeFailed'),
        hasLength(1),
      );
      blocked.complete();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'one P2P and one Relay client receive isolated terminal routes',
    () async {
      final session = TerminalSession('', '');
      final factory = _FakePtyPeerFactory();
      final host = _TestRemoteHost(
        sessions: [session],
        ptyPeerFactory: factory,
      );
      addTearDown(host.dispose);
      addTearDown(host.disposeSessions);
      final p2pPeer = await _connectP2P(host, factory, 10);
      host.onPeer(11, 'client', true);

      host.onFrame({
        't': 'term.open',
        'sid': session.id,
        'from': 10,
        'routeId': 'direct',
        'transport': 'p2p',
      });
      host.onFrame({
        't': 'term.open',
        'sid': session.id,
        'from': 11,
        'routeId': 'brokered',
        'transport': 'relay',
      });
      await Future<void>.delayed(Duration.zero);
      p2pPeer.sent.clear();
      host.sent.clear();

      session.remoteSink?.call('fanout');
      await _flushOutputBatcher();

      expect(p2pPeer.decodedFrames(), [
        allOf(
          containsPair('t', 'term.output'),
          containsPair('routeId', 'direct'),
          containsPair('seq', 1),
        ),
      ]);
      expect(host.sent.where((f) => f['t'] == 'term.output'), [
        allOf(
          containsPair('to', 11),
          containsPair('routeId', 'brokered'),
          containsPair('seq', 1),
        ),
      ]);

      host.onPeer(10, 'client', false);
      expect(p2pPeer.closed, isTrue);
      expect(session.remoteSink, isNotNull);
      host.sent.clear();
      session.remoteSink?.call('relay-survives');
      await _flushOutputBatcher();
      expect(host.sent.where((f) => f['t'] == 'term.output'), [
        allOf(
          containsPair('to', 11),
          containsPair('routeId', 'brokered'),
          containsPair('seq', 2),
        ),
      ]);
    },
  );

  test(
    'stale route is rejected without tearing down the current route',
    () async {
      final session = TerminalSession('', '');
      final host = _TestRemoteHost(sessions: [session]);
      addTearDown(host.dispose);
      addTearDown(host.disposeSessions);
      host.onPeer(12, 'client', true);
      host.onFrame({
        't': 'term.open',
        'sid': session.id,
        'from': 12,
        'routeId': 'current',
        'transport': 'relay',
      });
      await Future<void>.delayed(Duration.zero);
      host.sent.clear();

      host.onFrame({
        't': 'term.resize',
        'sid': session.id,
        'from': 12,
        'routeId': 'stale',
        'seq': 1,
        'rows': 40,
        'cols': 100,
      });
      expect(session.debugRemoteSize, isNull);
      expect(host.sent.single, containsPair('t', 'term.routeFailed'));
      expect(host.sent.single, containsPair('routeId', 'stale'));
      expect(session.remoteSink, isNotNull);

      host.onFrame({
        't': 'term.resize',
        'sid': session.id,
        'from': 12,
        'routeId': 'current',
        'seq': 1,
        'rows': 41,
        'cols': 101,
      });
      expect(session.debugRemoteSize, (rows: 41, cols: 101));
    },
  );

  test('wrong channel fails and removes only that terminal watcher', () async {
    final session = TerminalSession('', '');
    final factory = _FakePtyPeerFactory();
    final host = _TestRemoteHost(
      sessions: [session],
      ptyTransportMode: PtyTransportMode.p2p,
      ptyPeerFactory: factory,
    );
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);
    await _connectP2P(host, factory, 13);
    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 13,
      'routeId': 'direct',
      'transport': 'p2p',
    });
    await Future<void>.delayed(Duration.zero);
    host.sent.clear();

    // The route is locked to P2P, so the same payload arriving over Relay fails.
    host.onFrame({
      't': 'term.resize',
      'sid': session.id,
      'from': 13,
      'routeId': 'direct',
      'seq': 1,
      'rows': 30,
      'cols': 90,
    });

    expect(session.debugRemoteSize, isNull);
    expect(session.remoteSink, isNull);
    expect(host.sent, [containsPair('t', 'term.routeFailed')]);
  });

  test('duplicate input sequence drops and a gap fails the route', () async {
    final session = TerminalSession('', '');
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);
    host.onPeer(14, 'client', true);
    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 14,
      'routeId': 'ordered',
      'transport': 'relay',
    });
    await Future<void>.delayed(Duration.zero);
    host.sent.clear();

    void resize(int seq, int rows) => host.onFrame({
      't': 'term.resize',
      'sid': session.id,
      'from': 14,
      'routeId': 'ordered',
      'seq': seq,
      'rows': rows,
      'cols': 80,
    });

    resize(1, 30);
    resize(1, 31);
    expect(session.debugRemoteSize, (rows: 30, cols: 80));
    expect(host.sent, isEmpty);

    resize(3, 33);
    await Future<void>.delayed(const Duration(milliseconds: 550));
    expect(session.debugRemoteSize, isNull);
    expect(host.sent, [containsPair('t', 'term.routeFailed')]);
  });

  test(
    'malformed routed input fails closed without reaching the PTY',
    () async {
      final session = TerminalSession('', '');
      final host = _TestRemoteHost(sessions: [session]);
      addTearDown(host.dispose);
      addTearDown(host.disposeSessions);
      host.onPeer(16, 'client', true);
      host.onFrame({
        't': 'term.open',
        'sid': session.id,
        'from': 16,
        'routeId': 'typed',
        'transport': 'relay',
      });
      await Future<void>.delayed(Duration.zero);
      host.sent.clear();

      host.onFrame({
        't': 'term.input',
        'sid': session.id,
        'from': 16,
        'routeId': 'typed',
        'seq': 1,
        'd': 42,
      });

      expect(host.sent, [containsPair('t', 'term.routeFailed')]);
      expect(session.remoteSink, isNull);
    },
  );

  test(
    'term.close stops Relay output and ignores a stale route close',
    () async {
      final session = TerminalSession('', '');
      final host = _TestRemoteHost(sessions: [session]);
      addTearDown(host.dispose);
      addTearDown(host.disposeSessions);
      host.onPeer(17, 'client', true);

      host.onFrame({
        't': 'term.open',
        'sid': session.id,
        'from': 17,
        'routeId': 'old',
        'transport': 'relay',
      });
      host.onFrame({
        't': 'term.open',
        'sid': session.id,
        'from': 17,
        'routeId': 'current',
        'transport': 'relay',
      });
      await Future<void>.delayed(Duration.zero);
      host.sent.clear();

      host.onFrame({
        't': 'term.close',
        'sid': session.id,
        'from': 17,
        'routeId': 'old',
      });
      expect(host.watching(session.id), isTrue);

      host.onFrame({
        't': 'term.close',
        'sid': session.id,
        'from': 17,
        'routeId': 'current',
      });
      expect(host.watching(session.id), isFalse);
      expect(session.remoteSink, isNull);
      expect(host.sent.where((frame) => frame['t'] == 'term.output'), isEmpty);
    },
  );

  test('active PTY routes have a global memory bound', () async {
    final session = TerminalSession('', '');
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    for (var peer = 1; peer <= 129; peer++) {
      host.onPeer(peer, 'client', true);
      host.onFrame({
        't': 'term.open',
        'sid': session.id,
        'from': peer,
        'routeId': 'route-$peer',
        'transport': 'relay',
        'historyMode': 'none',
      });
    }
    await Future<void>.delayed(Duration.zero);

    final failure = host.sent.lastWhere(
      (frame) => frame['t'] == 'term.routeFailed',
    );
    expect(failure['to'], 129);
    expect(failure['reason'], contains('数量已达上限'));
    expect(failure['code'], 'route_limit');
  });

  test('invalid replacement viewport preserves the active route', () async {
    final session = TerminalSession('', '');
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 17,
      'routeId': 'healthy',
      'transport': 'relay',
      'historyMode': 'none',
    });
    await Future<void>.delayed(Duration.zero);
    host.sent.clear();

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 17,
      'routeId': 'invalid-replacement',
      'transport': 'relay',
      'cols': 501,
      'rows': 24,
    });
    session.remoteSink?.call('still-watched');
    await _flushOutputBatcher();

    expect(host.watching(session.id), isTrue);
    expect(
      host.sent,
      contains(
        allOf(
          containsPair('t', 'term.routeFailed'),
          containsPair('routeId', 'invalid-replacement'),
        ),
      ),
    );
    expect(
      host.sent,
      contains(
        allOf(
          containsPair('t', 'term.output'),
          containsPair('routeId', 'healthy'),
          containsPair('d', 'still-watched'),
        ),
      ),
    );
  });

  test('strict P2P host rejects and removes Relay terminal routes', () async {
    final session = TerminalSession('', '');
    final host = _TestRemoteHost(
      sessions: [session],
      ptyTransportMode: PtyTransportMode.p2p,
    );
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 18,
      'routeId': 'relay-rejected',
      'transport': 'relay',
    });
    await Future<void>.delayed(Duration.zero);
    expect(host.watching(session.id), isFalse);
    expect(host.sent, [
      allOf(
        containsPair('t', 'term.routeFailed'),
        containsPair('code', 'p2p_required'),
      ),
    ]);

    final automatic = _TestRemoteHost(sessions: [session]);
    addTearDown(automatic.dispose);
    automatic.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 19,
      'routeId': 'relay-existing',
      'transport': 'relay',
    });
    await Future<void>.delayed(Duration.zero);
    expect(automatic.watching(session.id), isTrue);

    final transition = automatic.setPtyTransportMode(PtyTransportMode.p2p);
    expect(automatic.watching(session.id), isFalse);
    await transition;
    expect(
      automatic.sent.where((frame) => frame['t'] == 'term.routeFailed'),
      contains(containsPair('code', 'p2p_required')),
    );
  });

  test('P2P send failure never retries terminal output on Relay', () async {
    final session = TerminalSession('', '');
    final factory = _FakePtyPeerFactory();
    final host = _TestRemoteHost(
      sessions: [session],
      ptyTransportMode: PtyTransportMode.p2p,
      ptyPeerFactory: factory,
    );
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);
    final peer = await _connectP2P(host, factory, 15);
    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 15,
      'routeId': 'no-fallback',
      'transport': 'p2p',
    });
    await Future<void>.delayed(Duration.zero);
    peer.sent.clear();
    host.sent.clear();
    peer.sendResult = false;

    session.remoteSink?.call('must-not-leak');
    await _flushOutputBatcher();

    expect(peer.decodedFrames(), isEmpty);
    expect(host.sent.where((f) => f['t'] == 'term.output'), isEmpty);
    expect(host.sent.where((f) => f['t'] == 'term.routeFailed'), isNotEmpty);
    expect(session.remoteSink, isNull);
  });

  test('disconnect disable and dispose all close P2P peers', () async {
    for (final action in ['disconnect', 'disable', 'dispose']) {
      final factory = _FakePtyPeerFactory();
      final host = _TestRemoteHost(
        sessions: const [],
        ptyTransportMode: PtyTransportMode.p2p,
        ptyPeerFactory: factory,
      );
      final peer = await _connectP2P(host, factory, 20);

      switch (action) {
        case 'disconnect':
          host.onDisconnected();
        case 'disable':
          host.disable();
        case 'dispose':
          host.dispose();
      }
      await Future<void>.delayed(Duration.zero);
      expect(peer.closed, isTrue, reason: action);
      if (action != 'dispose') host.dispose();
    }
  });

  test('remote term.open wakes a deferred restored session', () {
    final session = TerminalSession('', '')..deferred = true;
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    var repainted = false;
    host.addListener(() => repainted = true);

    expect(session.started, isFalse);
    expect(session.deferred, isTrue);

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 1,
      'cols': 80,
      'rows': 24,
    });

    expect(session.deferred, isFalse);
    expect(session.started, isTrue);
    expect(session.debugRemoteSize, (rows: 24, cols: 80));
    expect(repainted, isTrue);
  });

  test('remote resize is ignored until that client watches the session', () {
    final session = TerminalSession('', '')..deferred = true;
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    host.onFrame({
      't': 'term.resize',
      'sid': session.id,
      'from': 1,
      'cols': 100,
      'rows': 40,
    });

    expect(session.debugRemoteSize, isNull);
    expect(session.started, isFalse);
  });

  test('dropping the last watcher clears the remote size', () {
    final session = TerminalSession('', '')..deferred = true;
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 1,
      'cols': 80,
      'rows': 24,
    });
    expect(session.debugRemoteSize, (rows: 24, cols: 80));

    host.onPeer(1, 'client', false);

    expect(session.debugRemoteSize, isNull);
  });

  test('watched client resize updates the remote size', () {
    final session = TerminalSession('', '')..deferred = true;
    final host = _TestRemoteHost(sessions: [session]);
    addTearDown(host.dispose);
    addTearDown(host.disposeSessions);

    host.onFrame({
      't': 'term.open',
      'sid': session.id,
      'from': 1,
      'cols': 80,
      'rows': 24,
    });
    host.onFrame({
      't': 'term.resize',
      'sid': session.id,
      'from': 1,
      'cols': 100,
      'rows': 40,
    });

    expect(session.debugRemoteSize, (rows: 40, cols: 100));
  });

  test('todo assign replies ok to the requesting client', () async {
    final host = _TestRemoteHost(
      sessions: const [],
      onAssignTodo: (req) async {
        expect(req['todoId'], 'todo-1');
        return null;
      },
    );
    addTearDown(host.dispose);

    host.onFrame({'t': 'todo.assign', 'from': 7, 'todoId': 'todo-1'});
    await Future<void>.delayed(Duration.zero);

    expect(host.sent, [
      {'t': 'todo.assign.ok', 'to': 7, 'todoId': 'todo-1'},
    ]);
  });

  test('todo assign trims todo id before handler and reply', () async {
    Map<String, dynamic>? seen;
    final host = _TestRemoteHost(
      sessions: const [],
      onAssignTodo: (req) async {
        seen = Map<String, dynamic>.from(req);
        return null;
      },
    );
    addTearDown(host.dispose);

    host.onFrame({'t': 'todo.assign', 'from': 7, 'todoId': ' todo-1 '});
    await Future<void>.delayed(Duration.zero);

    expect(seen?['todoId'], 'todo-1');
    expect(host.sent, [
      {'t': 'todo.assign.ok', 'to': 7, 'todoId': 'todo-1'},
    ]);
  });

  test(
    'todo assign handler exceptions reply err instead of timing out',
    () async {
      final host = _TestRemoteHost(
        sessions: const [],
        onAssignTodo: (_) async => throw StateError('boom'),
      );
      addTearDown(host.dispose);

      host.onFrame({'t': 'todo.assign', 'from': 9, 'todoId': 'todo-2'});
      await Future<void>.delayed(Duration.zero);

      expect(host.sent, hasLength(1));
      expect(host.sent.single['t'], 'todo.assign.err');
      expect(host.sent.single['to'], 9);
      expect(host.sent.single['todoId'], 'todo-2');
      expect(host.sent.single['msg'], contains('boom'));
    },
  );
}
