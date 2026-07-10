import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

const String ptySignalFrameType = 'pty.signal';
const int ptyMaxPacketBytes = 16 * 1024;

enum PtyTransportMode {
  auto,
  p2p,
  relay;

  String get wireName => name;

  static PtyTransportMode? fromWire(Object? value) {
    for (final mode in values) {
      if (value == mode.wireName) return mode;
    }
    return null;
  }
}

enum PtyPeerState { relay, connecting, p2p, failed, closed }

enum PtySendResult { sentP2p, useRelay, unavailable }

class PtyPeerStatus {
  const PtyPeerStatus({
    required this.peerId,
    required this.mode,
    required this.state,
    this.epoch = 0,
    this.error,
  });

  final int peerId;
  final PtyTransportMode mode;
  final PtyPeerState state;
  final int epoch;
  final String? error;
}

class PtyDescription {
  const PtyDescription({required this.type, required this.sdp});

  final String type;
  final String sdp;

  Map<String, dynamic> toJson() => {'type': type, 'sdp': sdp};

  static PtyDescription? fromJson(Object? value) {
    if (value is! Map) return null;
    final type = value['type'];
    final sdp = value['sdp'];
    if (type is! String ||
        sdp is! String ||
        type.isEmpty ||
        sdp.isEmpty ||
        sdp.length > 2 * 1024 * 1024) {
      return null;
    }
    if (type != 'offer' && type != 'answer') return null;
    return PtyDescription(type: type, sdp: sdp);
  }
}

class PtyIceCandidate {
  const PtyIceCandidate({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  Map<String, dynamic> toJson() => {
    'candidate': candidate,
    if (sdpMid != null) 'sdpMid': sdpMid,
    if (sdpMLineIndex != null) 'sdpMLineIndex': sdpMLineIndex,
  };

  static PtyIceCandidate? fromJson(Object? value) {
    if (value is! Map) return null;
    final candidate = value['candidate'];
    if (candidate is! String || candidate.isEmpty || candidate.length > 4096) {
      return null;
    }
    final line = value['sdpMLineIndex'];
    if (line != null && line is! int) return null;
    final mid = value['sdpMid'];
    if (mid != null && (mid is! String || mid.length > 256)) return null;
    return PtyIceCandidate(
      candidate: candidate,
      sdpMid: mid is String ? mid : null,
      sdpMLineIndex: line is int ? line : null,
    );
  }
}

typedef PtyPacketHandler = void Function(Uint8List packet);
typedef PtyIceHandler = void Function(PtyIceCandidate candidate);
typedef PtyPeerStateHandler = void Function(PtyPeerState state, String? error);

class PtyPeerCallbacks {
  const PtyPeerCallbacks({
    required this.onPacket,
    required this.onIce,
    required this.onState,
  });

  final PtyPacketHandler onPacket;
  final PtyIceHandler onIce;
  final PtyPeerStateHandler onState;
}

abstract interface class PtyPeer {
  Future<PtyDescription> createOffer();
  Future<PtyDescription> acceptOffer(PtyDescription offer);
  Future<void> acceptAnswer(PtyDescription answer);
  Future<void> addIce(PtyIceCandidate candidate);

  /// Sends the batch in order. False means it did not complete; callers must
  /// fail the route rather than replay the frame over another transport.
  Future<bool> sendPackets(List<Uint8List> packets);

  Future<void> close();
}

abstract interface class PtyPeerFactory {
  Future<PtyPeer> create({
    required int peerId,
    required bool initiator,
    required PtyPeerCallbacks callbacks,
  });
}

typedef PtySignalSender = void Function(Map<String, dynamic> frame);
typedef PtyFrameHandler = void Function(int peerId, Map<String, dynamic> frame);
typedef PtyStatusHandler = void Function(PtyPeerStatus status);

bool isPtyDataFrame(Object? value) {
  if (value is! Map) return false;
  return switch (value['t']) {
    'term.ready' || 'term.input' || 'term.output' || 'term.resize' => true,
    _ => false,
  };
}

class PtyPacketCodec {
  static const int _headerBytes = 12;
  static const int _magic = 0x5054;
  static const int _version = 1;
  static const int _maxMessageBytes = 2 * 1024 * 1024;
  static const int _maxParts = 160;

  static List<Uint8List> encode(
    Map<String, dynamic> frame, {
    required int messageId,
  }) {
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(frame)));
    if (payload.length > _maxMessageBytes) {
      throw const FormatException('PTY frame exceeds 2 MiB');
    }
    final payloadPerPacket = ptyMaxPacketBytes - _headerBytes;
    final count = payload.isEmpty
        ? 1
        : (payload.length + payloadPerPacket - 1) ~/ payloadPerPacket;
    if (count > _maxParts) {
      throw const FormatException('PTY frame has too many parts');
    }
    return [
      for (var index = 0; index < count; index++)
        _packet(
          messageId,
          index,
          count,
          payload.sublist(
            index * payloadPerPacket,
            ((index + 1) * payloadPerPacket).clamp(0, payload.length),
          ),
        ),
    ];
  }

