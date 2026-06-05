import 'dart:async';
import 'dart:convert';
import 'dart:io';

class SseEvent {
  final String type;
  final String data;
  SseEvent(this.type, this.data);
}

// subscribeEvents streams the relay's SSE feed (/v1/events?recipient=<me>),
// auto-reconnecting on drop. Each `data:` line is dispatched with the preceding
// `event:` type. Cancel the subscription to stop (and end the reconnect loop).
Stream<SseEvent> subscribeEvents(
    String baseUrl, String token, String recipient) async* {
  final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
  final uri = Uri.parse(
      '$base/v1/events?recipient=${Uri.encodeQueryComponent(recipient)}');
  final client = HttpClient();
  try {
    while (true) {
      try {
        final req = await client.getUrl(uri);
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
        final resp = await req.close();
        if (resp.statusCode != 200) {
          await resp.drain<void>();
          await Future<void>.delayed(const Duration(seconds: 3));
          continue;
        }
        var type = 'message';
        final lines =
            resp.transform(utf8.decoder).transform(const LineSplitter());
        await for (final line in lines) {
          if (line.isEmpty) {
            type = 'message';
          } else if (line.startsWith('event:')) {
            type = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            yield SseEvent(type, line.substring(5).trim());
          }
        }
      } catch (_) {
        // fall through to reconnect
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  } finally {
    client.close(force: true);
  }
}
