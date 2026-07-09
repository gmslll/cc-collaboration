import 'package:app/remote/remote_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('websocket relay uri encodes role as a query parameter', () {
    final uri = RemoteChannel.uriForTesting(
      'https://relay.example.com/',
      'host+lead&x=wrong',
    );

    expect(uri.scheme, 'wss');
    expect(uri.path, '/v1/ws');
    expect(uri.queryParameters['role'], 'host+lead&x=wrong');
    expect(uri.queryParameters['x'], isNull);
    expect(
      uri.toString(),
      'wss://relay.example.com/v1/ws?role=host%2Blead%26x%3Dwrong',
    );
  });
}
