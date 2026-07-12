import 'dart:async';
import 'dart:convert';

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

  test('probe acknowledges a healthy socket without reconnecting', () async {
    final socket = _FakeRemoteSocket();
    final channel = _TestRemoteChannel((_, _) => socket);
    addTearDown(channel.dispose);

    channel.start();
    socket.readyCompleter.complete();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add('{"t":"_hello","connId":7}');
    await Future<void>.delayed(Duration.zero);

    final result = channel.probe(timeout: const Duration(seconds: 1));
    final request =
        jsonDecode(socket.sent.last as String) as Map<String, dynamic>;
    expect(request['t'], '_probe');
    socket.controller.add(jsonEncode({'t': '_probeAck', 'id': request['id']}));

    expect(await result, isTrue);
    expect(channel.connected, isTrue);
    expect(socket.closeCount, 0);
  });

  test(
    'probe timeout reports stale without closing the socket itself',
    () async {
      final socket = _FakeRemoteSocket();
      final channel = _TestRemoteChannel((_, _) => socket);
      addTearDown(channel.dispose);

      channel.start();
      socket.readyCompleter.complete();
      await Future<void>.delayed(Duration.zero);
      socket.controller.add('{"t":"_hello","connId":8}');
      await Future<void>.delayed(Duration.zero);

      expect(
        await channel.probe(timeout: const Duration(milliseconds: 10)),
        isFalse,
      );
      expect(channel.connected, isTrue);
      expect(socket.closeCount, 0);
    },
  );

  test('stale probe does not invalidate a replacement socket', () async {
    final first = _FakeRemoteSocket();
    final second = _FakeRemoteSocket();
    var connections = 0;
    final channel = _TestRemoteChannel((_, _) {
      connections++;
      return connections == 1 ? first : second;
    });
    addTearDown(channel.dispose);

    channel.start();
    first.readyCompleter.complete();
    await Future<void>.delayed(Duration.zero);
    first.controller.add('{"t":"_hello","connId":8}');
    await Future<void>.delayed(Duration.zero);

    final result = channel.probe(timeout: const Duration(seconds: 5));
    channel.stop();
    channel.start();
    second.readyCompleter.complete();
    await Future<void>.delayed(Duration.zero);
    second.controller.add('{"t":"_hello","connId":9}');
    await Future<void>.delayed(Duration.zero);

    expect(await result, isTrue);
    expect(channel.connected, isTrue);
    expect(second.closeCount, 0);
  });
}
