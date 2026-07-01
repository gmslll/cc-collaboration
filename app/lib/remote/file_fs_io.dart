import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../local/path_utils.dart';
import 'file_transfer.dart';

// True on native (this file is only compiled when dart:library.io exists), so
// the web-safe UI can gate the file-transfer controls without touching Platform.
const bool kFileTransferSupported = true;

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
  bool taken(String p) => File(p).existsSync() || File('$p.part').existsSync();
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

// FileSendHandle is a live outgoing transfer the UI can cancel and await. It
// also carries the accept/reject gate: after the sender announces (file.offer)
// it blocks until the receiver's decision routes back here as accept()/reject().
class FileSendHandle {
  FileSendHandle(this.xid, this._cancel, this.done, this._gate);
  final String xid;
  final void Function() _cancel;
  final Future<void> done;
  final Completer<bool> _gate;
  void cancel() => _cancel();
  // accept/reject resolve the consent gate the sender is waiting on (driven by
  // the receiver's file.accept / file.reject). Idempotent.
  void accept() {
    if (!_gate.isCompleted) _gate.complete(true);
  }

  void reject() {
    if (!_gate.isCompleted) _gate.complete(false);
  }
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

// Max time to wait for the receiver's accept after announcing an offer before
// giving up — so a phone that never answers (asleep, dialog dismissed) doesn't
// leave the sender hanging forever.
const Duration _acceptTimeout = Duration(seconds: 60);

// sendFileOverChannel reads [path] and streams it as file.offer/chunk/end frames
// via [send] (which routes through RemoteChannel). It reads 256KB at a time,
// computes a streaming sha256, yields between chunks so a big file doesn't
// starve the UI isolate, and honors cancel(). Routing: pass [to] for host→a
// specific client (or 0 to broadcast); omit it on the client so it reaches the
// host. When [requireAccept] is set the sender announces the offer and then
// waits for the receiver's file.accept (routed in via the handle) before
// streaming any data; a file.reject or a timeout aborts without sending bytes.
FileSendHandle sendFileOverChannel({
  required String path,
  required void Function(Map<String, dynamic> frame) send,
  int? to,
  String? sid,
  bool requireAccept = false,
  void Function(int sent, int total)? onProgress,
  void Function(bool ok, String msg)? onDone,
}) {
  final xid =
      'f${DateTime.now().microsecondsSinceEpoch}-${path.hashCode & 0xffff}';
  var cancelled = false;
  final completer = Completer<void>();
  final gate = Completer<bool>();

  Future<void> run() async {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      final size = await file.length();
      if (size > kMaxFileBytes) {
        onDone?.call(false, '文件过大 (上限 100MB)');
        return;
      }
      final name = sanitizeFileName(pathBaseName(path));
      send(
        fileOfferFrame(
          xid: xid,
          name: name,
          size: size,
          mime: _guessMime(name),
          sid: sid,
          to: to,
        ),
      );
      // Wait for the receiver to consent before streaming. accept()/reject() on
      // the handle complete this gate; cancel() is checked below.
      if (requireAccept) {
        bool accepted;
        try {
          accepted = await gate.future.timeout(_acceptTimeout);
        } on TimeoutException {
          send(fileCancelFrame(xid: xid, reason: '等待接受超时', to: to));
          onDone?.call(false, '对方未响应');
          return;
        }
        if (!accepted) {
          onDone?.call(false, '对方已拒绝');
          return;
        }
        if (cancelled) {
          send(fileCancelFrame(xid: xid, reason: '已取消', to: to));
          onDone?.call(false, '已取消');
          return;
        }
      }
      raf = await file.open();
      final digestOut = DigestCatcher();
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
        send(
          fileChunkFrame(
            xid: xid,
            seq: seq++,
            dataB64: base64Encode(slice),
            to: to,
          ),
        );
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
  return FileSendHandle(xid, () => cancelled = true, completer.future, gate);
}