  static Uint8List _packet(
    int messageId,
    int index,
    int count,
    Uint8List payload,
  ) {
    final packet = Uint8List(_headerBytes + payload.length);
    final header = ByteData.sublistView(packet);
    header.setUint16(0, _magic);
    header.setUint8(2, _version);
    header.setUint8(3, 0);
    header.setUint32(4, messageId);
    header.setUint16(8, index);
    header.setUint16(10, count);
    packet.setRange(_headerBytes, packet.length, payload);
    return packet;
  }
}

class PtyPacketReassembler {
  static const int _headerBytes = 12;
  static const int _magic = 0x5054;
  static const int _version = 1;
  static const int _maxMessageBytes = 2 * 1024 * 1024;
  static const int _maxParts = 160;
  static const int _maxActiveMessages = 4;
  static const int _maxBufferedBytes = 4 * 1024 * 1024;

  final Map<int, _PtyPacketAssembly> _active = {};
  int _bufferedBytes = 0;

  Map<String, dynamic>? add(Uint8List packet) {
    if (packet.length < _headerBytes || packet.length > ptyMaxPacketBytes) {
      throw const FormatException('Invalid PTY packet length');
    }
    final header = ByteData.sublistView(packet);
    if (header.getUint16(0) != _magic ||
        header.getUint8(2) != _version ||
        header.getUint8(3) != 0) {
      throw const FormatException('Invalid PTY packet header');
    }
    final messageId = header.getUint32(4);
    final index = header.getUint16(8);
    final count = header.getUint16(10);
    if (count == 0 || count > _maxParts || index >= count) {
      throw const FormatException('Invalid PTY packet part');
    }

    var assembly = _active[messageId];
    if (assembly == null) {
      if (_active.length >= _maxActiveMessages) {
        throw const FormatException('Too many incomplete PTY frames');
      }
      assembly = _PtyPacketAssembly(count);
      _active[messageId] = assembly;
    } else if (assembly.parts.length != count) {
      _drop(messageId);
      throw const FormatException('PTY packet count changed');
    }
    if (assembly.parts[index] != null) {
      _drop(messageId);
      throw const FormatException('Duplicate PTY packet part');
    }
    final payload = Uint8List.sublistView(packet, _headerBytes);
    if (_bufferedBytes + payload.length > _maxBufferedBytes) {
      _drop(messageId);
      throw const FormatException('Too much buffered PTY data');
    }
    assembly.parts[index] = Uint8List.fromList(payload);
    assembly.bytes += payload.length;
    _bufferedBytes += payload.length;
    if (assembly.bytes > _maxMessageBytes) {
      _drop(messageId);
      throw const FormatException('PTY frame exceeds 2 MiB');
    }
    if (assembly.parts.any((part) => part == null)) return null;

    _drop(messageId);
    final all = BytesBuilder(copy: false);
    for (final part in assembly.parts) {
      all.add(part!);
    }
    final decoded = jsonDecode(
      utf8.decode(all.takeBytes(), allowMalformed: false),
    );
    if (decoded is! Map) throw const FormatException('PTY frame is not a map');
    return Map<String, dynamic>.from(decoded);
  }

  void _drop(int messageId) {
    final removed = _active.remove(messageId);
    if (removed != null) _bufferedBytes -= removed.bytes;
  }

  void clear() {
    _active.clear();
    _bufferedBytes = 0;
  }
}

class _PtyPacketAssembly {
  _PtyPacketAssembly(int count) : parts = List<Uint8List?>.filled(count, null);

  final List<Uint8List?> parts;
  int bytes = 0;
}

