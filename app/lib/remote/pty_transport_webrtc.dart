import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'pty_transport.dart';

const Map<String, dynamic> defaultPtyRtcConfiguration = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
  ],
  'sdpSemantics': 'unified-plan',
};

@visibleForTesting
Future<T> ptyWithDeadline<T>(
  Future<T> source, {
  required Duration timeout,
  required String operation,
  FutureOr<void> Function(T value)? onLateValue,
}) {
  final result = Completer<T>();
  late final Timer timer;
  var settled = false;

  timer = Timer(timeout, () {
    if (settled) return;
    settled = true;
    result.completeError(TimeoutException('$operation timed out', timeout));
  });
  unawaited(
    source.then<void>(
      (value) {
        if (settled) {
          if (onLateValue != null) {
            unawaited(
              Future<void>.sync(
                () => onLateValue(value),
              ).then<void>((_) {}, onError: (_, _) {}),
            );
          }
          return;
        }
        settled = true;
        timer.cancel();
        result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (settled) return;
        settled = true;
        timer.cancel();
        result.completeError(error, stack);
      },
    ),
  );
  return result.future;
}

@visibleForTesting
class PtyBufferGate {
  PtyBufferGate({
    required this.maxBufferedBytes,
    this.waitTimeout = const Duration(seconds: 10),
    this.pollInterval = const Duration(milliseconds: 250),
  }) : assert(maxBufferedBytes > 0),
       assert(waitTimeout > Duration.zero),
       assert(pollInterval > Duration.zero);

  static final Object _closedMarker = Object();

  final int maxBufferedBytes;
  final Duration waitTimeout;
  final Duration pollInterval;
  final Completer<void> _closedSignal = Completer<void>();
  Completer<void>? _waiter;
  bool _closed = false;

  void notifyLow() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (!_closedSignal.isCompleted) _closedSignal.complete();
    notifyLow();
  }

  Future<bool> waitForCapacity({
    required int bytes,
    required Future<int> Function() readBufferedAmount,
    required bool Function() isOpen,
    Duration? timeout,
  }) async {
    if (bytes <= 0 || bytes > maxBufferedBytes) return false;
    var budget = timeout ?? waitTimeout;
    if (budget > waitTimeout) budget = waitTimeout;
    if (budget <= Duration.zero) return false;
    final stopwatch = Stopwatch()..start();

    while (!_closed && isOpen()) {
      final remaining = budget - stopwatch.elapsed;
      if (remaining <= Duration.zero) return false;
      final read = ptyWithDeadline<int>(
        Future<int>.sync(readBufferedAmount),
        timeout: remaining,
        operation: 'read WebRTC buffered amount',
      ).then<Object>((value) => value);
      final closed = _closedSignal.future.then<Object>((_) => _closedMarker);
      Object bufferedOrClosed;
      try {
        bufferedOrClosed = await Future.any<Object>([read, closed]);
      } on TimeoutException {
        return false;
      } catch (_) {
        return false;
      }
      if (identical(bufferedOrClosed, _closedMarker) || _closed || !isOpen()) {
        return false;
      }
      final buffered = bufferedOrClosed as int;
      if (buffered <= maxBufferedBytes - bytes) return true;

      final wake = Completer<void>();
      _waiter = wake;
      final afterRead = budget - stopwatch.elapsed;
      if (afterRead <= Duration.zero) {
        if (identical(_waiter, wake)) _waiter = null;
        return false;
      }
      final wait = afterRead < pollInterval ? afterRead : pollInterval;
      try {
        await Future.any<void>([
          wake.future,
          _closedSignal.future,
          Future<void>.delayed(wait),
        ]);
      } finally {
        if (identical(_waiter, wake)) _waiter = null;
      }
    }
    return false;
  }
}

@visibleForTesting
class PtySendQueue {
  PtySendQueue({required this.maxQueuedBatches, required this.maxQueuedBytes})
    : assert(maxQueuedBatches > 0),
      assert(maxQueuedBytes > 0);

  final int maxQueuedBatches;
  final int maxQueuedBytes;
  final Completer<void> _closedSignal = Completer<void>();
  Future<void> _tail = Future<void>.value();
  int _queuedBatches = 0;
  int _queuedBytes = 0;
  bool _closed = false;

