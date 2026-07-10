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
class PtyBufferGate {
  PtyBufferGate({
    required this.maxBufferedBytes,
    this.waitTimeout = const Duration(seconds: 10),
    this.pollInterval = const Duration(milliseconds: 250),
  }) : assert(maxBufferedBytes > 0);

  final int maxBufferedBytes;
  final Duration waitTimeout;
  final Duration pollInterval;
  Completer<void>? _waiter;
  bool _closed = false;

  void notifyLow() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void close() {
    _closed = true;
    notifyLow();
  }

  Future<bool> waitForCapacity({
    required int bytes,
    required Future<int> Function() readBufferedAmount,
    required bool Function() isOpen,
  }) async {
    if (bytes <= 0 || bytes > maxBufferedBytes) return false;
    final deadline = DateTime.now().add(waitTimeout);
    while (!_closed && isOpen()) {
      final wake = Completer<void>();
      _waiter = wake;
      final buffered = await readBufferedAmount();
      if (_closed || !isOpen()) return false;
      if (buffered <= maxBufferedBytes - bytes) {
        if (identical(_waiter, wake)) _waiter = null;
        return true;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return false;
      final wait = remaining < pollInterval ? remaining : pollInterval;
      try {
        await wake.future.timeout(wait);
      } on TimeoutException {
        // Some platform implementations miss low-buffer callbacks. Polling is
        // bounded and keeps a healthy but slow SCTP channel from being killed.
      } finally {
        if (identical(_waiter, wake)) _waiter = null;
      }
    }
    return false;
  }
}

class WebRtcPtyPeerFactory implements PtyPeerFactory {
  WebRtcPtyPeerFactory({
    this.configuration = defaultPtyRtcConfiguration,
    this.maxBufferedBytes = 512 * 1024,
  }) : assert(maxBufferedBytes > 0);

  final Map<String, dynamic> configuration;
  final int maxBufferedBytes;

  @override
  Future<PtyPeer> create({
    required int peerId,
    required bool initiator,
    required PtyPeerCallbacks callbacks,
  }) async {
    final pc = await createPeerConnection(configuration);
    final peer = _WebRtcPtyPeer(
      pc: pc,
      callbacks: callbacks,
      maxBufferedBytes: maxBufferedBytes,
    );
    try {
      peer.bind();
      if (initiator) {
        final channel = await pc.createDataChannel(
          'cc-handoff.pty.v1',
          reliablePtyDataChannelInit(),
        );
        await peer.attachChannel(channel);
      }
      return peer;
    } catch (error, stack) {
      try {
        await peer.close();
      } catch (_) {}
      Error.throwWithStackTrace(error, stack);
    }
  }
}

RTCDataChannelInit reliablePtyDataChannelInit() => RTCDataChannelInit()
  ..ordered = true
  ..maxRetransmitTime = -1
  ..maxRetransmits = -1
  ..negotiated = false;

class _WebRtcPtyPeer implements PtyPeer {
  _WebRtcPtyPeer({
    required this._pc,
    required this._callbacks,
    required this.maxBufferedBytes,
  });

  final RTCPeerConnection _pc;
  final PtyPeerCallbacks _callbacks;
  final int maxBufferedBytes;
  late final PtyBufferGate _bufferGate = PtyBufferGate(
    maxBufferedBytes: maxBufferedBytes,
  );
  RTCDataChannel? _channel;
  Future<void> _sendTail = Future<void>.value();
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
        unawaited(channel.close());
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
      await channel.close();
      return;
    }
    if (_channel != null && !identical(_channel, channel)) {
      await channel.close();
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

  @override
  Future<PtyDescription> createOffer() async {
    final offer = await _pc.createOffer();
    await _pc.setLocalDescription(offer);
    return _localDescription('offer');
  }

  @override
  Future<PtyDescription> acceptOffer(PtyDescription offer) async {
    await _pc.setRemoteDescription(
      RTCSessionDescription(offer.sdp, offer.type),
    );
    final answer = await _pc.createAnswer();
    await _pc.setLocalDescription(answer);
    return _localDescription('answer');
  }

  @override
  Future<void> acceptAnswer(PtyDescription answer) =>
      _pc.setRemoteDescription(RTCSessionDescription(answer.sdp, answer.type));

  Future<PtyDescription> _localDescription(String expectedType) async {
    final description = await _pc.getLocalDescription();
    final sdp = description?.sdp;
    final type = description?.type;
    if (sdp == null || sdp.isEmpty || type != expectedType) {
      throw StateError('missing WebRTC $expectedType description');
    }
    return PtyDescription(type: type!, sdp: sdp);
  }

  @override
  Future<void> addIce(PtyIceCandidate candidate) => _pc.addCandidate(
    RTCIceCandidate(
      candidate.candidate,
      candidate.sdpMid,
      candidate.sdpMLineIndex,
    ),
  );

  @override
  Future<bool> sendPackets(List<Uint8List> packets) async {
    final previous = _sendTail;
    final done = Completer<void>();
    _sendTail = done.future;
    await previous;
    try {
      final channel = _channel;
      if (_closing ||
          channel == null ||
          channel.state != RTCDataChannelState.RTCDataChannelOpen) {
        return false;
      }
      for (final packet in packets) {
        if (_closing ||
            channel.state != RTCDataChannelState.RTCDataChannelOpen) {
          return false;
        }
        final hasCapacity = await _bufferGate.waitForCapacity(
          bytes: packet.length,
          readBufferedAmount: channel.getBufferedAmount,
          isOpen: () =>
              !_closing &&
              channel.state == RTCDataChannelState.RTCDataChannelOpen,
        );
        if (!hasCapacity) return false;
        await channel.send(RTCDataChannelMessage.fromBinary(packet));
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      done.complete();
    }
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _bufferGate.close();
    final channel = _channel;
    _channel = null;
    try {
      await channel?.close();
    } finally {
      await _pc.close();
    }
  }
}