abstract class PtyTransportController {
  PtyTransportController._(
    this._mode,
    this._peerFactory,
    this._sendSignal,
    this._onFrame,
    this._onStatus,
  );

  final PtyPeerFactory _peerFactory;
  final PtySignalSender _sendSignal;
  final PtyFrameHandler _onFrame;
  final PtyStatusHandler? _onStatus;
  final Map<int, _PtyPeerSession> _sessions = {};
  final Map<int, PtyPeerStatus> _statuses = {};
  final Map<int, int> _latestRemoteOfferEpoch = {};
  final Map<(int, int), List<PtyIceCandidate>> _earlyIce = {};
  final Map<int, Future<void>> _signalTails = {};
  PtyTransportMode _mode;
  int _nextEpoch = 0;
  int _nextMessageId = 0;
  bool _disposed = false;

  PtyTransportMode get mode => _mode;

  PtyPeerStatus statusFor(int peerId) =>
      _statuses[peerId] ??
      PtyPeerStatus(
        peerId: peerId,
        mode: _mode,
        state: _mode == PtyTransportMode.relay
            ? PtyPeerState.relay
            : PtyPeerState.closed,
      );

  Future<void> setMode(PtyTransportMode next) async {
    if (_disposed || next == _mode) return;
    _mode = next;
    if (next == PtyTransportMode.relay) {
      await _closeAll(PtyPeerState.relay);
    }
    await onModeChanged();
  }

  Future<void> onModeChanged() async {}

  Future<PtySendResult> sendPtyFrame(
    int peerId,
    Map<String, dynamic> frame,
  ) async {
    if (_disposed || !isPtyDataFrame(frame)) return PtySendResult.useRelay;
    if (_mode == PtyTransportMode.relay) return PtySendResult.useRelay;
    final session = _sessions[peerId];
    if (session == null ||
        session.state != PtyPeerState.p2p ||
        session.peer == null) {
      return _mode == PtyTransportMode.auto
          ? PtySendResult.useRelay
          : PtySendResult.unavailable;
    }

    try {
      final packets = PtyPacketCodec.encode(
        frame,
        messageId: _nextMessageId = (_nextMessageId + 1) & 0xffffffff,
      );
      final sent = await session.peer!.sendPackets(packets);
      if (sent) return PtySendResult.sentP2p;
      if (identical(_sessions[peerId], session)) {
        await _failSession(peerId, session.epoch, 'data channel backpressure');
      }
    } catch (error) {
      if (identical(_sessions[peerId], session)) {
        await _failSession(peerId, session.epoch, '$error');
      }
    }
    // Once a frame was assigned to an open DataChannel route, never retry that
    // same frame through Relay: a partial batch could otherwise duplicate input
    // or output. Auto mode recovers by opening a fresh Relay route instead.
    return PtySendResult.unavailable;
  }