  int get queuedBatches => _queuedBatches;
  int get queuedBytes => _queuedBytes;

  Future<bool> enqueue({
    required int bytes,
    required Future<bool> Function() operation,
  }) {
    if (_closed ||
        bytes <= 0 ||
        bytes > maxQueuedBytes - _queuedBytes ||
        _queuedBatches >= maxQueuedBatches) {
      return Future<bool>.value(false);
    }
    _queuedBatches++;
    _queuedBytes += bytes;

    final previous = _tail;
    final run = () async {
      await Future.any<void>([previous, _closedSignal.future]);
      if (_closed) return false;
      try {
        return await operation();
      } catch (_) {
        return false;
      }
    }();
    final result = run.whenComplete(() {
      _queuedBatches--;
      _queuedBytes -= bytes;
    });
    _tail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (!_closedSignal.isCompleted) _closedSignal.complete();
  }
}

@visibleForTesting
Future<void> ptyCloseConcurrently({
  Future<void> Function()? closeChannel,
  required Future<void> Function() closePeerConnection,
  required Duration timeout,
}) => Future.wait<void>([
  if (closeChannel != null)
    _closeOperationQuietly(closeChannel, timeout, 'close PTY data channel'),
  _closeOperationQuietly(
    closePeerConnection,
    timeout,
    'close WebRTC peer connection',
  ),
]);

class WebRtcPtyPeerFactory implements PtyPeerFactory {
  WebRtcPtyPeerFactory({
    this.configuration = defaultPtyRtcConfiguration,
    this.maxBufferedBytes = 512 * 1024,
    this.maxQueuedBatches = 32,
    this.maxQueuedBytes = 4 * 1024 * 1024,
    this.operationTimeout = const Duration(seconds: 10),
    this.sendBatchTimeout = const Duration(seconds: 10),
    this.closeTimeout = const Duration(seconds: 3),
  }) : assert(maxBufferedBytes > 0),
       assert(maxQueuedBatches > 0),
       assert(maxQueuedBytes > 0),
       assert(operationTimeout > Duration.zero),
       assert(sendBatchTimeout > Duration.zero),
       assert(closeTimeout > Duration.zero);

  final Map<String, dynamic> configuration;
  final int maxBufferedBytes;
  final int maxQueuedBatches;
  final int maxQueuedBytes;
  final Duration operationTimeout;
  final Duration sendBatchTimeout;
  final Duration closeTimeout;

  @override
  Future<PtyPeer> create({
    required int peerId,
    required bool initiator,
    required PtyPeerCallbacks callbacks,
  }) async {
    final pc = await ptyWithDeadline<RTCPeerConnection>(
      createPeerConnection(configuration),
      timeout: operationTimeout,
      operation: 'create WebRTC peer connection',
      onLateValue: (latePc) =>
          _closePeerConnectionQuietly(latePc, closeTimeout),
    );
    final peer = _WebRtcPtyPeer(
      pc: pc,
      callbacks: callbacks,
      maxBufferedBytes: maxBufferedBytes,
      maxQueuedBatches: maxQueuedBatches,
      maxQueuedBytes: maxQueuedBytes,
      operationTimeout: operationTimeout,
      sendBatchTimeout: sendBatchTimeout,
      closeTimeout: closeTimeout,
    );
    try {
      peer.bind();
      if (initiator) {
        final channel = await ptyWithDeadline<RTCDataChannel>(
          pc.createDataChannel(
            'cc-handoff.pty.v1',
            reliablePtyDataChannelInit(),
          ),
          timeout: operationTimeout,
          operation: 'create PTY data channel',
          onLateValue: (lateChannel) =>
              _closeDataChannelQuietly(lateChannel, closeTimeout),
        );
        await peer.attachChannel(channel);
      }
      return peer;
    } catch (error, stack) {
      await peer.close();
      Error.throwWithStackTrace(error, stack);
    }
  }
}

RTCDataChannelInit reliablePtyDataChannelInit() => RTCDataChannelInit()
  ..ordered = true
  ..maxRetransmitTime = -1
  ..maxRetransmits = -1
  ..negotiated = false
  ..binaryType = 'binary';

