import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'file_transfer.dart';

// True on native (this file is only compiled when dart:library.io exists), so
// the web-safe UI can gate the file-transfer controls without touching Platform.
const bool kFileTransferSupported = true;

// _DigestCatcher captures the final Digest from a chunked sha256 conversion
// (same trick as file_transfer.dart, avoiding package:convert's AccumulatorSink).
class _DigestCatcher implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

// Native (dart:io) disk layer for file transfer — selected by file_fs.dart when
// dart:library.io exists. Host (macOS) lands files in ~/Downloads/cc-recv; the
// phone client lands them in its app Documents/cc-recv. The macOS app runs
// unsandboxed (see Runner entitlements) so ~/Downloads is writable directly.

Future<Directory> _landingDir({required bool host}) async {
  Directory base;
  if (host) {
    final home = Platform.environment['HOME'] ?? '';
    base = Directory(
      home.isEmpty ? Directory.systemTemp.path : '$home/Downloads',
    );
  } else {
    base = await getApplicationDocumentsDirectory();
  }
  final dir = Directory('${base.path}/cc-recv');
  await dir.create(recursive: true);
  return dir;
}

// _dedupePath returns a free path in [dir] for [name] (foo.png, foo-1.png, …),
// checking both the final name and its .part sibling so a re-sent file or a
// concurrent transfer of the same name never clobbers an in-flight one.
String _dedupePath(Directory dir, String name) {
  bool taken(String p) =>
      File(p).existsSync() || File('$p.part').existsSync();
  var candidate = '${dir.path}/$name';
  if (!taken(candidate)) return candidate;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 1; i < 10000; i++) {
    candidate = '${dir.path}/$stem-$i$ext';
    if (!taken(candidate)) return candidate;
  }
  return '${dir.path}/$stem-${DateTime.now().millisecondsSinceEpoch}$ext';
}

class _IoChunkSink implements FileChunkSink {
  _IoChunkSink(this._tmp, this._raf, this._finalPath);
  final File _tmp;
  final RandomAccessFile _raf;
  final String _finalPath;

  @override
  Future<void> add(List<int> bytes) => _raf.writeFrom(bytes);

  @override
  Future<String> finish() async {
    await _raf.flush();
    await _raf.close();
    final out = await _tmp.rename(_finalPath); // same dir → atomic move
    return out.path;
  }

  @override
  Future<void> abort() async {
    try {
      await _raf.close();
    } catch (_) {}
    try {
      if (await _tmp.exists()) await _tmp.delete();
    } catch (_) {}
  }
}

// openReceiveSink makes the landing dir and opens a temp <final>.part file for a
// just-offered transfer. Used as FileReceiver.openSink.
Future<FileChunkSink> openReceiveSink(
  IncomingFile info, {
  required bool host,
}) async {
  final dir = await _landingDir(host: host);
  final finalPath = _dedupePath(dir, info.name);
  final tmp = File('$finalPath.part');
  final raf = await tmp.open(mode: FileMode.write);
  return _IoChunkSink(tmp, raf, finalPath);
}

// FileSendHandle is a live outgoing transfer the UI can cancel and await.
class FileSendHandle {
  FileSendHandle(this.xid, this._cancel, this.done);
  final String xid;
  final void Function() _cancel;
  final Future<void> done;
  void cancel() => _cancel();
}

const Map<String, String> _mimes = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'json': 'application/json',
  'zip': 'application/zip',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'mp3': 'audio/mpeg',
};

String? _guessMime(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  return _mimes[name.substring(dot + 1).toLowerCase()];
}

// sendFileOverChannel reads [path] and streams it as file.offer/chunk/end frames
// via [send] (which routes through RemoteChannel). It reads 256KB at a time,
// computes a streaming sha256, yields between chunks so a big file doesn't
// starve the UI isolate, and honors cancel(). Routing: pass [to] for host→a
// specific client (or 0 to broadcast); omit it on the client so it reaches the
// host.
FileSendHandle sendFileOverChannel({
  required String path,
  required void Function(Map<String, dynamic> frame) send,
  int? to,
  String? sid,
  void Function(int sent, int total)? onProgress,
  void Function(bool ok, String msg)? onDone,
}) {
  final xid = 'f${DateTime.now().microsecondsSinceEpoch}-${path.hashCode & 0xffff}';
  var cancelled = false;
  final completer = Completer<void>();

  Future<void> run() async {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      final size = await file.length();
      if (size > kMaxFileBytes) {
        onDone?.call(false, '文件过大 (上限 100MB)');
        return;
      }
      final name = sanitizeFileName(path.split('/').last);
      send(fileOfferFrame(
        xid: xid,
        name: name,
        size: size,
        mime: _guessMime(name),
        sid: sid,
        to: to,
      ));
      raf = await file.open();
      final digestOut = _DigestCatcher();
      final digestIn = sha256.startChunkedConversion(digestOut);
      final buf = Uint8List(kFileChunkBytes);
      var seq = 0;
      var sent = 0;
      while (sent < size) {
        if (cancelled) {
          send(fileCancelFrame(xid: xid, reason: '已取消', to: to));
          onDone?.call(false, '已取消');
          return;
        }
        final n = await raf.readInto(buf);
        if (n <= 0) break;
        final slice = n == buf.length ? buf : Uint8List.sublistView(buf, 0, n);
        digestIn.add(slice);
        send(fileChunkFrame(xid: xid, seq: seq++, dataB64: base64Encode(slice), to: to));
        sent += n;
        onProgress?.call(sent, size);
        await Future<void>.delayed(Duration.zero); // let the UI breathe
      }
      digestIn.close();
      send(fileEndFrame(xid: xid, sha256: digestOut.value.toString(), to: to));
      onDone?.call(true, '已发送');
    } catch (e) {
      send(fileCancelFrame(xid: xid, reason: '$e', to: to));
      onDone?.call(false, '$e');
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
      if (!completer.isCompleted) completer.complete();
    }
  }

  unawaited(run());
  return FileSendHandle(xid, () => cancelled = true, completer.future);
}
