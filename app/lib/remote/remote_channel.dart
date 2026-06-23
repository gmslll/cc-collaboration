import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

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
  });

  WebSocket? _ws;
  int? _connId; // this connection's id (from the relay's _hello)
  bool _running = false;
  bool _disposed = false;
  String? lastError;

  bool get connected => _ws != null;
  bool get active => _running; // sharing/connecting requested (vs. wire state)

  void start() {
    if (_running || _disposed) return;
    _running = true;
    _notify();
    unawaited(_loop());
  }

  void stop() {
    _running = false;
    _ws?.close();
    _ws = null;
    _connId = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _running = false;
    _ws?.close();
    super.dispose();
  }

  // --- subclass hooks ---
  void onConnected() {}
  void onDisconnected() {}
  void onPeer(int connId, String role, bool connected) {}
  void onFrame(Map<String, dynamic> frame);

  // send writes a frame, stamping the sender's connId as `from` so a peer can
  // reply directly (`to`); the relay routes by `to`/role and ignores the rest.
  void send(Map<String, dynamic> frame) {
    final ws = _ws;
    if (ws == null) return;
    frame['from'] = _connId ?? 0;
    try {
      ws.add(jsonEncode(frame));
    } catch (_) {}
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static Uri _uri(String relayUrl, String role) {
    var u = relayUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (u.startsWith('https://')) {
      u = 'wss://${u.substring(8)}';
    } else if (u.startsWith('http://')) {
      u = 'ws://${u.substring(7)}';
    } else if (!u.startsWith('ws://') && !u.startsWith('wss://')) {
      u = 'ws://$u';
    }
    return Uri.parse('$u/v1/ws?role=$role');
  }

  Future<void> _loop() async {
    while (_running) {
      lastError = null;
      try {
        final ws = await WebSocket.connect(
          _uri(relayUrl, role).toString(),
          headers: {'Authorization': 'Bearer $token'},
        );
        _ws = ws;
        _notify();
        await for (final msg in ws) {
          if (msg is String) _dispatch(msg);
        }
      } catch (e) {
        lastError = '$e';
      }
      _ws = null;
      _connId = null;
      onDisconnected();
      _notify();
      if (!_running) break;
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
