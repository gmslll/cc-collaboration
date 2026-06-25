import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// Native (desktop/mobile) WebSocket: pass the bearer token as a header — the
// relay's normal auth path — and keep a 20s WS ping so a dead peer is detected
// (the channel closes, driving the reconnect in RemoteChannel._loop). This is
// the original dart:io behaviour, unchanged for host + phone.
WebSocketChannel connectWs(Uri uri, String token) => IOWebSocketChannel.connect(
  uri,
  headers: {'Authorization': 'Bearer $token'},
  pingInterval: const Duration(seconds: 20),
);