  Future<bool> handleSignal(Map<String, dynamic> frame) {
    if (frame['t'] != ptySignalFrameType) return Future<bool>.value(false);
    final from = frame['from'];
    if (_disposed || from is! int || from <= 0) return Future<bool>.value(true);
    final snapshot = Map<String, dynamic>.from(frame);
    final previous = _signalTails[from] ?? Future<void>.value();
    final queued = previous.then((_) => _handleSignal(snapshot));
    // Relay is ordered per connection. Preserve that order per peer without a
    // slow phone blocking negotiation for every other phone.
    final settled = queued.then<void>((_) {}, onError: (_) {});
    _signalTails[from] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_signalTails[from], settled)) _signalTails.remove(from);
      }),
    );
    return queued.then<bool>((_) => true, onError: (_) => true);
  }

  Future<void> _handleSignal(Map<String, dynamic> frame) async {
    final from = frame['from'];
    final kind = frame['kind'];
    if (from is! int || from <= 0 || kind is! String || _disposed) return;
    if (kind == 'mode') {
      final remoteMode = PtyTransportMode.fromWire(frame['mode']);
      if (remoteMode != null) await onRemoteMode(from, remoteMode);
      return;
    }
    final epoch = frame['epoch'];
    if (epoch is! int || epoch <= 0) return;
    switch (kind) {
      case 'offer':
        final offer = PtyDescription.fromJson(frame['description']);
        if (offer != null && offer.type == 'offer') {
          await acceptOffer(from, epoch, offer);
        }
      case 'answer':
        final answer = PtyDescription.fromJson(frame['description']);
        if (answer != null && answer.type == 'answer') {
          await _acceptAnswer(from, epoch, answer);
        }
      case 'ice':
        final candidate = PtyIceCandidate.fromJson(frame['candidate']);
        if (candidate != null) await _acceptIce(from, epoch, candidate);
      case 'close':
        await _closeSession(from, epoch, PtyPeerState.closed);
    }
  }

  Future<void> onRemoteMode(int peerId, PtyTransportMode remoteMode) async {}

  Future<void> acceptOffer(int peerId, int epoch, PtyDescription offer) async {
    if (_mode == PtyTransportMode.relay) {
      _sendClose(peerId, epoch, 'relay mode');
      return;
    }
    final latest = _latestRemoteOfferEpoch[peerId] ?? 0;
    if (epoch <= latest) return;
    _latestRemoteOfferEpoch[peerId] = epoch;
    await _replaceSession(peerId, epoch, initiator: false);
    final session = _sessions[peerId];
    final peer = session?.peer;
    if (session == null || peer == null || session.epoch != epoch) return;
    try {
      final answer = await peer.acceptOffer(offer);
      if (!_isCurrent(peerId, epoch, peer)) return;
      session.remoteDescriptionReady = true;
      await _drainIce(peerId, session);
      _signal(peerId, 'answer', epoch, description: answer.toJson());
    } catch (error) {
      await _failSession(peerId, epoch, '$error');
    }
  }

  Future<void> startOffer(int peerId) async {
    if (_disposed || _mode == PtyTransportMode.relay) return;
    final epoch = ++_nextEpoch;
    await _replaceSession(peerId, epoch, initiator: true);
    final session = _sessions[peerId];
    final peer = session?.peer;
    if (session == null || peer == null || session.epoch != epoch) return;
    try {
      final offer = await peer.createOffer();
      if (!_isCurrent(peerId, epoch, peer)) return;
      _signal(peerId, 'offer', epoch, description: offer.toJson());
    } catch (error) {
      await _failSession(peerId, epoch, '$error');
    }
  }

  Future<void> peerDisconnected(int peerId) async {
    _latestRemoteOfferEpoch.remove(peerId);
    await restartPeer(peerId);
  }

  /// Closes one transport attempt while retaining the highest remote offer
  /// epoch. Used for retry on the same Relay connId so a delayed old offer
  /// cannot be accepted again between close and the replacement offer.
  Future<void> restartPeer(int peerId) async {
    _earlyIce.removeWhere((key, _) => key.$1 == peerId);
    final session = _sessions[peerId];
    if (session != null) {
      await _closeSession(peerId, session.epoch, PtyPeerState.closed);
    }
    _statuses.remove(peerId);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait(_signalTails.values.toList());
    _signalTails.clear();
    await _closeAll(PtyPeerState.closed);
    _earlyIce.clear();
  }

  Future<void> _replaceSession(
    int peerId,
    int epoch, {
    required bool initiator,
  }) async {
    final old = _sessions.remove(peerId);
    await _closePeer(old?.peer);
    old?.reassembler.clear();
    if (_disposed || _mode == PtyTransportMode.relay) return;
    final session = _PtyPeerSession(epoch, initiator);
    _sessions[peerId] = session;
    _setStatus(peerId, PtyPeerState.connecting, epoch);
    try {
      final peer = await _peerFactory.create(
        peerId: peerId,
        initiator: initiator,
        callbacks: PtyPeerCallbacks(
          onPacket: (packet) => _receivePacket(peerId, epoch, packet),
          onIce: (candidate) {
            if (_sessions[peerId]?.epoch == epoch) {
              _signal(peerId, 'ice', epoch, candidate: candidate.toJson());
            }
          },
          onState: (state, error) =>
              _peerStateChanged(peerId, epoch, state, error),
        ),
      );
      if (_disposed || _sessions[peerId] != session) {
        await _closePeer(peer);
        return;
      }
      session.peer = peer;
    } catch (error) {
      await _failSession(peerId, epoch, '$error');
    }
  }

  Future<void> _acceptAnswer(
    int peerId,
    int epoch,
    PtyDescription answer,
  ) async {
    final session = _sessions[peerId];
    final peer = session?.peer;
    if (session == null ||
        peer == null ||
        session.epoch != epoch ||
        !session.initiator) {
      return;
    }
    try {
      await peer.acceptAnswer(answer);
      if (!_isCurrent(peerId, epoch, peer)) return;
      session.remoteDescriptionReady = true;
      await _drainIce(peerId, session);
    } catch (error) {
      await _failSession(peerId, epoch, '$error');
    }
  }

  Future<void> _acceptIce(
    int peerId,
    int epoch,
    PtyIceCandidate candidate,
  ) async {
    final session = _sessions[peerId];
    if (session == null ||
        session.epoch != epoch ||
        !session.remoteDescriptionReady) {
      final latest = _latestRemoteOfferEpoch[peerId] ?? 0;
      if (epoch < latest) return;
      final key = (peerId, epoch);
      var queue = _earlyIce[key];
      if (queue == null) {
        final peerEpochs = _earlyIce.keys
            .where((candidateKey) => candidateKey.$1 == peerId)
            .length;
        if (_earlyIce.length >= 32 || peerEpochs >= 4) return;
        queue = <PtyIceCandidate>[];
        _earlyIce[key] = queue;
      }
      if (queue.length < 32) queue.add(candidate);
      return;
    }
    try {
      await session.peer?.addIce(candidate);
    } catch (error) {
      await _failSession(peerId, epoch, '$error');
    }
  }

  Future<void> _drainIce(int peerId, _PtyPeerSession session) async {
    final pending = _earlyIce.remove((peerId, session.epoch)) ?? const [];
    for (final candidate in pending) {
      if (_sessions[peerId] != session) return;
      await session.peer?.addIce(candidate);
    }
    _earlyIce.removeWhere(
      (key, _) => key.$1 == peerId && key.$2 < session.epoch,
    );
  }

  void _receivePacket(int peerId, int epoch, Uint8List packet) {
    final session = _sessions[peerId];
    if (session == null || session.epoch != epoch) return;
    try {
      final frame = session.reassembler.add(packet);
      if (frame == null) return;
      if (!isPtyDataFrame(frame)) {
        throw const FormatException('Non-PTY frame on PTY data channel');
      }
      _onFrame(peerId, frame);
    } catch (error) {
      unawaited(_failSession(peerId, epoch, '$error'));
    }
  }

  void _peerStateChanged(
    int peerId,
    int epoch,
    PtyPeerState state,
    String? error,
  ) {
    final session = _sessions[peerId];
    if (session == null || session.epoch != epoch) return;
    session.state = state;
    _setStatus(peerId, state, epoch, error);
    if (state == PtyPeerState.failed || state == PtyPeerState.closed) {
      unawaited(_closeSession(peerId, epoch, state, error: error));
    }
  }

  bool _isCurrent(int peerId, int epoch, PtyPeer peer) =>
      !_disposed &&
      _sessions[peerId]?.epoch == epoch &&
      identical(_sessions[peerId]?.peer, peer);

  Future<void> _failSession(int peerId, int epoch, String error) async {
    _sendClose(peerId, epoch, error);
    await _closeSession(peerId, epoch, PtyPeerState.failed, error: error);
  }

  Future<void> _closeSession(
    int peerId,
    int epoch,
    PtyPeerState state, {
    String? error,
  }) async {
    final session = _sessions[peerId];
    if (session == null || session.epoch != epoch) return;
    _sessions.remove(peerId);
    session.reassembler.clear();
    await _closePeer(session.peer);
    final replacement = _sessions[peerId];
    if (replacement != null && replacement.epoch != epoch) return;
    final currentStatus = _statuses[peerId];
    if (currentStatus != null && currentStatus.epoch > epoch) return;
    _setStatus(peerId, state, epoch, error);
  }

  Future<void> _closeAll(PtyPeerState state) async {
    final sessions = _sessions.entries.toList();
    _sessions.clear();
    for (final entry in sessions) {
      entry.value.reassembler.clear();
      await _closePeer(entry.value.peer);
      _setStatus(entry.key, state, entry.value.epoch);
    }
  }

  static Future<void> _closePeer(PtyPeer? peer) async {
    try {
      final closing = peer?.close();
      if (closing != null) {
        await closing.timeout(const Duration(seconds: 3));
      }
    } catch (_) {}
  }

  void _signal(
    int peerId,
    String kind,
    int epoch, {
    Map<String, dynamic>? description,
    Map<String, dynamic>? candidate,
  }) {
    _sendSignal({
      't': ptySignalFrameType,
      'to': peerId,
      'kind': kind,
      'epoch': epoch,
      'description': ?description,
      'candidate': ?candidate,
    });
  }

  void _sendClose(int peerId, int epoch, String reason) {
    _sendSignal({
      't': ptySignalFrameType,
      'to': peerId,
      'kind': 'close',
      'epoch': epoch,
      'reason': reason,
    });
  }

  void sendMode(int peerId) {
    _sendSignal({
      't': ptySignalFrameType,
      'to': peerId,
      'kind': 'mode',
      'mode': _mode.wireName,
    });
  }

  void _setStatus(int peerId, PtyPeerState state, int epoch, [String? error]) {
    final status = PtyPeerStatus(
      peerId: peerId,
      mode: _mode,
      state: state,
      epoch: epoch,
      error: error,
    );
    _statuses[peerId] = status;
    _onStatus?.call(status);
  }
}

