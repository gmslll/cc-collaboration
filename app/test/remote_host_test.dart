import 'dart:io';
import 'dart:typed_data';

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
  }) : _sessions = sessions,
       super(
         relayUrl: 'http://relay.test',
         token: 'token',
         sessions: (() => sessions),
         roots: (() => roots),
       );

  final List<TerminalSession> _sessions;
  final sent = <Map<String, dynamic>>[];

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
    expect(host.sent, [containsPair('t', 'term.routeFailed')]);

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

    await automatic.setPtyTransportMode(PtyTransportMode.p2p);

    expect(automatic.watching(session.id), isFalse);
    expect(
      automatic.sent.where((frame) => frame['t'] == 'term.routeFailed'),
      isNotEmpty,
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
