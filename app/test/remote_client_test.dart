import 'dart:async';
import 'dart:typed_data';

import 'package:app/remote/pty_transport.dart';
import 'package:app/remote/remote_channel.dart';
import 'package:app/remote/remote_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestRemoteClient extends RemoteClient {
  _TestRemoteClient({
    PtyTransportMode mode = PtyTransportMode.auto,
    PtyPeerFactory? peerFactory,
    super.socketConnector,
  }) : super(
         relayUrl: 'http://relay.test',
         token: 'token',
         ptyTransportMode: mode,
         ptyPeerFactory: peerFactory,
       );

  final sent = <Map<String, dynamic>>[];

  @override
  void send(Map<String, dynamic> frame) {
    sent.add(Map<String, dynamic>.from(frame));
  }

  void markHostOnline() {
    onFrame({'t': 'sessions', 'items': const []});
  }
}

class _FakeRemoteSocket implements RemoteSocket {
  final readyCompleter = Completer<void>();
  final controller = StreamController<dynamic>();
  int closeCount = 0;

  @override
  Future<void> get ready => readyCompleter.future;

  @override
  Stream<dynamic> get stream => controller.stream;

  @override
  void add(dynamic data) {}

  @override
  Future<void> close() async {
    closeCount++;
    if (!controller.isClosed) await controller.close();
  }
}

class _FakePtyPeerFactory implements PtyPeerFactory {
  late final _FakePtyPeer peer;
  int createCount = 0;

  @override
  Future<PtyPeer> create({
    required int peerId,
    required bool initiator,
    required PtyPeerCallbacks callbacks,
  }) async {
    createCount++;
    peer = _FakePtyPeer(callbacks);
    return peer;
  }
}

class _FakePtyPeer implements PtyPeer {
  _FakePtyPeer(this.callbacks);

  final PtyPeerCallbacks callbacks;
  final List<List<Uint8List>> sentBatches = [];
  bool closed = false;
  bool sendResult = true;
  Completer<void>? sendGate;
  int activeSends = 0;
  int maxActiveSends = 0;
  Completer<void>? closeGate;

  @override
  Future<PtyDescription> acceptOffer(PtyDescription offer) async {
    callbacks.onState(PtyPeerState.p2p, null);
    return const PtyDescription(type: 'answer', sdp: 'answer-sdp');
  }

  @override
  Future<void> acceptAnswer(PtyDescription answer) async {}

  @override
  Future<void> addIce(PtyIceCandidate candidate) async {}

  @override
  Future<void> close() async {
    closed = true;
    await closeGate?.future;
  }

  @override
  Future<PtyDescription> createOffer() async =>
      const PtyDescription(type: 'offer', sdp: 'offer-sdp');

  @override
  Future<bool> sendPackets(List<Uint8List> packets) async {
    if (closed) return false;
    activeSends++;
    if (activeSends > maxActiveSends) maxActiveSends = activeSends;
    await sendGate?.future;
    activeSends--;
    if (closed || !sendResult) return false;
    sentBatches.add([for (final packet in packets) Uint8List.fromList(packet)]);
    return true;
  }

  void emit(Map<String, dynamic> frame, {int messageId = 1}) {
    for (final packet in PtyPacketCodec.encode(frame, messageId: messageId)) {
      callbacks.onPacket(packet);
    }
  }

  List<Map<String, dynamic>> sentFrames() {
    final reassembler = PtyPacketReassembler();
    final frames = <Map<String, dynamic>>[];
    for (final batch in sentBatches) {
      for (final packet in batch) {
        final frame = reassembler.add(packet);
        if (frame != null) frames.add(frame);
      }
    }
    return frames;
  }
}

Map<String, dynamic> _sessionsFrame(
  int from, [
  List<String> sids = const <String>[],
]) => {
  't': 'sessions',
  'from': from,
  'items': [
    for (final sid in sids)
      {'sid': sid, 'title': sid, 'workdir': '/tmp/$sid', 'agent': 'codex'},
  ],
};

