// connectWs(uri, token) opens the relay WebSocket with the right implementation
// per platform: dart:io (header auth + 20s ping) on desktop/mobile, the browser
// socket (token in ?access_token=) on web. RemoteChannel uses only the returned
// WebSocketChannel's stream/sink, so it stays platform-agnostic.
export 'ws_connect_io.dart' if (dart.library.html) 'ws_connect_web.dart';
