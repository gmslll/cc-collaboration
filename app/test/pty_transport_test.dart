import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/remote/pty_transport.dart';
import 'package:app/remote/pty_transport_webrtc.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePeerFactory implements PtyPeerFactory {
  _FakePeerFactory({this.onCreate});

  final void Function(_FakePeer peer)? onCreate;
  final List<_FakePeer> peers = [];

  @override
  Future<PtyPeer> create({
    required int peerId,
    required bool initiator,
    required PtyPeerCallbacks callbacks,
  }) async {
    final peer = _FakePeer(peerId, initiator, callbacks);
    onCreate?.call(peer);
    peers.add(peer);
    return peer;
  }
}

class _FakePeer implements PtyPeer {
  _FakePeer(this.peerId, this.initiator, this.callbacks);

  final int peerId;
  final bool initiator;
  final PtyPeerCallbacks callbacks;
  final List<PtyIceCandidate> ice = [];
  final List<List<Uint8List>> sent = [];
  bool sendResult = true;
  bool closed = false;
  bool throwOnClose = false;
  int closeAttempts = 0;
  Completer<void>? acceptOfferGate;
  Completer<bool>? sendGate;
  Completer<void>? closeGate;

  @override
  Future<PtyDescription> createOffer() async =>
      const PtyDescription(type: 'offer', sdp: 'offer-sdp');

  @override
  Future<PtyDescription> acceptOffer(PtyDescription offer) async {
    await acceptOfferGate?.future;
    return const PtyDescription(type: 'answer', sdp: 'answer-sdp');
  }

  @override
  Future<void> acceptAnswer(PtyDescription answer) async {}

  @override
  Future<void> addIce(PtyIceCandidate candidate) async => ice.add(candidate);

  @override
  Future<bool> sendPackets(List<Uint8List> packets) async {
    final gated = sendGate;
    if (gated != null) return gated.future;
    if (!sendResult) return false;
    sent.add([for (final packet in packets) Uint8List.fromList(packet)]);
    return true;
  }

  @override
  Future<void> close() async {
    closeAttempts++;
    closed = true;
    await closeGate?.future;
    if (throwOnClose) throw StateError('close failed');
  }

  void open() => callbacks.onState(PtyPeerState.p2p, null);
  void packet(Uint8List packet) => callbacks.onPacket(packet);
}