class PtyHostTransportController extends PtyTransportController {
  PtyHostTransportController({
    required PtyTransportMode mode,
    required PtyPeerFactory peerFactory,
    required PtySignalSender sendSignal,
    required PtyFrameHandler onFrame,
    PtyStatusHandler? onStatus,
  }) : super._(mode, peerFactory, sendSignal, onFrame, onStatus);

  final Set<int> _connectedPeers = {};
  final Map<int, PtyTransportMode> _remoteModes = {};

  void peerConnected(int peerId) {
    if (peerId > 0) _connectedPeers.add(peerId);
  }

  @override
  Future<void> acceptOffer(int peerId, int epoch, PtyDescription offer) async {
    _sendClose(peerId, epoch, 'host does not accept PTY offers');
  }

  @override
  Future<void> peerDisconnected(int peerId) async {
    _connectedPeers.remove(peerId);
    _remoteModes.remove(peerId);
    await super.peerDisconnected(peerId);
  }

  @override
  Future<void> onRemoteMode(int peerId, PtyTransportMode remoteMode) async {
    if (!_connectedPeers.contains(peerId)) return;
    _remoteModes[peerId] = remoteMode;
    await _reconcile(peerId);
  }

  @override
  Future<void> onModeChanged() async {
    for (final peerId in _connectedPeers.toList()) {
      await _reconcile(peerId);
    }
  }

