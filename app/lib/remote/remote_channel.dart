import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'ws_connect.dart';

abstract interface class RemoteSocket {
  Future<void> get ready;
  Stream<dynamic> get stream;
  void add(dynamic data);
  Future<void> close();
}

typedef RemoteSocketConnector = RemoteSocket Function(Uri uri, String token);

class _WebSocketRemoteSocket implements RemoteSocket {
  _WebSocketRemoteSocket(this.channel);

  final WebSocketChannel channel;

  @override
  Future<void> get ready => channel.ready;

  @override
  Stream<dynamic> get stream => channel.stream;

  @override
  void add(dynamic data) => channel.sink.add(data);

  @override
  Future<void> close() => channel.sink.close();
}

RemoteSocket _connectRemoteSocket(Uri uri, String token) =>
    _WebSocketRemoteSocket(connectWs(uri, token));

// RemoteChannel is the shared transport for both ends of the remote workspace:
// it owns the relay WebSocket (connect, auth, auto-reconnect), the /v1/ws URL
// normalization, the `_hello`/`_peer` control frames, and frame send/dispatch.
// RemoteHost and RemoteClient subclass it and implement only their app frames.
abstract class RemoteChannel extends ChangeNotifier {
  final String relayUrl;
  final String token;
  final String role; // 'host' | 'client'
  RemoteChannel({
    required this.relayUrl,
    required this.token,
    required this.role,
    RemoteSocketConnector? socketConnector,
  }) : _socketConnector = socketConnector ?? _connectRemoteSocket;

  final RemoteSocketConnector _socketConnector;
  RemoteSocket? _ch;
  RemoteSocket? _pendingSocket;
  Timer? _authHeartbeat;
  int? _connId; // this connection's id (from the relay's _hello)
  int _generation = 0;
  bool _running = false;
  bool _disposed = false;
  String? lastError;

  bool get connected => _ch != null;
  bool get active => _running; // sharing/connecting requested (vs. wire state)

  void start() {
    if (_running || _disposed) return;
    _running = true;
    final generation = ++_generation;
    _notify();
    unawaited(_loop(generation));
  }

  void stop() {
    _running = false;
    _generation++;
    _authHeartbeat?.cancel();
    _authHeartbeat = null;
    final ch = _ch;
    final pending = _pendingSocket;
    _ch = null;
    _pendingSocket = null;
    unawaited(_closeQuietly(ch));
    if (!identical(pending, ch)) unawaited(_closeQuietly(pending));
    _connId = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _running = false;
    _generation++;
    _authHeartbeat?.cancel();
    _authHeartbeat = null;
    final ch = _ch;
    final pending = _pendingSocket;
    _ch = null;
    _pendingSocket = null;
    unawaited(_closeQuietly(ch));
    if (!identical(pending, ch)) unawaited(_closeQuietly(pending));
    super.dispose();
  }

  // kick forces an immediate reconnect by closing the current socket (the
  // _loop's `await for` then ends and reconnects). Used on phone foreground
  // resume: a backgrounded socket is usually already dead, so don't wait up to
  // a full ping interval to notice. No-op when not running / not connected.
  void kick() {
    if (!_running) return;
    unawaited(_closeQuietly(_ch));
  }

  // --- subclass hooks ---
  void onConnected() {}
  void onDisconnected() {}
  void onPeer(int connId, String role, bool connected) {}
  void onFrame(Map<String, dynamic> frame);

  // send writes a frame, stamping the sender's connId as `from` so a peer can
  // reply directly (`to`); the relay routes by `to`/role and ignores the rest.
  void send(Map<String, dynamic> frame) {
    final ch = _ch;
    if (ch == null) return;
    frame['from'] = _connId ?? 0;
    try {
      ch.add(jsonEncode(frame));
    } catch (_) {}
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static Uri _uri(String relayUrl, String role) {
    var raw = relayUrl.trim();
    if (!raw.contains('://')) raw = 'ws://$raw';

    final parsed = Uri.parse(raw);
    final scheme = switch (parsed.scheme.toLowerCase()) {
      'https' => 'wss',
      'http' => 'ws',
      'wss' || 'ws' => parsed.scheme.toLowerCase(),
      final other => other,
    };
    final basePath = parsed.path.replaceAll(RegExp(r'/+$'), '');
    final port = parsed.hasPort && parsed.port != 0 ? parsed.port : null;
    return Uri(
      scheme: scheme,
      host: parsed.host,
      port: port,
      path: basePath.isEmpty ? '/v1/ws' : '$basePath/v1/ws',
      queryParameters: {'role': role},
    );
  }

  @visibleForTesting
  static Uri uriForTesting(String relayUrl, String role) =>
      _uri(relayUrl, role);

  bool _isCurrent(int generation, RemoteSocket ch) =>
      !_disposed && _running && generation == _generation && identical(_ch, ch);

  static Future<void> _closeQuietly(RemoteSocket? ch) async {
    try {
      await ch?.close();
    } catch (_) {}
  }

  Future<void> _loop(int generation) async {
    while (_running && !_disposed && generation == _generation) {
      lastError = null;
      RemoteSocket? ch;
      var installed = false;
      try {
        ch = _socketConnector(_uri(relayUrl, role), token);
        _pendingSocket = ch;
        // ready completes on a successful handshake (or throws → reconnect). On
        // native the channel also pings every 20s so a dead peer is detected
        // (the stream ends, the loop reconnects) — mobile NAT/proxies silently
        // drop idle TCP; on web the browser owns keepalive. See ws_connect.dart.
        await ch.ready;
        if (_disposed || !_running || generation != _generation) {
          await _closeQuietly(ch);
          return;
        }
        if (identical(_pendingSocket, ch)) _pendingSocket = null;
        _ch = ch;
        installed = true;
        // PTY bytes may travel entirely over a WebRTC DataChannel. Keep a small
        // authenticated Relay text frame flowing so the server re-checks a
        // disabled/deleted account and closes the control socket; both peers
        // then tear down P2P in onDisconnected instead of retaining access.
        _authHeartbeat?.cancel();
        _authHeartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
          if (_isCurrent(generation, ch!)) send({'t': '_ping'});
        });
        _notify();
        await for (final msg in ch.stream) {
          if (!_isCurrent(generation, ch)) break;
          if (msg is String) _dispatch(msg);
        }
      } catch (e) {
        if (!_disposed && _running && generation == _generation) {
          lastError = '$e';
        }
      }
      if (ch != null && _isCurrent(generation, ch)) {
        _authHeartbeat?.cancel();
        _authHeartbeat = null;
        _ch = null;
        _connId = null;
        onDisconnected();
        _notify();
      } else if (!installed &&
          !_disposed &&
          _running &&
          generation == _generation) {
        _notify();
      }
      if (identical(_pendingSocket, ch)) _pendingSocket = null;
      await _closeQuietly(ch);
      if (!_running || _disposed || generation != _generation) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  void _dispatch(String raw) {
    Map<String, dynamic> f;
    try {
      f = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (f['t']) {
      case '_hello':
        _connId = (f['connId'] as num?)?.toInt();
        onConnected();
      case '_peer':
        final id = (f['connId'] as num?)?.toInt();
        final r = f['role'] as String?;
        if (id != null && r != null) onPeer(id, r, f['event'] == 'connect');
      default:
        onFrame(f);
    }
  }
}