void main() {
  test('mode codec accepts only the three supported values', () {
    expect(PtyTransportMode.fromWire('auto'), PtyTransportMode.auto);
    expect(PtyTransportMode.fromWire('p2p'), PtyTransportMode.p2p);
    expect(PtyTransportMode.fromWire('relay'), PtyTransportMode.relay);
    expect(PtyTransportMode.fromWire('fallback'), isNull);
  });

  test('WebRTC adapter requests a reliable ordered data channel', () {
    final init = reliablePtyDataChannelInit();
    expect(init.ordered, isTrue);
    expect(init.maxRetransmitTime, -1);
    expect(init.maxRetransmits, -1);
    expect(init.negotiated, isFalse);
    expect(init.binaryType, 'binary');
  });

  test('vendored WebRTC wrapper forces ArrayBuffer on the actual channel', () {
    final source = File(
      'third_party/dart_webrtc/lib/src/rtc_data_channel_impl.dart',
    ).readAsStringSync();
    expect(source, contains("_jsDc.binaryType = 'arraybuffer'"));
  });

  test('PTY data allowlist includes only ordered terminal stream frames', () {
    for (final type in [
      'term.ready',
      'term.close',
      'term.input',
      'term.output',
      'term.resize',
      'screen',
      'reply',
      'status',
      'activity',
    ]) {
      expect(isPtyDataFrame({'t': type}), isTrue, reason: type);
    }
    for (final type in [
      'term.open',
      'term.routeFailed',
      ptySignalFrameType,
      'sessions',
    ]) {
      expect(isPtyDataFrame({'t': type}), isFalse, reason: type);
    }
  });

  test('plugin deadline returns promptly and cleans up a late value', () async {
    final source = Completer<int>();
    final cleaned = Completer<int>();

    await expectLater(
      ptyWithDeadline<int>(
        source.future,
        timeout: const Duration(milliseconds: 20),
        operation: 'test operation',
        onLateValue: cleaned.complete,
      ),
      throwsA(isA<TimeoutException>()),
    );
    source.complete(42);
    expect(await cleaned.future, 42);
  });

  test(
    'peer close attempts the connection while channel close hangs',
    () async {
      final channelGate = Completer<void>();
      var connectionCloseAttempts = 0;

      await ptyCloseConcurrently(
        closeChannel: () => channelGate.future,
        closePeerConnection: () async {
          connectionCloseAttempts++;
        },
        timeout: const Duration(milliseconds: 20),
      ).timeout(const Duration(milliseconds: 100));

      expect(connectionCloseAttempts, 1);
    },
  );

  test('send queue reserves bounded memory before async chaining', () async {
    final queue = PtySendQueue(maxQueuedBatches: 8, maxQueuedBytes: 80);
    final firstGate = Completer<bool>();
    var started = 0;
    final sends = <Future<bool>>[];

    sends.add(
      queue.enqueue(
        bytes: 10,
        operation: () {
          started++;
          return firstGate.future;
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);
    for (var index = 1; index < 1000; index++) {
      sends.add(
        queue.enqueue(
          bytes: 10,
          operation: () async {
            started++;
            return true;
          },
        ),
      );
    }

    expect(queue.queuedBatches, 8);
    expect(queue.queuedBytes, 80);
    expect(started, 1);
    queue.close();
    firstGate.complete(true);
    final results = await Future.wait(sends);
    expect(results.where((result) => result), hasLength(1));
    expect(started, 1);
    expect(queue.queuedBatches, 0);
    expect(queue.queuedBytes, 0);
  });

  test('UTF-8 frames split below 16 KiB and reassemble losslessly', () {
    final data = List.filled(9000, '终端🙂').join();
    final frame = <String, dynamic>{'t': 'term.output', 'sid': 's1', 'd': data};
    final packets = PtyPacketCodec.encode(frame, messageId: 7);

    expect(packets.length, greaterThan(1));
    expect(
      packets.every((packet) => packet.length <= ptyMaxPacketBytes),
      isTrue,
    );

    final reassembler = PtyPacketReassembler();
    Map<String, dynamic>? decoded;
    for (final packet in packets) {
      decoded = reassembler.add(packet) ?? decoded;
    }
    expect(decoded, frame);
  });

  test('malformed and duplicate packet parts fail closed', () {
    final packets = PtyPacketCodec.encode({
      't': 'term.input',
      'sid': 's1',
      'd': List.filled(20000, 'x').join(),
    }, messageId: 9);
    final reassembler = PtyPacketReassembler();
    expect(reassembler.add(packets.first), isNull);
    expect(() => reassembler.add(packets.first), throwsFormatException);
    expect(
      () => PtyPacketReassembler().add(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });

  test('reassembler caps aggregate incomplete data across message ids', () {
    List<Uint8List> packets(int messageId) => PtyPacketCodec.encode({
      't': 'term.output',
      'sid': 's1',
      'd': List.filled(1500000, 'x').join(),
    }, messageId: messageId);

    final first = packets(1);
    final second = packets(2);
    final third = packets(3);
    final reassembler = PtyPacketReassembler();
    for (final packet in first.take(first.length - 1)) {
      expect(reassembler.add(packet), isNull);
    }
    for (final packet in second.take(second.length - 1)) {
      expect(reassembler.add(packet), isNull);
    }

    expect(() {
      for (final packet in third.take(third.length - 1)) {
        reassembler.add(packet);
      }
    }, throwsFormatException);
  });

  test('reassembler tolerates Web Blob packet callback interleaving', () {
    final batches = [
      for (var id = 1; id <= 8; id++)
        PtyPacketCodec.encode({
          't': 'term.output',
          'sid': 's$id',
          'd': List.filled(20000, '$id').join(),
        }, messageId: id),
    ];
    final reassembler = PtyPacketReassembler();
    for (final batch in batches) {
      expect(reassembler.add(batch.first), isNull);
    }
    final decoded = <Map<String, dynamic>>[];
    for (final batch in batches) {
      for (final packet in batch.skip(1)) {
        final frame = reassembler.add(packet);
        if (frame != null) decoded.add(frame);
      }
    }
    expect(decoded.map((frame) => frame['sid']), [
      for (var id = 1; id <= 8; id++) 's$id',
    ]);
  });

  test('buffer gate waits for a slow healthy channel to drain', () async {
    final gate = PtyBufferGate(
      maxBufferedBytes: 100,
      waitTimeout: const Duration(seconds: 1),
      pollInterval: const Duration(milliseconds: 10),
    );
    var buffered = 90;

    final waiting = gate.waitForCapacity(
      bytes: 20,
      readBufferedAmount: () async => buffered,
      isOpen: () => true,
    );
    await Future<void>.delayed(Duration.zero);
    buffered = 40;
    gate.notifyLow();

    expect(await waiting, isTrue);
  });

  test(
    'buffer gate bounds a hung plugin read and close wakes waiters',
    () async {
      final hungRead = Completer<int>();
      final timed = PtyBufferGate(
        maxBufferedBytes: 100,
        waitTimeout: const Duration(milliseconds: 25),
      );
      expect(
        await timed.waitForCapacity(
          bytes: 10,
          readBufferedAmount: () => hungRead.future,
          isOpen: () => true,
        ),
        isFalse,
      );

      final closing = PtyBufferGate(
        maxBufferedBytes: 100,
        waitTimeout: const Duration(seconds: 5),
      );
      final waiting = closing.waitForCapacity(
        bytes: 10,
        readBufferedAmount: () => Completer<int>().future,
        isOpen: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      closing.close();
      expect(await waiting, isFalse);
    },
  );

  test('forced relay neither creates a peer nor accepts an offer', () async {
    final factory = _FakePeerFactory();
    final signals = <Map<String, dynamic>>[];
    final host = PtyHostTransportController(
      mode: PtyTransportMode.relay,
      peerFactory: factory,
      sendSignal: signals.add,
      onFrame: (_, _) {},
    );
    addTearDown(host.dispose);

    host.peerConnected(2);
    await host.handleSignal({
      't': ptySignalFrameType,
      'from': 2,
      'kind': 'mode',
      'mode': 'p2p',
    });
    await host.handleSignal({
      't': ptySignalFrameType,
      'from': 2,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'offer'},
    });

    expect(factory.peers, isEmpty);
    expect(signals.single['kind'], 'close');
    expect(
      await host.sendPtyFrame(2, {'t': 'term.output', 'd': 'x'}),
      PtySendResult.useRelay,
    );
  });

  test('host mode announcement starts one peer and sends an offer', () async {
    final factory = _FakePeerFactory();
    final signals = <Map<String, dynamic>>[];
    final host = PtyHostTransportController(
      mode: PtyTransportMode.auto,
      peerFactory: factory,
      sendSignal: signals.add,
      onFrame: (_, _) {},
    );
    addTearDown(host.dispose);
    host.peerConnected(2);

    await host.handleSignal({
      't': ptySignalFrameType,
      'from': 2,
      'kind': 'mode',
      'mode': 'auto',
    });

    expect(factory.peers, hasLength(1));
    expect(factory.peers.single.initiator, isTrue);
    expect(signals.single, containsPair('kind', 'offer'));
    expect(signals.single, containsPair('to', 2));
  });

  test('host rejects glare offers instead of creating an answerer', () async {
    final factory = _FakePeerFactory();
    final signals = <Map<String, dynamic>>[];
    final host = PtyHostTransportController(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
      sendSignal: signals.add,
      onFrame: (_, _) {},
    );
    addTearDown(host.dispose);
    host.peerConnected(2);

    await host.handleSignal({
      't': ptySignalFrameType,
      'from': 2,
      'kind': 'offer',
      'epoch': 5,
      'description': {'type': 'offer', 'sdp': 'client-offer'},
    });

    expect(factory.peers, isEmpty);
    expect(signals.single, containsPair('kind', 'close'));
  });

  test(
    'ICE received before offer is queued and old epochs are ignored',
    () async {
      final factory = _FakePeerFactory();
      final signals = <Map<String, dynamic>>[];
      final client = PtyClientTransportController(
        mode: PtyTransportMode.p2p,
        peerFactory: factory,
        sendSignal: signals.add,
        onFrame: (_, _) {},
      );
      addTearDown(client.dispose);

      await client.handleSignal({
        't': ptySignalFrameType,
        'from': 1,
        'kind': 'ice',
        'epoch': 4,
        'candidate': {'candidate': 'early'},
      });
      await client.handleSignal({
        't': ptySignalFrameType,
        'from': 1,
        'kind': 'offer',
        'epoch': 4,
        'description': {'type': 'offer', 'sdp': 'new'},
      });
      await client.handleSignal({
        't': ptySignalFrameType,
        'from': 1,
        'kind': 'offer',
        'epoch': 3,
        'description': {'type': 'offer', 'sdp': 'stale'},
      });
      await client.handleSignal({
        't': ptySignalFrameType,
        'from': 1,
        'kind': 'ice',
        'epoch': 3,
        'candidate': {'candidate': 'stale'},
      });

      expect(factory.peers, hasLength(1));
      expect(factory.peers.single.initiator, isFalse);
      expect(factory.peers.single.ice.map((value) => value.candidate), [
        'early',
      ]);
      expect(signals.single, containsPair('kind', 'answer'));
      expect(signals.single, containsPair('epoch', 4));
    },
  );

  test('same-peer retry retains the remote offer epoch watermark', () async {
    final factory = _FakePeerFactory();
    final client = PtyClientTransportController(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
      sendSignal: (_) {},
      onFrame: (_, _) {},
    );
    addTearDown(client.dispose);

    Future<void> offer(int epoch) => client.handleSignal({
      't': ptySignalFrameType,
      'from': 1,
      'kind': 'offer',
      'epoch': epoch,
      'description': {'type': 'offer', 'sdp': 'offer-$epoch'},
    });

    await offer(4);
    await client.restartPeer(1);
    await offer(4);
    expect(factory.peers, hasLength(1));

    await offer(5);
    expect(factory.peers, hasLength(2));
  });

  test('early ICE bounds peer epochs and cannot grow without offers', () async {
    final factory = _FakePeerFactory();
    final client = PtyClientTransportController(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
      sendSignal: (_) {},
      onFrame: (_, _) {},
    );
    addTearDown(client.dispose);

    for (var epoch = 1; epoch <= 200; epoch++) {
      await client.handleSignal({
        't': ptySignalFrameType,
        'from': 1,
        'kind': 'ice',
        'epoch': epoch,
        'candidate': {'candidate': 'candidate-$epoch'},
      });
    }
    await client.handleSignal({
      't': ptySignalFrameType,
      'from': 1,
      'kind': 'offer',
      'epoch': 200,
      'description': {'type': 'offer', 'sdp': 'offer'},
    });

    expect(factory.peers, hasLength(1));
    expect(factory.peers.single.ice, isEmpty);
  });

  test(
    'P2P delivery is isolated per peer and reassembles inbound data',
    () async {
      final factory = _FakePeerFactory();
      final signals = <Map<String, dynamic>>[];
      final received = <(int, Map<String, dynamic>)>[];
      final host = PtyHostTransportController(
        mode: PtyTransportMode.p2p,
        peerFactory: factory,
        sendSignal: signals.add,
        onFrame: (peerId, frame) => received.add((peerId, frame)),
      );
      addTearDown(host.dispose);
      for (final peerId in [2, 3]) {
        host.peerConnected(peerId);
        await host.handleSignal({
          't': ptySignalFrameType,
          'from': peerId,
          'kind': 'mode',
          'mode': 'p2p',
        });
      }
      factory.peers[0].open();
      factory.peers[1].open();

      final outbound = {'t': 'term.output', 'sid': 's1', 'd': 'hello'};
      expect(await host.sendPtyFrame(2, outbound), PtySendResult.sentP2p);
      expect(factory.peers[0].sent, hasLength(1));
      expect(factory.peers[1].sent, isEmpty);

      final inbound = <String, dynamic>{
        't': 'term.input',
        'sid': 's1',
        'd': 'ls\r',
      };
      for (final packet in PtyPacketCodec.encode(inbound, messageId: 11)) {
        factory.peers[1].packet(packet);
      }
      expect(received, hasLength(1));
      expect(received.single.$1, 3);
      expect(received.single.$2, inbound);
    },
  );

  test(
    'an unselected host retries its connecting offer on failover mode',
    () async {
      final factory = _FakePeerFactory();
      final signals = <Map<String, dynamic>>[];
      final host = PtyHostTransportController(
        mode: PtyTransportMode.p2p,
        peerFactory: factory,
        sendSignal: signals.add,
        onFrame: (_, _) {},
      );
      addTearDown(host.dispose);

      Future<void> announce(int peerId) async {
        host.peerConnected(peerId);
        await host.handleSignal({
          't': ptySignalFrameType,
          'from': peerId,
          'kind': 'mode',
          'mode': 'p2p',
        });
      }

      await announce(2);
      await announce(3);
      final selected = factory.peers.singleWhere((peer) => peer.peerId == 2)
        ..open();
      final ignored = factory.peers.singleWhere((peer) => peer.peerId == 3);
      expect(host.statusFor(3).state, PtyPeerState.connecting);

      await host.handleSignal({
        't': ptySignalFrameType,
        'from': 3,
        'kind': 'mode',
        'mode': 'p2p',
      });

      final peer3Attempts = factory.peers
          .where((peer) => peer.peerId == 3)
          .toList();
      expect(peer3Attempts, hasLength(2));
      expect(ignored.closed, isTrue);
      expect(selected.closed, isFalse);
      expect(
        signals.where((frame) => frame['to'] == 3 && frame['kind'] == 'offer'),
        hasLength(2),
      );

      final replacement = peer3Attempts.last..open();
      await host.handleSignal({
        't': ptySignalFrameType,
        'from': 3,
        'kind': 'mode',
        'mode': 'p2p',
      });
      expect(factory.peers.where((peer) => peer.peerId == 3), hasLength(2));
      expect(replacement.closed, isFalse);
      expect(host.statusFor(3).state, PtyPeerState.p2p);
    },
  );

  test(
    'backpressure never retries an assigned P2P frame through Relay',
    () async {
      Future<PtySendResult> run(PtyTransportMode mode) async {
        final factory = _FakePeerFactory();
        final controller = PtyHostTransportController(
          mode: mode,
          peerFactory: factory,
          sendSignal: (_) {},
          onFrame: (_, _) {},
        );
        controller.peerConnected(2);
        await controller.handleSignal({
          't': ptySignalFrameType,
          'from': 2,
          'kind': 'mode',
          'mode': mode.wireName,
        });
        factory.peers.single
          ..open()
          ..sendResult = false;
        final result = await controller.sendPtyFrame(2, {
          't': 'term.output',
          'sid': 's1',
          'd': 'busy',
        });
        await controller.dispose();
        return result;
      }

      expect(await run(PtyTransportMode.auto), PtySendResult.unavailable);
      expect(await run(PtyTransportMode.p2p), PtySendResult.unavailable);
    },
  );

  test('one rejected frame does not close an otherwise open peer', () async {
    final factory = _FakePeerFactory();
    final host = PtyHostTransportController(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
      sendSignal: (_) {},
      onFrame: (_, _) {},
    );
    addTearDown(host.dispose);
    host.peerConnected(2);
    await host.handleSignal({
      't': ptySignalFrameType,
      'from': 2,
      'kind': 'mode',
      'mode': 'p2p',
    });
    final peer = factory.peers.single
      ..open()
      ..sendResult = false;

    expect(
      await host.sendPtyFrame(2, {
        't': 'term.output',
        'sid': 's1',
        'd': 'stale route frame',
      }),
      PtySendResult.unavailable,
    );
    expect(peer.closed, isFalse);
    expect(host.statusFor(2).state, PtyPeerState.p2p);
  });

  test('client advertises mode over relay control signaling', () async {
    final signals = <Map<String, dynamic>>[];
    final client = PtyClientTransportController(
      mode: PtyTransportMode.auto,
      peerFactory: _FakePeerFactory(),
      sendSignal: signals.add,
      onFrame: (_, _) {},
    );
    addTearDown(client.dispose);

    client.hostConnected(1);
    await client.setMode(PtyTransportMode.relay);

    expect(signals, [
      {'t': ptySignalFrameType, 'to': 1, 'kind': 'mode', 'mode': 'auto'},
      {'t': ptySignalFrameType, 'to': 1, 'kind': 'mode', 'mode': 'relay'},
    ]);
  });

  test(
    'superseded relay close cannot overwrite a replacement or advertise twice',
    () async {
      final factory = _FakePeerFactory();
      final signals = <Map<String, dynamic>>[];
      final client = PtyClientTransportController(
        mode: PtyTransportMode.auto,
        peerFactory: factory,
        sendSignal: signals.add,
        onFrame: (_, _) {},
      );
      addTearDown(client.dispose);
      client.hostConnected(1);
      await client.handleSignal({
        't': ptySignalFrameType,
        'from': 1,
        'kind': 'offer',
        'epoch': 1,
        'description': {'type': 'offer', 'sdp': 'offer-1'},
      });
      final old = factory.peers.single..open();
      old.closeGate = Completer<void>();

      final relayChange = client.setMode(PtyTransportMode.relay);
      await Future<void>.delayed(Duration.zero);
      expect(old.closed, isTrue);
      final p2pChange = client.setMode(PtyTransportMode.p2p);
      await p2pChange;
      final replacementSignal = client.handleSignal({
        't': ptySignalFrameType,
        'from': 1,
        'kind': 'offer',
        'epoch': 2,
        'description': {'type': 'offer', 'sdp': 'offer-2'},
      });
      await Future<void>.delayed(Duration.zero);
      final replacement = factory.peers.last..open();

      old.closeGate!.complete();
      await Future.wait([relayChange, replacementSignal]);

      expect(client.mode, PtyTransportMode.p2p);
      expect(client.statusFor(1).state, PtyPeerState.p2p);
      expect(replacement.closed, isFalse);
      expect(
        signals
            .where((frame) => frame['kind'] == 'mode')
            .map((frame) => frame['mode']),
        ['auto', 'p2p'],
      );
    },
  );

  test('non-PTY frames always stay on relay', () async {
    final controller = PtyClientTransportController(
      mode: PtyTransportMode.p2p,
      peerFactory: _FakePeerFactory(),
      sendSignal: (_) {},
      onFrame: (_, _) {},
    );
    addTearDown(controller.dispose);

    expect(
      await controller.sendPtyFrame(1, {'t': 'fs.read', 'path': '/tmp/a'}),
      PtySendResult.useRelay,
    );
  });

  test('malformed signal scalar types are ignored without throwing', () async {
    final controller = PtyClientTransportController(
      mode: PtyTransportMode.p2p,
      peerFactory: _FakePeerFactory(),
      sendSignal: (_) {},
      onFrame: (_, _) {},
    );
    addTearDown(controller.dispose);

    expect(
      await controller.handleSignal({
        't': ptySignalFrameType,
        'from': 'one',
        'kind': 'offer',
        'epoch': 1,
      }),
      isTrue,
    );
    expect(
      await controller.handleSignal({
        't': ptySignalFrameType,
        'from': 1,
        'kind': 'offer',
        'epoch': 1.5,
      }),
      isTrue,
    );
    expect(
      await controller.handleSignal({
        't': ptySignalFrameType,
        'from': 0x80000000,
        'kind': 'ice',
        'epoch': 1,
        'candidate': {'candidate': 'candidate'},
      }),
      isTrue,
    );
    expect(
      await controller.handleSignal({
        't': ptySignalFrameType,
        'from': 1,
        'kind': 'ice',
        'epoch': 1,
        'candidate': {'candidate': 'candidate', 'sdpMLineIndex': -1},
      }),
      isTrue,
    );
  });

  test('signal lanes enforce count and byte limits before enqueue', () async {
    final acceptGate = Completer<void>();
    final factory = _FakePeerFactory(
      onCreate: (peer) => peer.acceptOfferGate = acceptGate,
    );
    final client = PtyClientTransportController(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
      sendSignal: (_) {},
      onFrame: (_, _) {},
      maxQueuedSignals: 3,
      maxQueuedSignalBytes: 4096,
      maxPeerQueuedSignals: 3,
      maxPeerQueuedSignalBytes: 4096,
    );
    addTearDown(client.dispose);

    final offer = client.handleSignal({
      't': ptySignalFrameType,
      'from': 1,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'offer'},
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final ice = <Future<bool>>[];
    for (var index = 0; index < 100; index++) {
      ice.add(
        client.handleSignal({
          't': ptySignalFrameType,
          'from': 1,
          'kind': 'ice',
          'epoch': 1,
          'candidate': {'candidate': 'candidate-$index'},
        }),
      );
    }
    acceptGate.complete();
    await offer;
    await Future.wait(ice);

    expect(factory.peers, hasLength(1));
    expect(factory.peers.single.ice.length, lessThanOrEqualTo(2));

    final byteLimited = PtyClientTransportController(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
      sendSignal: (_) {},
      onFrame: (_, _) {},
      maxQueuedSignalBytes: 100,
      maxPeerQueuedSignalBytes: 100,
    );
    await byteLimited.handleSignal({
      't': ptySignalFrameType,
      'from': 2,
      'kind': 'offer',
      'epoch': 1,
      'description': {'type': 'offer', 'sdp': 'too-large-for-budget'},
    });
    await byteLimited.dispose();
    expect(factory.peers, hasLength(1));
  });

  test(
    'disconnect invalidates an offer before its queued turn starts',
    () async {
      final factory = _FakePeerFactory();
      final client = PtyClientTransportController(
        mode: PtyTransportMode.p2p,
        peerFactory: factory,
        sendSignal: (_) {},
        onFrame: (_, _) {},
      );
      addTearDown(client.dispose);

      final queued = client.handleSignal({
        't': ptySignalFrameType,
        'from': 1,
        'kind': 'offer',
        'epoch': 1,
        'description': {'type': 'offer', 'sdp': 'offer'},
      });
      await client.peerDisconnected(1);
      await queued;

      expect(factory.peers, isEmpty);
    },
  );

  test('new peer lifecycle is not blocked by a hung old signal lane', () async {
    final oldAccept = Completer<void>();
    final factory = _FakePeerFactory(
      onCreate: (peer) {
        if (peer.peerId == 1 &&
            peer.initiator == false &&
            oldAccept.isCompleted == false) {
          peer.acceptOfferGate = oldAccept;
        }
      },
    );
    final client = PtyClientTransportController(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
      sendSignal: (_) {},
      onFrame: (_, _) {},
    );
    addTearDown(client.dispose);

    Future<bool> offer(int epoch) => client.handleSignal({
      't': ptySignalFrameType,
      'from': 1,
      'kind': 'offer',
      'epoch': epoch,
      'description': {'type': 'offer', 'sdp': 'offer-$epoch'},
    });

    final oldSignal = offer(1);
    while (factory.peers.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await client.peerDisconnected(1);
    final replacementSignal = offer(1);
    while (factory.peers.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(factory.peers.first.closed, isTrue);
    expect(factory.peers.last.closed, isFalse);
    oldAccept.complete();
    await Future.wait([oldSignal, replacementSignal]);
    expect(factory.peers.last.closed, isFalse);
  });

  test(
    'dispose closes peers without awaiting a hung signal operation',
    () async {
      final acceptGate = Completer<void>();
      final factory = _FakePeerFactory(
        onCreate: (peer) => peer.acceptOfferGate = acceptGate,
      );
      final client = PtyClientTransportController(
        mode: PtyTransportMode.p2p,
        peerFactory: factory,
        sendSignal: (_) {},
        onFrame: (_, _) {},
      );
      final handling = client.handleSignal({
        't': ptySignalFrameType,
        'from': 1,
        'kind': 'offer',
        'epoch': 1,
        'description': {'type': 'offer', 'sdp': 'offer'},
      });
      while (factory.peers.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }

      await client.dispose().timeout(const Duration(milliseconds: 100));
      expect(factory.peers.single.closeAttempts, 1);
      acceptGate.complete();
      await handling;
    },
  );

  test('wire close and immediate retry mode are processed in order', () async {
    final factory = _FakePeerFactory();
    final signals = <Map<String, dynamic>>[];
    final host = PtyHostTransportController(
      mode: PtyTransportMode.auto,
      peerFactory: factory,
      sendSignal: signals.add,
      onFrame: (_, _) {},
    );
    addTearDown(host.dispose);
    host.peerConnected(9);
    await host.handleSignal({
      't': ptySignalFrameType,
      'from': 9,
      'kind': 'mode',
      'mode': 'p2p',
    });
    final firstOffer = signals.lastWhere((frame) => frame['kind'] == 'offer');
    final epoch = firstOffer['epoch'] as int;
    factory.peers.first.open();

    final closing = host.handleSignal({
      't': ptySignalFrameType,
      'from': 9,
      'kind': 'close',
      'epoch': epoch,
    });
    final retrying = host.handleSignal({
      't': ptySignalFrameType,
      'from': 9,
      'kind': 'mode',
      'mode': 'p2p',
    });
    await Future.wait([closing, retrying]);

    expect(factory.peers, hasLength(2));
    expect(signals.where((frame) => frame['kind'] == 'offer'), hasLength(2));
  });

  test(
    'an old async close cannot overwrite a replacement peer status',
    () async {
      final factory = _FakePeerFactory();
      final host = PtyHostTransportController(
        mode: PtyTransportMode.auto,
        peerFactory: factory,
        sendSignal: (_) {},
        onFrame: (_, _) {},
      );
      addTearDown(host.dispose);
      host.peerConnected(12);
      await host.handleSignal({
        't': ptySignalFrameType,
        'from': 12,
        'kind': 'mode',
        'mode': 'p2p',
      });
      final old = factory.peers.single;
      old.open();
      old.closeGate = Completer<void>();

      old.callbacks.onState(PtyPeerState.failed, 'old failed');
      await host.handleSignal({
        't': ptySignalFrameType,
        'from': 12,
        'kind': 'mode',
        'mode': 'p2p',
      });
      final replacement = factory.peers.last;
      replacement.open();
      old.closeGate!.complete();
      await Future<void>.delayed(Duration.zero);

      expect(host.statusFor(12).state, PtyPeerState.p2p);
    },
  );

  test('restart close cannot erase a concurrently replaced status', () async {
    final factory = _FakePeerFactory();
    final client = PtyClientTransportController(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
      sendSignal: (_) {},
      onFrame: (_, _) {},
    );
    addTearDown(client.dispose);
    Future<void> offer(int epoch) => client.handleSignal({
      't': ptySignalFrameType,
      'from': 1,
      'kind': 'offer',
      'epoch': epoch,
      'description': {'type': 'offer', 'sdp': 'offer-$epoch'},
    });

    await offer(1);
    final old = factory.peers.single;
    old.closeGate = Completer<void>();
    final restarting = client.restartPeer(1);
    await Future<void>.delayed(Duration.zero);
    await offer(2);
    factory.peers.last.open();
    old.closeGate!.complete();
    await restarting;

    expect(client.statusFor(1).state, PtyPeerState.p2p);
  });

  test('an old send failure cannot close a replacement peer', () async {
    final factory = _FakePeerFactory();
    final host = PtyHostTransportController(
      mode: PtyTransportMode.p2p,
      peerFactory: factory,
      sendSignal: (_) {},
      onFrame: (_, _) {},
    );
    addTearDown(host.dispose);
    host.peerConnected(22);
    Future<void> announce() => host.handleSignal({
      't': ptySignalFrameType,
      'from': 22,
      'kind': 'mode',
      'mode': 'p2p',
    });

    await announce();
    final old = factory.peers.single..open();
    old.sendGate = Completer<bool>();
    final sending = host.sendPtyFrame(22, {
      't': 'term.output',
      'sid': 's1',
      'd': 'old session',
    });
    await Future<void>.delayed(Duration.zero);

    await host.restartPeer(22);
    await announce();
    final replacement = factory.peers.last..open();
    old.sendGate!.complete(false);

    expect(await sending, PtySendResult.unavailable);
    expect(replacement.closed, isFalse);
    expect(host.statusFor(22).state, PtyPeerState.p2p);
  });

  test('host exposes the negotiated remote transport mode', () async {
    final host = PtyHostTransportController(
      mode: PtyTransportMode.relay,
      peerFactory: _FakePeerFactory(),
      sendSignal: (_) {},
      onFrame: (_, _) {},
    );
    addTearDown(host.dispose);
    host.peerConnected(31);

    await host.handleSignal({
      't': ptySignalFrameType,
      'from': 31,
      'kind': 'mode',
      'mode': 'auto',
    });
    expect(host.remoteModeFor(31), PtyTransportMode.auto);
    await host.peerDisconnected(31);
    expect(host.remoteModeFor(31), isNull);
  });

  test('dispose closes every peer even when one close throws', () async {
    final factory = _FakePeerFactory();
    final host = PtyHostTransportController(
      mode: PtyTransportMode.auto,
      peerFactory: factory,
      sendSignal: (_) {},
      onFrame: (_, _) {},
    );
    for (final peerId in [10, 11]) {
      host.peerConnected(peerId);
      await host.handleSignal({
        't': ptySignalFrameType,
        'from': peerId,
        'kind': 'mode',
        'mode': 'p2p',
      });
    }
    factory.peers.first.throwOnClose = true;

    await host.dispose();

    expect(factory.peers.map((peer) => peer.closeAttempts), everyElement(1));
  });
}