  Future<void> _reconcile(int peerId) async {
    final remoteMode = _remoteModes[peerId];
    if (mode == PtyTransportMode.relay ||
        remoteMode == PtyTransportMode.relay) {
      final status = statusFor(peerId);
      if (status.epoch > 0) {
        await peerDisconnected(peerId);
        _connectedPeers.add(peerId);
        if (remoteMode != null) _remoteModes[peerId] = remoteMode;
      }
      return;
    }
    if (remoteMode != null &&
        statusFor(peerId).state != PtyPeerState.connecting &&
        statusFor(peerId).state != PtyPeerState.p2p) {
      await startOffer(peerId);
    }
  }
}

class PtyClientTransportController extends PtyTransportController {
  PtyClientTransportController({
    required PtyTransportMode mode,
    required PtyPeerFactory peerFactory,
    required PtySignalSender sendSignal,
    required PtyFrameHandler onFrame,
    PtyStatusHandler? onStatus,
  }) : super._(mode, peerFactory, sendSignal, onFrame, onStatus);

  int? _hostPeerId;

  void hostConnected(int peerId) {
    if (peerId <= 0) return;
    _hostPeerId = peerId;
    sendMode(peerId);
  }

  @override
  Future<void> peerDisconnected(int peerId) async {
    if (_hostPeerId == peerId) _hostPeerId = null;
    await super.peerDisconnected(peerId);
  }

  @override
  Future<void> onModeChanged() async {
    final host = _hostPeerId;
    if (host != null) sendMode(host);
  }
}

class _PtyPeerSession {
  _PtyPeerSession(this.epoch, this.initiator);

  final int epoch;
  final bool initiator;
  final PtyPacketReassembler reassembler = PtyPacketReassembler();
  PtyPeer? peer;
  PtyPeerState state = PtyPeerState.connecting;
  bool remoteDescriptionReady = false;
}