void main() {
  test('remote git create branch includes optional start ref', () {
    final client = _TestRemoteClient();
    addTearDown(client.dispose);

    client.gitCreateBranch('/repo', 'feat/team', start: ' origin/main ');

    expect(client.sent, [
      {
        't': 'git.createBranch',
        'path': '/repo',
        'branch': 'feat/team',
        'start': 'origin/main',
      },
    ]);
  });

  test('remote git create branch omits blank start ref', () {
    final client = _TestRemoteClient();
    addTearDown(client.dispose);

    client.gitCreateBranch('/repo', 'feat/team', start: '   ');

    expect(client.sent, [
      {'t': 'git.createBranch', 'path': '/repo', 'branch': 'feat/team'},
    ]);
  });

  test('remote config commands trim fields before sending frames', () {
    final client = _TestRemoteClient();
    addTearDown(client.dispose);

    client.newWorkspace(' Mobile ', ' /tmp/mobile ');
    client.removeWorkspace(' Mobile ');
    client.addProject(' Team ', ' https://github.com/org/repo.git ');
    client.removeProject(' Team ', ' Backend ');
    client.addWorktree(' Team ', ' Backend ', ' feat/team ', ' origin/main ');
    client.removeWorktree(' Team ', ' Backend ', ' feat/team ');

    expect(client.sent, [
      {'t': 'ws.new', 'name': 'Mobile', 'path': '/tmp/mobile'},
      {'t': 'ws.remove', 'name': 'Mobile'},
      {
        't': 'proj.add',
        'workspace': 'Team',
        'source': 'https://github.com/org/repo.git',
      },
      {'t': 'proj.remove', 'workspace': 'Team', 'project': 'Backend'},
      {
        't': 'wt.add',
        'workspace': 'Team',
        'project': 'Backend',
        'branch': 'feat/team',
        'start': 'origin/main',
      },
      {
        't': 'wt.remove',
        'workspace': 'Team',
        'project': 'Backend',
        'branch': 'feat/team',
        'force': true,
      },
    ]);
  });

  test('remote config commands preserve default workspace and omit blanks', () {
    final client = _TestRemoteClient();
    addTearDown(client.dispose);

    client.newWorkspace(' Mobile ', '   ');
    client.addProject('', ' /repo ');
    client.addWorktree('', ' Backend ', ' feat/team ', '   ');

    expect(client.sent, [
      {'t': 'ws.new', 'name': 'Mobile'},
      {'t': 'proj.add', 'workspace': '', 'source': '/repo'},
      {
        't': 'wt.add',
        'workspace': '',
        'project': 'Backend',
        'branch': 'feat/team',
      },
    ]);
  });

  testWidgets('remote assign fails immediately when the host is offline', (
    tester,
  ) async {
    final client = _TestRemoteClient();
    addTearDown(client.dispose);

    final result = await client.requestAssign(
      todoId: 'todo-1',
      mode: 'existing',
      sid: 'session-1',
    );

    expect(result, '电脑端未在线，请先在电脑端开启「共享工作区」');
    expect(client.sent, isEmpty);
  });

  testWidgets('remote assign supersede cancels the older timeout', (
    tester,
  ) async {
    final client = _TestRemoteClient()..markHostOnline();
    addTearDown(client.dispose);

    final first = client.requestAssign(
      todoId: 'todo-1',
      mode: 'existing',
      sid: 'old-session',
    );
    await tester.pump(const Duration(seconds: 5));
    final second = client.requestAssign(
      todoId: 'todo-1',
      mode: 'existing',
      sid: 'new-session',
    );

    expect(await first, '已被新的指派请求取代');
    var secondDone = false;
    String? secondResult = 'pending';
    second.then((value) {
      secondDone = true;
      secondResult = value;
    });

    await tester.pump(const Duration(seconds: 26));

    expect(secondDone, isFalse);

    client.onFrame({'t': 'todo.assign.ok', 'todoId': 'todo-1'});
    await tester.pump();

    expect(secondDone, isTrue);
    expect(secondResult, isNull);
    expect(client.sent, [
      {
        't': 'todo.assign',
        'todoId': 'todo-1',
        'mode': 'existing',
        'sid': 'old-session',
      },
      {
        't': 'todo.assign',
        'todoId': 'todo-1',
        'mode': 'existing',
        'sid': 'new-session',
      },
    ]);
  });

  testWidgets('remote assign sends relay project id for team scope', (
    tester,
  ) async {
    final client = _TestRemoteClient()..markHostOnline();
    addTearDown(client.dispose);

    final result = client.requestAssign(
      todoId: ' todo-1 ',
      mode: ' new ',
      sid: ' ',
      workspace: ' Team ',
      project: ' Backend ',
      projectId: ' relay-project ',
      kind: ' claude ',
      branch: ' feat/team ',
    );
    await tester.pump();

    expect(client.sent.single, {
      't': 'todo.assign',
      'todoId': 'todo-1',
      'mode': 'new',
      'workspace': 'Team',
      'project': 'Backend',
      'projectId': 'relay-project',
      'kind': 'claude',
      'branch': 'feat/team',
    });
    client.onFrame({'t': 'todo.assign.ok', 'todoId': 'todo-1'});
    await tester.pump();
    expect(await result, isNull);
  });

  test('Relay mode opens and drives a terminal only through Relay', () {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(
      mode: PtyTransportMode.relay,
      peerFactory: factory,
    );
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));

    client.terminalFor('sid-1');
    client.sendKeys('sid-1', 'x');

    final open = client.sent.firstWhere((frame) => frame['t'] == 'term.open');
    final input = client.sent.firstWhere((frame) => frame['t'] == 'term.input');
    expect(open['transport'], 'relay');
    expect(open['to'], 7);
    expect(input['routeId'], open['routeId']);
    expect(input['seq'], 1);
    expect(input['to'], 7);
  });

  test('quick reply opens an input route on first use and after close', () {
    final client = _TestRemoteClient(mode: PtyTransportMode.relay);
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));

    expect(client.beginQuickReply('sid-1'), isTrue);
    expect(client.sendKeys('sid-1', 'y'), isTrue);
    client.endQuickReply('sid-1');
    expect(client.beginQuickReply('sid-1'), isTrue);

    final opens = client.sent
        .where((frame) => frame['t'] == 'term.open')
        .toList();
    expect(opens, hasLength(2));
    expect(opens.every((frame) => frame['historyMode'] == 'none'), isTrue);
    final input = client.sent.singleWhere(
      (frame) => frame['t'] == 'term.input',
    );
    expect(input['to'], 7);
    expect(input['routeId'], opens.first['routeId']);
  });

  testWidgets(
    'quick reply reuses a full Relay route and auxiliary frames share its sequence',
    (tester) async {
      final client = _TestRemoteClient(mode: PtyTransportMode.relay);
      addTearDown(client.dispose);
      client.onFrame(_sessionsFrame(7, ['sid-1']));
      final terminal = client.terminalFor('sid-1');
      final open = client.sent.singleWhere(
        (frame) => frame['t'] == 'term.open',
      );

      expect(client.beginQuickReply('sid-1'), isTrue);
      expect(client.requestScreen('sid-1'), isTrue);
      expect(
        client.sent.where((frame) => frame['t'] == 'term.open'),
        hasLength(1),
      );
      final request = client.sent.singleWhere(
        (frame) => frame['t'] == 'screen',
      );
      expect(request['routeId'], open['routeId']);
      expect(request['seq'], 1);

      client.onFrame({
        't': 'screen',
        'from': 7,
        'sid': 'sid-1',
        'routeId': open['routeId'],
        'seq': 1,
        'requestId': request['requestId'],
        'text': 'snapshot',
        'cols': 80,
        'rows': 24,
      });
      client.onFrame({
        't': 'term.output',
        'from': 7,
        'sid': 'sid-1',
        'routeId': open['routeId'],
        'seq': 2,
        'd': 'after-snapshot',
      });
      await tester.pump(const Duration(milliseconds: 220));

      expect(client.screens['sid-1']?.ansi, 'snapshot');
      expect(terminal.buffer.getText(), contains('after-snapshot'));
      expect(
        client.sent.where((frame) => frame['t'] == 'term.open'),
        hasLength(1),
      );
      client.endQuickReply('sid-1');
      expect(client.sendKeys('sid-1', 'x'), isTrue);
    },
  );

  test(
    'strict P2P does not leak terminal input through Relay before ready',
    () {
      final client = _TestRemoteClient(mode: PtyTransportMode.p2p);
      addTearDown(client.dispose);
      client.onFrame(_sessionsFrame(7, ['sid-1']));

      client.terminalFor('sid-1');
      client.sendKeys('sid-1', 'dangerous-enter\r');

      expect(client.sent.where((frame) => frame['t'] == 'term.open'), isEmpty);
      expect(client.sent.where((frame) => frame['t'] == 'term.input'), isEmpty);
      expect(client.ptyInputBlocked('sid-1'), isTrue);
      expect(client.ptyRouteStatusText('sid-1'), contains('暂存 1 条'));
    },
  );

  testWidgets('opening strict P2P route flushes queued input in order', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
    );
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.terminalFor('sid-1');

    expect(client.sendKeys('sid-1', 'first'), isTrue);
    expect(client.sendKeys('sid-1', 'second'), isTrue);
    client.onFrame({
      't': ptySignalFrameType,
      'from': 7,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'offer-sdp'},
    });
    await tester.pump();
    final open = client.sent.lastWhere((frame) => frame['t'] == 'term.open');
    factory.peer.emit({
      't': 'term.ready',
      'sid': 'sid-1',
      'routeId': open['routeId'],
    });
    await tester.pump();

    expect(
      factory.peer
          .sentFrames()
          .where((frame) => frame['t'] == 'term.input')
          .map((frame) => frame['d']),
      ['first', 'second'],
    );
    expect(client.ptyRouteStatusText('sid-1'), isNull);
  });

  testWidgets('P2P route serializes a full pending input queue', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
    );
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.terminalFor('sid-1');
    for (var i = 0; i < 64; i++) {
      expect(client.sendKeys('sid-1', '$i,'), isTrue);
    }
    client.onFrame({
      't': ptySignalFrameType,
      'from': 7,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'offer-sdp'},
    });
    await tester.pump();
    final open = client.sent.lastWhere((frame) => frame['t'] == 'term.open');
    factory.peer.sendGate = Completer<void>();
    factory.peer.emit({
      't': 'term.ready',
      'sid': 'sid-1',
      'routeId': open['routeId'],
    });
    await tester.pump();
    expect(factory.peer.activeSends, 1);
    expect(factory.peer.maxActiveSends, 1);

    factory.peer.sendGate!.complete();
    await tester.pumpAndSettle();
    final inputs = factory.peer
        .sentFrames()
        .where((frame) => frame['t'] == 'term.input')
        .toList();
    expect(inputs, hasLength(64));
    expect(inputs.map((frame) => frame['d']), [
      for (var i = 0; i < 64; i++) '$i,',
    ]);
    expect(factory.peer.maxActiveSends, 1);
  });

  testWidgets('quick reply closes after its confirmed P2P input', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
    );
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.onFrame({
      't': ptySignalFrameType,
      'from': 7,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'offer-sdp'},
    });
    await tester.pump();
    client.beginQuickReply('sid-1');
    final open = client.sent.lastWhere((frame) => frame['t'] == 'term.open');
    factory.peer.emit({
      't': 'term.ready',
      'sid': 'sid-1',
      'routeId': open['routeId'],
    });
    factory.peer.sendGate = Completer<void>();
    final delivered = client.sendKeysConfirmed('sid-1', 'y\r');
    await tester.pump();
    client.endQuickReply('sid-1');
    expect(client.sent.where((frame) => frame['t'] == 'term.close'), isEmpty);

    factory.peer.sendGate!.complete();
    expect(await delivered, isTrue);
    await tester.pumpAndSettle();
    expect(factory.peer.sentFrames().map((frame) => frame['t']), [
      'term.input',
      'term.close',
    ]);
  });

  testWidgets('P2P input budget reserves an ordered close without data loss', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
    );
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.onFrame({
      't': ptySignalFrameType,
      'from': 7,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'offer-sdp'},
    });
    await tester.pump();
    expect(client.beginQuickReply('sid-1'), isTrue);
    final open = client.sent.lastWhere((frame) => frame['t'] == 'term.open');
    factory.peer.emit({
      't': 'term.ready',
      'sid': 'sid-1',
      'routeId': open['routeId'],
    });
    factory.peer.sendGate = Completer<void>();

    for (var i = 0; i < 64; i++) {
      expect(client.sendKeys('sid-1', '$i,'), isTrue);
    }
    expect(client.sendKeys('sid-1', 'overflow'), isFalse);
    await tester.pump();
    expect(factory.peer.activeSends, 1);

    client.endQuickReply('sid-1');
    factory.peer.sendGate!.complete();
    await tester.pumpAndSettle();

    final frames = factory.peer.sentFrames();
    expect(frames.where((frame) => frame['t'] == 'term.input'), hasLength(64));
    expect(frames.last['t'], 'term.close');
    expect(client.sent.where((frame) => frame['t'] == 'term.input'), isEmpty);
  });

  testWidgets(
    'a failed confirmed input is never replayed after mode recovery',
    (tester) async {
      final factory = _FakePtyPeerFactory();
      final client = _TestRemoteClient(
        mode: PtyTransportMode.p2p,
        peerFactory: factory,
      );
      addTearDown(client.dispose);
      client.onFrame(_sessionsFrame(7, ['sid-1']));
      client.onFrame({
        't': ptySignalFrameType,
        'from': 7,
        'kind': 'offer',
        'epoch': 1,
        'description': {'type': 'offer', 'sdp': 'offer-sdp'},
      });
      await tester.pump();
      client.beginQuickReply('sid-1');
      final open = client.sent.lastWhere((frame) => frame['t'] == 'term.open');
      factory.peer.emit({
        't': 'term.ready',
        'sid': 'sid-1',
        'routeId': open['routeId'],
      });
      factory.peer.sendGate = Completer<void>();
      expect(client.sendKeys('sid-1', 'accepted-unconfirmed'), isTrue);
      final confirmed = client.sendKeysConfirmed('sid-1', 'must-not-replay');
      await tester.pump();

      final switching = client.setPtyTransportMode(PtyTransportMode.relay);
      expect(await confirmed, isFalse);
      factory.peer.sendGate!.complete();
      await switching;
      await tester.pumpAndSettle();

      final relayInputs = client.sent
          .where((frame) => frame['t'] == 'term.input')
          .map((frame) => frame['d']);
      expect(relayInputs, isNot(contains('must-not-replay')));
    },
  );

  testWidgets('mode switch completes an in-flight confirmed input promptly', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
    );
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.onFrame({
      't': ptySignalFrameType,
      'from': 7,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'offer-sdp'},
    });
    await tester.pump();
    client.beginQuickReply('sid-1');
    final open = client.sent.lastWhere((frame) => frame['t'] == 'term.open');
    factory.peer.emit({
      't': 'term.ready',
      'sid': 'sid-1',
      'routeId': open['routeId'],
    });
    factory.peer.sendGate = Completer<void>();

    final confirmed = client.sendKeysConfirmed('sid-1', 'in-flight');
    await tester.pump();
    expect(factory.peer.activeSends, 1);
    final switching = client.setPtyTransportMode(PtyTransportMode.relay);

    expect(await confirmed.timeout(const Duration(milliseconds: 100)), isFalse);
    factory.peer.sendGate!.complete();
    await switching;
  });

  testWidgets('quick reply rejects a delayed snapshot from its prior popup', (
    tester,
  ) async {
    final client = _TestRemoteClient(mode: PtyTransportMode.relay);
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.terminalFor('sid-1');
    final open = client.sent.singleWhere((frame) => frame['t'] == 'term.open');

    client.beginQuickReply('sid-1');
    client.requestScreen('sid-1');
    final firstRequest = client.sent.lastWhere(
      (frame) => frame['t'] == 'screen',
    );
    client.endQuickReply('sid-1');
    client.beginQuickReply('sid-1');
    client.requestScreen('sid-1');
    final secondRequest = client.sent.lastWhere(
      (frame) => frame['t'] == 'screen',
    );
    expect(secondRequest['requestId'], isNot(firstRequest['requestId']));

    client.onFrame({
      't': 'screen',
      'from': 7,
      'sid': 'sid-1',
      'routeId': open['routeId'],
      'seq': 1,
      'requestId': firstRequest['requestId'],
      'text': 'stale approval prompt',
      'cols': 80,
      'rows': 24,
    });
    expect(client.hasFreshScreen('sid-1'), isFalse);

    client.onFrame({
      't': 'screen',
      'from': 7,
      'sid': 'sid-1',
      'routeId': open['routeId'],
      'seq': 2,
      'requestId': secondRequest['requestId'],
      'text': 'current approval prompt',
      'cols': 80,
      'rows': 24,
    });
    await tester.pump();
    expect(client.hasFreshScreen('sid-1'), isTrue);
    expect(client.screens['sid-1']?.ansi, 'current approval prompt');
  });

  test(
    'quick reply explains when an old Host cannot echo snapshot identity',
    () {
      final client = _TestRemoteClient(mode: PtyTransportMode.relay);
      addTearDown(client.dispose);
      client.onFrame(_sessionsFrame(7, ['sid-1']));
      client.beginQuickReply('sid-1');
      client.requestScreen('sid-1');
      final open = client.sent.singleWhere(
        (frame) => frame['t'] == 'term.open',
      );

      client.onFrame({
        't': 'screen',
        'from': 7,
        'sid': 'sid-1',
        'routeId': open['routeId'],
        'seq': 1,
        'text': 'unidentified old-host snapshot',
        'cols': 80,
        'rows': 24,
      });

      expect(client.hasFreshScreen('sid-1'), isFalse);
      expect(client.ptyRouteStatusText('sid-1'), contains('版本过旧'));
    },
  );

  testWidgets('P2P route open has an independent ready deadline', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
    );
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.onFrame({
      't': ptySignalFrameType,
      'from': 7,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'offer-sdp'},
    });
    await tester.pump();
    client.terminalFor('sid-1');

    await tester.pump(const Duration(seconds: 16));

    expect(client.ptyInputBlocked('sid-1'), isTrue);
    expect(client.ptyRouteStatusText('sid-1'), contains('超时'));
    expect(client.ptyPeerState, PtyPeerState.p2p);
  });

  test('opening route input queue is bounded and reports overflow', () {
    final client = _TestRemoteClient(mode: PtyTransportMode.p2p);
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.terminalFor('sid-1');

    for (var i = 0; i < 64; i++) {
      expect(client.sendKeys('sid-1', 'x'), isTrue);
    }
    expect(client.sendKeys('sid-1', 'overflow'), isFalse);
    expect(client.ptyRouteStatusText('sid-1'), contains('待发送输入过多'));
  });

  testWidgets('strict P2P locks ready output and input to one route', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
    );
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.onFrame({
      't': ptySignalFrameType,
      'from': 7,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'offer-sdp'},
    });
    await tester.pump();

    final term = client.terminalFor('sid-1');
    final open = client.sent.lastWhere((frame) => frame['t'] == 'term.open');
    final routeId = open['routeId'] as String;
    expect(open['transport'], 'p2p');
    client.defaultViewport = (cols: 80, rows: 24);
    expect(client.adoptSize('sid-1'), 'transport-blocked');

    factory.peer.emit({'t': 'term.ready', 'sid': 'sid-1', 'routeId': routeId});
    client.sendKeys('sid-1', 'x');
    await tester.pump();
    expect(client.ptyInputBlocked('sid-1'), isFalse);
    expect(client.sent.where((frame) => frame['t'] == 'term.input'), isEmpty);
    expect(factory.peer.sentFrames(), [
      {
        't': 'term.resize',
        'sid': 'sid-1',
        'rows': 24,
        'cols': 80,
        'routeId': routeId,
        'seq': 1,
      },
      {
        't': 'term.input',
        'sid': 'sid-1',
        'd': 'x',
        'routeId': routeId,
        'seq': 2,
      },
    ]);

    factory.peer.emit({
      't': 'term.output',
      'sid': 'sid-1',
      'routeId': routeId,
      'seq': 1,
      'd': 'hello',
    }, messageId: 2);
    factory.peer.emit({
      't': 'term.output',
      'sid': 'sid-1',
      'routeId': routeId,
      'seq': 1,
      'd': 'duplicate',
    }, messageId: 3);
    expect(term.buffer.getText(), contains('hello'));
    expect(term.buffer.getText(), isNot(contains('duplicate')));
  });

  test('strict screen request never falls back to Relay', () {
    final client = _TestRemoteClient(mode: PtyTransportMode.p2p);
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.beginQuickReply('sid-1');

    expect(client.requestScreen('sid-1'), isFalse);
    expect(client.sent.where((frame) => frame['t'] == 'screen'), isEmpty);
    expect(client.ptyRouteStatusText('sid-1'), contains('路由尚未就绪'));
  });

  testWidgets('malformed P2P terminal output fails closed without throwing', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
    );
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.onFrame({
      't': ptySignalFrameType,
      'from': 7,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'offer-sdp'},
    });
    await tester.pump();

    client.terminalFor('sid-1');
    final open = client.sent.lastWhere((frame) => frame['t'] == 'term.open');
    final routeId = open['routeId'] as String;
    factory.peer.emit({'t': 'term.ready', 'sid': 'sid-1', 'routeId': routeId});

    factory.peer.emit({
      't': 'term.output',
      'sid': 'sid-1',
      'routeId': routeId,
      'seq': 1,
      'd': 42,
    }, messageId: 2);
    await tester.pump();

    expect(client.ptyInputBlocked('sid-1'), isTrue);
    expect(client.ptyError, contains('内容类型'));
  });

  test(
    'switching from Relay to strict P2P closes the Relay route first',
    () async {
      final client = _TestRemoteClient(mode: PtyTransportMode.relay);
      client.onFrame(_sessionsFrame(7, ['sid-1']));
      client.terminalFor('sid-1');
      final open = client.sent.lastWhere((frame) => frame['t'] == 'term.open');

      await client.setPtyTransportMode(PtyTransportMode.p2p);

      final close = client.sent.lastWhere(
        (frame) => frame['t'] == 'term.close',
      );
      expect(close['to'], 7);
      expect(close['sid'], 'sid-1');
      expect(close['routeId'], open['routeId']);
      expect(
        client.sent
            .skip(client.sent.indexOf(close) + 1)
            .where((frame) => frame['t'] == 'term.open'),
        isEmpty,
      );
      expect(client.ptyInputBlocked('sid-1'), isTrue);
      client.dispose();
    },
  );

  test('strict P2P ignores late route-less Relay terminal content', () async {
    final client = _TestRemoteClient(mode: PtyTransportMode.relay);
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    final terminal = client.terminalFor('sid-1');

    await client.setPtyTransportMode(PtyTransportMode.p2p);
    client.onFrame({
      't': 'term.output',
      'from': 7,
      'sid': 'sid-1',
      'd': 'relay-secret',
    });
    client.onFrame({
      't': 'screen',
      'from': 7,
      'sid': 'sid-1',
      'text': 'relay-screen-secret',
    });

    expect(terminal.buffer.getText(), isNot(contains('relay-secret')));
    expect(client.screens['sid-1'], isNull);
  });

  test('strict P2P strips content from Relay overview', () {
    final client = _TestRemoteClient(mode: PtyTransportMode.p2p);
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.onFrame({
      't': 'overview',
      'from': 7,
      'items': [
        {
          'sid': 'sid-1',
          'label': 'Secret',
          'agent': 'codex',
          'isAgent': true,
          'ws': 'ws',
          'proj': 'proj',
          'status': 'working',
          'statusDetail': 'private status',
          'usage': '10%',
          'preview': 'private output',
          'recentActivity': [
            {'kind': 'tool', 'text': 'private command'},
          ],
        },
      ],
    });

    final card = client.overview['sid-1']!;
    expect(card.preview, isEmpty);
    expect(card.statusDetail, isEmpty);
    expect(card.recentActivity, isEmpty);
  });

  test(
    'strict discovery sends capability mode without requesting old host data',
    () {
      final client = _TestRemoteClient(mode: PtyTransportMode.p2p);
      addTearDown(client.dispose);

      client.onConnected();

      expect(client.sent.where((frame) => frame['t'] == 'list'), isEmpty);
      expect(
        client.sent,
        contains(
          allOf(
            containsPair('t', ptySignalFrameType),
            containsPair('kind', 'mode'),
          ),
        ),
      );
    },
  );

  test('closed route ignores delayed modern Relay metadata', () {
    final client = _TestRemoteClient(mode: PtyTransportMode.relay);
    addTearDown(client.dispose);
    var replies = 0;
    var statuses = 0;
    client.onReplyText = (_, _) => replies++;
    client.onAgentStatus = (_, _, _, _) => statuses++;
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    final terminal = client.terminalFor('sid-1');
    final open = client.sent.lastWhere((frame) => frame['t'] == 'term.open');
    client.onFrame(_sessionsFrame(7));

    for (final frame in [
      {'t': 'term.output', 'd': 'stale'},
      {'t': 'screen', 'text': 'stale'},
      {'t': 'reply', 'text': 'stale'},
      {'t': 'status', 'working': true, 'text': 'stale'},
      {'t': 'activity', 'items': const []},
    ]) {
      client.onFrame({
        ...frame,
        'from': 7,
        'sid': 'sid-1',
        'routeId': open['routeId'],
        'seq': 1,
      });
    }

    expect(terminal.buffer.getText(), isNot(contains('stale')));
    expect(client.screens['sid-1'], isNull);
    expect(replies, 0);
    expect(statuses, 0);
  });

  testWidgets('auto route send failure reopens through Relay', (tester) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(peerFactory: factory);
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.onFrame({
      't': ptySignalFrameType,
      'from': 7,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'offer-sdp'},
    });
    await tester.pump();
    client.terminalFor('sid-1');
    final p2pOpen = client.sent.lastWhere((frame) => frame['t'] == 'term.open');
    factory.peer.emit({
      't': 'term.ready',
      'sid': 'sid-1',
      'routeId': p2pOpen['routeId'],
    });
    factory.peer.sendResult = false;
    expect(client.sendKeys('sid-1', 'x'), isTrue);

    await tester.pumpAndSettle();

    final recovered = client.sent.lastWhere(
      (frame) => frame['t'] == 'term.open',
    );
    expect(recovered['transport'], 'relay');
    expect(client.ptyPeerState, isNot(PtyPeerState.p2p));
    expect(client.ptyRouteStatusText('sid-1'), contains('可能未送达'));
    expect(client.ptyRouteNeedsAttention('sid-1'), isTrue);
    client.acknowledgePtyDeliveryWarning('sid-1');
    expect(client.hasPtyDeliveryWarning('sid-1'), isFalse);
    expect(client.ptyRouteNeedsAttention('sid-1'), isFalse);
  });

  test('p2p-required failure does not spin Relay route reopen', () {
    final client = _TestRemoteClient();
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.terminalFor('sid-1');
    final open = client.sent.lastWhere((frame) => frame['t'] == 'term.open');

    client.onFrame({
      't': 'term.routeFailed',
      'from': 7,
      'sid': 'sid-1',
      'routeId': open['routeId'],
      'code': 'p2p_required',
      'reason': '电脑要求使用 P2P 终端传输',
    });

    expect(
      client.sent.where((frame) => frame['t'] == 'term.open'),
      hasLength(1),
    );
    expect(client.ptyRouteStatusText('sid-1'), contains('P2P'));
  });

  testWidgets('route-limit failure stays failed without a reopen loop', (
    tester,
  ) async {
    final client = _TestRemoteClient(mode: PtyTransportMode.relay);
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.terminalFor('sid-1');
    final open = client.sent.lastWhere((frame) => frame['t'] == 'term.open');

    client.onFrame({
      't': 'term.routeFailed',
      'from': 7,
      'sid': 'sid-1',
      'routeId': open['routeId'],
      'code': 'route_limit',
      'reason': '终端路由数量已达上限',
    });
    await tester.pump();

    expect(
      client.sent.where((frame) => frame['t'] == 'term.open'),
      hasLength(1),
    );
    expect(client.ptyRouteStatusText('sid-1'), contains('数量已达上限'));
  });

  test(
    'strict P2P selection reconnects Relay to evict legacy host watchers',
    () async {
      final socket = _FakeRemoteSocket();
      final client = _TestRemoteClient(
        mode: PtyTransportMode.relay,
        socketConnector: (_, _) => socket,
      );
      client.connect();
      socket.readyCompleter.complete();
      await Future<void>.delayed(Duration.zero);
      expect(client.connected, isTrue);
      client.onFrame(_sessionsFrame(7, ['sid-1']));
      client.terminalFor('sid-1');

      await client.setPtyTransportMode(PtyTransportMode.p2p);
      await Future<void>.delayed(Duration.zero);

      expect(client.sent, contains(containsPair('t', 'pty.strictBarrier')));
      expect(socket.closeCount, greaterThanOrEqualTo(1));
      expect(client.ptyInputBlocked('sid-1'), isTrue);
      client.dispose();
    },
  );

  test('auto to strict reconnects even with no current Relay route', () async {
    final socket = _FakeRemoteSocket();
    final client = _TestRemoteClient(socketConnector: (_, _) => socket);
    client.connect();
    socket.readyCompleter.complete();
    await Future<void>.delayed(Duration.zero);
    client.onFrame(_sessionsFrame(7));

    await client.setPtyTransportMode(PtyTransportMode.p2p);
    await Future<void>.delayed(Duration.zero);

    expect(socket.closeCount, greaterThanOrEqualTo(1));
    client.dispose();
  });

  testWidgets('client ignores P2P signaling from a non-host peer', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(peerFactory: factory);
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));

    client.onFrame({
      't': ptySignalFrameType,
      'from': 8,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'spoof'},
    });
    await tester.pump();

    expect(factory.createCount, 0);
  });

  testWidgets(
    'strict P2P rotates from an unavailable Host to an offering Host',
    (tester) async {
      final factory = _FakePtyPeerFactory();
      final client = _TestRemoteClient(
        mode: PtyTransportMode.p2p,
        peerFactory: factory,
      );
      addTearDown(client.dispose);
      client.onPeer(7, 'host', true);
      client.onPeer(8, 'host', true);

      client.onFrame({
        't': ptySignalFrameType,
        'from': 8,
        'kind': 'offer',
        'epoch': 1,
        'description': {'type': 'offer', 'sdp': 'first-offer'},
      });
      expect(
        client.sent.where(
          (frame) =>
              frame['t'] == ptySignalFrameType &&
              frame['kind'] == 'close' &&
              frame['to'] == 8,
        ),
        hasLength(1),
      );

      await tester.pump(const Duration(seconds: 4));
      expect(
        client.sent.where(
          (frame) =>
              frame['t'] == ptySignalFrameType &&
              frame['kind'] == 'mode' &&
              frame['to'] == 8,
        ),
        isNotEmpty,
      );
      client.onFrame({
        't': ptySignalFrameType,
        'from': 8,
        'kind': 'offer',
        'epoch': 2,
        'description': {'type': 'offer', 'sdp': 'retry-offer'},
      });
      await tester.pump();

      expect(factory.createCount, 1);
      expect(client.ptyPeerState, PtyPeerState.p2p);
    },
  );

  testWidgets('strict P2P blocks input immediately when the host disconnects', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
    );
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.onFrame({
      't': ptySignalFrameType,
      'from': 7,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'offer-sdp'},
    });
    await tester.pump();
    client.terminalFor('sid-1');
    final routeId = client.sent.lastWhere(
      (frame) => frame['t'] == 'term.open',
    )['routeId'];
    factory.peer.emit({'t': 'term.ready', 'sid': 'sid-1', 'routeId': routeId});
    expect(client.ptyInputBlocked('sid-1'), isFalse);

    client.onPeer(7, 'host', false);

    expect(client.ptyInputBlocked('sid-1'), isTrue);
    expect(client.ptyError, contains('断开'));
    expect(client.ptyPeerState, PtyPeerState.closed);
  });

  testWidgets('retry completion cannot revive a disposed P2P client', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
    );
    client.onFrame({'t': 'sessions', 'from': 7, 'items': const []});
    client.onFrame({
      't': ptySignalFrameType,
      'from': 7,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'offer-sdp'},
    });
    await tester.pump();
    final gate = Completer<void>();
    factory.peer.closeGate = gate;

    final retry = client.retryP2P();
    await tester.pump();
    client.dispose();
    gate.complete();
    await retry;
    await tester.pump();

    expect(factory.createCount, 1);
  });

  testWidgets('automatic mode reopens routes for P2P and Relay recovery', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(peerFactory: factory);
    addTearDown(client.dispose);
    var resets = 0;
    client.onTerminalReset = () => resets++;
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.terminalFor('sid-1');
    expect(
      client.sent.lastWhere((frame) => frame['t'] == 'term.open')['transport'],
      'relay',
    );

    client.onFrame({
      't': ptySignalFrameType,
      'from': 7,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'offer-sdp'},
    });
    await tester.pump();
    expect(
      client.sent.lastWhere((frame) => frame['t'] == 'term.open')['transport'],
      'p2p',
    );
    expect(resets, 1);
    expect(client.sendKeys('sid-1', 'queued-during-upgrade'), isTrue);
    expect(factory.peer.sentFrames(), isEmpty);
    final p2pOpen = client.sent.lastWhere((frame) => frame['t'] == 'term.open');
    factory.peer.emit({
      't': 'term.ready',
      'sid': 'sid-1',
      'routeId': p2pOpen['routeId'],
    });
    await tester.pump();
    expect(
      factory.peer.sentFrames().singleWhere(
        (frame) => frame['t'] == 'term.input',
      )['d'],
      'queued-during-upgrade',
    );

    factory.peer.callbacks.onState(PtyPeerState.failed, 'network lost');
    await tester.pump();
    await tester.pump();
    expect(
      client.sent.lastWhere((frame) => frame['t'] == 'term.open')['transport'],
      'relay',
    );
    expect(resets, 2);
  });

  testWidgets('Relay output reorders briefly before rebuilding a gap', (
    tester,
  ) async {
    final client = _TestRemoteClient(mode: PtyTransportMode.relay);
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    final terminal = client.terminalFor('sid-1');
    var resets = 0;
    client.onTerminalReset = () => resets++;
    final firstOpen = client.sent.lastWhere(
      (frame) => frame['t'] == 'term.open',
    );

    client.onFrame({
      't': 'term.output',
      'from': 7,
      'sid': 'sid-1',
      'routeId': firstOpen['routeId'],
      'seq': 2,
      'd': 'second',
    });
    client.onFrame({
      't': 'term.output',
      'from': 7,
      'sid': 'sid-1',
      'routeId': firstOpen['routeId'],
      'seq': 1,
      'd': 'first',
    });
    expect(terminal.buffer.getText(), contains('firstsecond'));

    client.reloadTerminal('sid-1');
    final gapOpen = client.sent.lastWhere((frame) => frame['t'] == 'term.open');
    client.onFrame({
      't': 'term.output',
      'from': 7,
      'sid': 'sid-1',
      'routeId': gapOpen['routeId'],
      'seq': 2,
      'd': 'gap',
    });
    await tester.pump(const Duration(milliseconds: 181));
    await tester.pump();

    final recoveredOpen = client.sent.lastWhere(
      (frame) => frame['t'] == 'term.open',
    );
    expect(recoveredOpen['routeId'], isNot(gapOpen['routeId']));
    expect(recoveredOpen['to'], 7);
    expect(resets, 1);
  });

  test('Relay routeFailed rebuilds the route instead of freezing it', () async {
    final client = _TestRemoteClient(mode: PtyTransportMode.relay);
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.terminalFor('sid-1');
    final first = client.sent.singleWhere((frame) => frame['t'] == 'term.open');

    client.onFrame({
      't': 'term.routeFailed',
      'from': 7,
      'sid': 'sid-1',
      'routeId': first['routeId'],
      'reason': 'Relay 输出队列已满',
    });
    await Future<void>.delayed(Duration.zero);

    final opens = client.sent
        .where((frame) => frame['t'] == 'term.open')
        .toList();
    expect(opens, hasLength(2));
    expect(opens.last['routeId'], isNot(first['routeId']));
    expect(client.ptyInputBlocked('sid-1'), isFalse);
  });

  test('host selection is stable and terminal routes stay owner-bound', () {
    final client = _TestRemoteClient(mode: PtyTransportMode.relay);
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.onPeer(8, 'host', true);
    client.terminalFor('sid-1');
    final routeId = client.sent.lastWhere(
      (frame) => frame['t'] == 'term.open',
    )['routeId'];
    client.onFrame(_sessionsFrame(8, ['other']));
    expect(client.sessions.map((session) => session.sid), ['sid-1']);
    client.onFrame({
      't': 'term.output',
      'from': 8,
      'sid': 'sid-1',
      'routeId': routeId,
      'seq': 1,
      'd': 'wrong-host-output',
    });
    expect(
      client.terminalFor('sid-1').buffer.getText(),
      isNot(contains('wrong-host-output')),
    );

    expect(client.sendKeys('sid-1', 'owner-only'), isTrue);
    expect(
      client.sent.lastWhere((frame) => frame['t'] == 'term.input')['to'],
      7,
    );
    client.onPeer(8, 'host', false);
    expect(client.hostOnline, isTrue);
  });

  test(
    'current host failover waits for snapshot and preserves valid input',
    () {
      final client = _TestRemoteClient(mode: PtyTransportMode.relay);
      addTearDown(client.dispose);
      client.onFrame(_sessionsFrame(7, ['sid-1']));
      client.onPeer(8, 'host', true);
      client.terminalFor('sid-1');

      client.onPeer(7, 'host', false);
      expect(client.sessions, isEmpty);
      expect(client.sendKeys('sid-1', 'during-switch'), isTrue);
      expect(
        client.sent.where(
          (frame) => frame['t'] == 'term.input' && frame['to'] == 8,
        ),
        isEmpty,
      );
      client.onFrame(_sessionsFrame(8, ['sid-1']));

      expect(
        client.sent.lastWhere((frame) => frame['t'] == 'term.open')['to'],
        8,
      );
      final input = client.sent.lastWhere(
        (frame) => frame['t'] == 'term.input',
      );
      expect(input['to'], 8);
      expect(input['d'], 'during-switch');
    },
  );

  test('current host failover drops input for a missing session', () {
    final client = _TestRemoteClient(mode: PtyTransportMode.relay);
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.onPeer(8, 'host', true);
    client.terminalFor('sid-1');
    client.onPeer(7, 'host', false);
    expect(client.sendKeys('sid-1', 'must-not-cross-hosts'), isTrue);

    client.onFrame(_sessionsFrame(8));

    expect(
      client.sent.where(
        (frame) => frame['t'] == 'term.input' && frame['to'] == 8,
      ),
      isEmpty,
    );
    expect(client.ptyRouteStatusText('sid-1'), contains('没有此会话'));
  });

  test('session removal closes its owner route and rejects later input', () {
    final client = _TestRemoteClient(mode: PtyTransportMode.relay);
    addTearDown(client.dispose);
    client.onFrame(_sessionsFrame(7, ['sid-1']));
    client.terminalFor('sid-1');
    final open = client.sent.lastWhere((frame) => frame['t'] == 'term.open');

    client.onFrame(_sessionsFrame(7));

    final close = client.sent.lastWhere((frame) => frame['t'] == 'term.close');
    expect(close['to'], 7);
    expect(close['routeId'], open['routeId']);
    expect(client.sendKeys('sid-1', 'late-input'), isFalse);
    expect(client.ptyInputBlocked('sid-1'), isTrue);
    expect(client.ptyRouteStatusText('sid-1'), contains('没有此会话'));
  });

  testWidgets('remote assign completes when the client is disposed', (
    tester,
  ) async {
    final client = _TestRemoteClient()..markHostOnline();

    final result = client.requestAssign(
      todoId: 'todo-1',
      mode: 'existing',
      sid: 'session-1',
    );
    client.dispose();

    expect(await result, '连接已关闭');
    await tester.pump(const Duration(seconds: 31));
  });
}
