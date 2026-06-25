import 'package:web_socket_channel/web_socket_channel.dart';

// Browser WebSocket: the handshake can't carry an Authorization header, so the
// token rides in the query (?access_token=), which the relay accepts as a
// fallback. The browser owns keepalive, so there's no app-level ping. Using the
// cross-platform WebSocketChannel.connect keeps us off the deprecated dart:html
// channel while still resolving to the browser socket on web.
WebSocketChannel connectWs(Uri uri, String token) => WebSocketChannel.connect(
  uri.replace(queryParameters: {...uri.queryParameters, 'access_token': token}),
);
