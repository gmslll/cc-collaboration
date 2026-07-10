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
    client.onFrame({'t': 'sessions', 'from': 7, 'items': const []});

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

  test(
    'strict P2P does not leak terminal input through Relay before ready',
    () {
      final client = _TestRemoteClient(mode: PtyTransportMode.p2p);
      addTearDown(client.dispose);
      client.onFrame({'t': 'sessions', 'from': 7, 'items': const []});

      client.terminalFor('sid-1');
      client.sendKeys('sid-1', 'dangerous-enter\r');

      expect(client.sent.where((frame) => frame['t'] == 'term.open'), isEmpty);
      expect(client.sent.where((frame) => frame['t'] == 'term.input'), isEmpty);
      expect(client.ptyInputBlocked('sid-1'), isTrue);
    },
  );

  testWidgets('strict P2P locks ready output and input to one route', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
    );
    addTearDown(client.dispose);
    client.onFrame({'t': 'sessions', 'from': 7, 'items': const []});
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

  testWidgets('malformed P2P terminal output fails closed without throwing', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
    );
    addTearDown(client.dispose);
    client.onFrame({'t': 'sessions', 'from': 7, 'items': const []});
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
      client.onFrame({'t': 'sessions', 'from': 7, 'items': const []});
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
      client.onFrame({'t': 'sessions', 'from': 7, 'items': const []});
      client.terminalFor('sid-1');

      await client.setPtyTransportMode(PtyTransportMode.p2p);
      await Future<void>.delayed(Duration.zero);

      expect(socket.closeCount, greaterThanOrEqualTo(1));
      expect(client.ptyInputBlocked('sid-1'), isTrue);
      client.dispose();
    },
  );

  testWidgets('client ignores P2P signaling from a non-host peer', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(peerFactory: factory);
    addTearDown(client.dispose);
    client.onFrame({'t': 'sessions', 'from': 7, 'items': const []});

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

  testWidgets('strict P2P blocks input immediately when the host disconnects', (
    tester,
  ) async {
    final factory = _FakePtyPeerFactory();
    final client = _TestRemoteClient(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
    );
    addTearDown(client.dispose);
    client.onFrame({'t': 'sessions', 'from': 7, 'items': const []});
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
    client.onFrame({'t': 'sessions', 'from': 7, 'items': const []});
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

    factory.peer.callbacks.onState(PtyPeerState.failed, 'network lost');
    await tester.pump();
    await tester.pump();
    expect(
      client.sent.lastWhere((frame) => frame['t'] == 'term.open')['transport'],
      'relay',
    );
    expect(resets, 2);
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
