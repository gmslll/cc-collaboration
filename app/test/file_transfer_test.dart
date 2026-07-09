import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:app/remote/file_fs_io.dart';
import 'package:app/remote/file_transfer.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// In-memory sink so the round-trip test doesn't touch the real landing dirs.
class _MemSink implements FileChunkSink {
  _MemSink(this.path);
  final String path;
  final BytesBuilder _b = BytesBuilder();
  bool aborted = false;
  @override
  Future<void> add(List<int> bytes) async => _b.add(bytes);
  @override
  Future<String> finish() async => path;
  @override
  Future<void> abort() async => aborted = true;
  Uint8List get bytes => _b.toBytes();
}

void main() {
  test('sanitizeFileName strips paths and traversal', () {
    expect(sanitizeFileName('/etc/passwd'), 'passwd');
    expect(sanitizeFileName('a/b/c.png'), 'c.png');
    expect(sanitizeFileName(r'C:\evil\x.txt'), 'x.txt');
    expect(sanitizeFileName('..'), 'file');
    expect(sanitizeFileName(''), 'file');
  });

  test('openReceiveSink sanitizes direct disk sink names', () async {
    final tmp = await Directory.systemTemp.createTemp('cc-ft-sink');
    addTearDown(() => tmp.delete(recursive: true));

    final sink = await openReceiveSink(
      IncomingFile('x', '../nested/evil.txt', 3, null, 1),
      host: true,
      landingDirOverride: tmp,
    );
    await sink.add([1, 2, 3]);
    final path = await sink.finish();

    expect(path, '${tmp.path}/evil.txt');
    expect(await File(path).readAsBytes(), [1, 2, 3]);
    expect(File('${tmp.parent.path}/nested/evil.txt').existsSync(), isFalse);
  });

  test('send → receive preserves bytes + sha256 across many chunks', () async {
    final tmp = await Directory.systemTemp.createTemp('cc-ft');
    addTearDown(() => tmp.delete(recursive: true));
    final src = File('${tmp.path}/src.bin');
    // 700KB of pseudo-random bytes → 3 chunks (256+256+188KB), exercising the
    // streaming sha256 and the multi-chunk reassembly path.
    final rnd = Random(42);
    final data = Uint8List.fromList(
      List.generate(700 * 1024, (_) => rnd.nextInt(256)),
    );
    await src.writeAsBytes(data);

    _MemSink? sink;
    final done = Completer<String>();
    final rx = FileReceiver(
      openSink: (info) async => sink = _MemSink('${tmp.path}/dst.bin'),
      sendFrame: (_) {}, // acks ignored in this test
      onComplete: (info, path) => done.complete(path),
      onError: (info, reason) => done.completeError(reason),
    );

    sendFileOverChannel(
      path: src.path,
      send: (f) {
        f['from'] = 1; // emulate the relay stamping the sender's connId
        rx.dispatch(Map<String, dynamic>.from(f));
      },
    );

    await done.future.timeout(const Duration(seconds: 10));
    expect(sink, isNotNull);
    expect(sink!.bytes.length, data.length);
    expect(
      sha256.convert(sink!.bytes).toString(),
      sha256.convert(data).toString(),
    );
  });

  test(
    'a corrupted sha256 is rejected and the partial file is aborted',
    () async {
      final tmp = await Directory.systemTemp.createTemp('cc-ft');
      addTearDown(() => tmp.delete(recursive: true));

      _MemSink? sink;
      final done = Completer<String>();
      final rx = FileReceiver(
        openSink: (info) async => sink = _MemSink('${tmp.path}/dst.bin'),
        sendFrame: (_) {},
        onComplete: (info, path) => done.complete(path),
        onError: (info, reason) => done.completeError(reason),
      );

      rx.dispatch({
        't': 'file.offer',
        'from': 1,
        'xid': 'x',
        'name': 'a.bin',
        'size': 3,
      });
      rx.dispatch({
        't': 'file.chunk',
        'from': 1,
        'xid': 'x',
        'seq': 0,
        'data': 'AQID',
      }); // [1,2,3]
      rx.dispatch({
        't': 'file.end',
        'from': 1,
        'xid': 'x',
        'sha256': 'deadbeef',
      });

      await expectLater(done.future, throwsA(contains('校验')));
      expect(sink!.aborted, isTrue);
    },
  );
}
