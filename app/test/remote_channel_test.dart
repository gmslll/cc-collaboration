import 'package:app/remote/remote_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes https relay URLs to wss without leaking port zero', () {
    final uri = remoteWsUri('https://handoff.infist.cn:0/', 'client');

    expect(uri.toString(), 'wss://handoff.infist.cn/v1/ws?role=client');
  });

  test('preserves explicit non-zero ports and base paths', () {
    final uri = remoteWsUri('http://127.0.0.1:18080/relay/', 'host');

    expect(uri.toString(), 'ws://127.0.0.1:18080/relay/v1/ws?role=host');
  });
}
