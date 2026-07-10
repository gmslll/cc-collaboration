import 'dart:async';

import 'package:app/remote/remote_channel.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRemoteSocket implements RemoteSocket {
  final readyCompleter = Completer<void>();
  final controller = StreamController<dynamic>();
  final sent = <dynamic>[];
  int closeCount = 0;

  @override
  Future<void> get ready => readyCompleter.future;

  @override
  Stream<dynamic> get stream => controller.stream;

  @override
  void add(dynamic data) => sent.add(data);

  @override
  Future<void> close() async {
    closeCount++;
    if (!controller.isClosed) await controller.close();
  }
}

class _TestRemoteChannel extends RemoteChannel {
  _TestRemoteChannel(RemoteSocketConnector connector)
    : super(
        relayUrl: 'https://relay.test',
        token: 'token',
        role: 'client',
        socketConnector: connector,
      );

  int connectedCount = 0;
  int disconnectedCount = 0;

  @override
  void onConnected() => connectedCount++;

  @override
  void onDisconnected() => disconnectedCount++;

  @override
  void onFrame(Map<String, dynamic> frame) {}
}

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

  test('drops an invalid explicit port zero', () {
    final uri = RemoteChannel.uriForTesting(
      'https://handoff.infist.cn:0/',
      'client',
    );

    expect(uri.toString(), 'wss://handoff.infist.cn/v1/ws?role=client');
  });

  test('preserves an explicit port and relay base path', () {
    final uri = RemoteChannel.uriForTesting(
      'http://127.0.0.1:18080/relay/',
      'host',
    );

    expect(uri.toString(), 'ws://127.0.0.1:18080/relay/v1/ws?role=host');
  });

  test(
    'stop then start cannot let an old handshake replace the new socket',
    () async {
      final first = _FakeRemoteSocket();
      final second = _FakeRemoteSocket();
      final sockets = [first, second];
      final channel = _TestRemoteChannel((_, _) => sockets.removeAt(0));

      channel.start();
      channel.stop();
      channel.start();
      first.readyCompleter.complete();
      await Future<void>.delayed(Duration.zero);
      expect(channel.connected, isFalse);

      second.readyCompleter.complete();
      await Future<void>.delayed(Duration.zero);
      second.controller.add('{"t":"_hello","connId":2}');
      await Future<void>.delayed(Duration.zero);

      expect(channel.connected, isTrue);
      expect(channel.connectedCount, 1);
      expect(first.closeCount, greaterThanOrEqualTo(1));
      channel.dispose();
    },
  );

  test('dispose during handshake never resurrects the socket', () async {
    final socket = _FakeRemoteSocket();
    final channel = _TestRemoteChannel((_, _) => socket);

    channel.start();
    channel.dispose();
    socket.readyCompleter.complete();
    await Future<void>.delayed(Duration.zero);

    expect(channel.connected, isFalse);
    expect(channel.connectedCount, 0);
    expect(socket.closeCount, greaterThanOrEqualTo(1));
  });
}