class _WebRtcPtyPeer implements PtyPeer {
  _WebRtcPtyPeer({
    required this._pc,
    required this._callbacks,
    required this.maxBufferedBytes,
    required this.maxQueuedBatches,
    required this.maxQueuedBytes,
    required this.operationTimeout,
    required this.sendBatchTimeout,
    required this.closeTimeout,
  }) : _sendQueue = PtySendQueue(
         maxQueuedBatches: maxQueuedBatches,
         maxQueuedBytes: maxQueuedBytes,
       );

  final RTCPeerConnection _pc;
  final PtyPeerCallbacks _callbacks;
  final int maxBufferedBytes;
  final int maxQueuedBatches;
  final int maxQueuedBytes;
  final Duration operationTimeout;
  final Duration sendBatchTimeout;
  final Duration closeTimeout;
  late final PtyBufferGate _bufferGate = PtyBufferGate(
    maxBufferedBytes: maxBufferedBytes,
    waitTimeout: sendBatchTimeout,
  );
  final PtySendQueue _sendQueue;
  RTCDataChannel? _channel;
  Future<void>? _closeFuture;
  bool _closing = false;

  void bind() {
    _pc.onIceCandidate = (candidate) {
      final value = candidate.candidate;
      if (_closing || value == null || value.isEmpty) return;
      _callbacks.onIce(
        PtyIceCandidate(
          candidate: value,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ),
      );
    };
    _pc.onDataChannel = (channel) {
      if (_closing ||
          _channel != null ||
          channel.label != 'cc-handoff.pty.v1') {
        unawaited(_closeDataChannelQuietly(channel, closeTimeout));
        return;
      }
      unawaited(_attachInboundChannel(channel));
    };
    _pc.onConnectionState = (state) {
      if (_closing) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _callbacks.onState(PtyPeerState.failed, 'WebRTC connection failed');
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _callbacks.onState(PtyPeerState.closed, null);
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateNew:
          break;
      }
    };
  }

  Future<void> _attachInboundChannel(RTCDataChannel channel) async {
    try {
      await attachChannel(channel);
    } catch (error) {
      await _closeDataChannelQuietly(channel, closeTimeout);
      if (!_closing) {
        _callbacks.onState(
          PtyPeerState.failed,
          'failed to attach PTY data channel: $error',
        );
      }
    }
  }

  Future<void> attachChannel(RTCDataChannel channel) async {
    if (_closing) {
      await _closeDataChannelQuietly(channel, closeTimeout);
      return;
    }
    if (_channel != null && !identical(_channel, channel)) {
      await _closeDataChannelQuietly(channel, closeTimeout);
      return;
    }
    _channel = channel;
    channel.bufferedAmountLowThreshold = maxBufferedBytes ~/ 2;
    channel.onBufferedAmountLow = (_) => _bufferGate.notifyLow();
    channel.onDataChannelState = (state) {
      if (_closing) return;
      switch (state) {
        case RTCDataChannelState.RTCDataChannelOpen:
          _callbacks.onState(PtyPeerState.p2p, null);
        case RTCDataChannelState.RTCDataChannelClosing:
        case RTCDataChannelState.RTCDataChannelClosed:
          _bufferGate.close();
          _callbacks.onState(PtyPeerState.failed, 'PTY data channel closed');
        case RTCDataChannelState.RTCDataChannelConnecting:
          _callbacks.onState(PtyPeerState.connecting, null);
      }
    };
    channel.onMessage = (message) {
      if (_closing) return;
      if (!message.isBinary) {
        _callbacks.onState(
          PtyPeerState.failed,
          'PTY data channel requires binary frames',
        );
        return;
      }
      _callbacks.onPacket(Uint8List.fromList(message.binary));
    };
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _callbacks.onState(PtyPeerState.p2p, null);
    }
  }

  Future<T> _operation<T>(Future<T> source, String name) =>
      ptyWithDeadline<T>(source, timeout: operationTimeout, operation: name);

  @override
  Future<PtyDescription> createOffer() async {
    final offer = await _operation(_pc.createOffer(), 'create WebRTC offer');
    await _operation(_pc.setLocalDescription(offer), 'set WebRTC local offer');
    return _localDescription('offer');
  }

  @override
  Future<PtyDescription> acceptOffer(PtyDescription offer) async {
    await _operation(
      _pc.setRemoteDescription(RTCSessionDescription(offer.sdp, offer.type)),
      'set WebRTC remote offer',
    );
    final answer = await _operation(_pc.createAnswer(), 'create WebRTC answer');
    await _operation(
      _pc.setLocalDescription(answer),
      'set WebRTC local answer',
    );
    return _localDescription('answer');
  }

  @override
  Future<void> acceptAnswer(PtyDescription answer) => _operation(
    _pc.setRemoteDescription(RTCSessionDescription(answer.sdp, answer.type)),
    'set WebRTC remote answer',
  );

  Future<PtyDescription> _localDescription(String expectedType) async {
    final description = await _operation(
      _pc.getLocalDescription(),
      'read WebRTC local description',
    );
    final sdp = description?.sdp;
    final type = description?.type;
    if (sdp == null || sdp.isEmpty || type != expectedType) {
      throw StateError('missing WebRTC $expectedType description');
    }
    return PtyDescription(type: type!, sdp: sdp);
  }

  @override
  Future<void> addIce(PtyIceCandidate candidate) => _operation(
    _pc.addCandidate(
      RTCIceCandidate(
        candidate.candidate,
        candidate.sdpMid,
        candidate.sdpMLineIndex,
      ),
    ),
    'add WebRTC ICE candidate',
  );

  @override
  Future<bool> sendPackets(List<Uint8List> packets) {
    if (_closing || packets.isEmpty) return Future<bool>.value(false);
    var bytes = 0;
    for (final packet in packets) {
      if (packet.isEmpty || packet.length > ptyMaxPacketBytes) {
        return Future<bool>.value(false);
      }
      bytes += packet.length;
      if (bytes > maxQueuedBytes) return Future<bool>.value(false);
    }
    return _sendQueue.enqueue(
      bytes: bytes,
      operation: () => _sendPacketsNow(packets),
    );
  }

  Future<bool> _sendPacketsNow(List<Uint8List> packets) async {
    final stopwatch = Stopwatch()..start();
    final channel = _channel;
    if (_closing ||
        channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return _closing ? false : _poisonAfterSendFailure();
    }
    for (final packet in packets) {
      if (_closing || channel.state != RTCDataChannelState.RTCDataChannelOpen) {
        return _closing ? false : _poisonAfterSendFailure();
      }
      var remaining = sendBatchTimeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) return _poisonAfterSendFailure();
      final hasCapacity = await _bufferGate.waitForCapacity(
        bytes: packet.length,
        readBufferedAmount: channel.getBufferedAmount,
        isOpen: () =>
            !_closing &&
            channel.state == RTCDataChannelState.RTCDataChannelOpen,
        timeout: remaining,
      );
      if (!hasCapacity) return _poisonAfterSendFailure();
      remaining = sendBatchTimeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) return _poisonAfterSendFailure();
      try {
        await ptyWithDeadline<void>(
          channel.send(RTCDataChannelMessage.fromBinary(packet)),
          timeout: remaining,
          operation: 'send PTY data channel packet',
        );
      } catch (_) {
        return _poisonAfterSendFailure();
      }
    }
    return true;
  }

  bool _poisonAfterSendFailure() {
    if (!_closing) {
      _callbacks.onState(PtyPeerState.failed, 'PTY data channel send failed');
      unawaited(close());
    }
    return false;
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closing = true;
    _bufferGate.close();
    _sendQueue.close();
    final channel = _channel;
    _channel = null;
    final closing = ptyCloseConcurrently(
      closeChannel: channel?.close,
      closePeerConnection: _pc.close,
      timeout: closeTimeout,
    );
    _closeFuture = closing;
    return closing;
  }
}

Future<void> _closeDataChannelQuietly(
  RTCDataChannel channel,
  Duration timeout,
) => _closeOperationQuietly(channel.close, timeout, 'close PTY data channel');

Future<void> _closePeerConnectionQuietly(
  RTCPeerConnection pc,
  Duration timeout,
) => _closeOperationQuietly(pc.close, timeout, 'close WebRTC peer connection');

Future<void> _closeOperationQuietly(
  Future<void> Function() close,
  Duration timeout,
  String operation,
) async {
  try {
    await ptyWithDeadline<void>(
      Future<void>.sync(close),
      timeout: timeout,
      operation: operation,
    );
  } catch (_) {}
}
