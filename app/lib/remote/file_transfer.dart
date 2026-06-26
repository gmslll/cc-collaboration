import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// file_transfer.dart is the web-safe protocol core for sending a file over the
// remote-workspace WebSocket (see RemoteChannel). It carries NO dart:io: the
// frame builders and the receiver are pure Dart so the phone client (compiled
// into the web bundle too) can import it. Actual disk reads/writes live behind
// the file_fs.dart conditional facade and are injected here as a sink.
//
// Wire protocol (symmetric — host↔client use the same frames):
//   file.offer  {xid, name, size, mime?, sid?}  announce a transfer
//   file.chunk  {xid, seq, data}                 data = base64 of a raw slice
//   file.end    {xid, sha256?}                   finalize; receiver verifies
//   file.cancel {xid, reason}                    sender or receiver aborts
//   file.ack    {xid, ok, savedPath?, msg?}      receiver reports the outcome
// `from` is stamped by RemoteChannel.send; the receiver acks back with to:from.

// Raw bytes per file.chunk. base64 inflates 256KB to ~341KB — well under the
// relay's 8MB frame cap — and the relay's permessage-deflate shrinks the wire
// cost further. Bigger chunks mean fewer frames but more work per encode/decode.
const int kFileChunkBytes = 256 * 1024;

// Hard ceiling on one transfer so a buggy or hostile peer can't fill the disk.
const int kMaxFileBytes = 100 * 1024 * 1024; // 100MB

// sanitizeFileName strips any directory component and rejects traversal so a
// received name can only ever be a leaf written into our own landing dir.
String sanitizeFileName(String raw) {
  var n = raw.split('/').last.split('\\').last.trim();
  if (n.isEmpty || n == '.' || n == '..') n = 'file';
  // Drop control chars / NULs that could confuse the filesystem.
  n = n.replaceAll(RegExp(r'[\x00-\x1f]'), '');
  return n.isEmpty ? 'file' : n;
}

// --- frame builders -------------------------------------------------------

Map<String, dynamic> fileOfferFrame({
  required String xid,
  required String name,
  required int size,
  String? mime,
  String? sid,
  int? to,
}) => {
  't': 'file.offer',
  'to': ?to,
  'xid': xid,
  'name': name,
  'size': size,
  'mime': ?mime,
  'sid': ?sid,
};

Map<String, dynamic> fileChunkFrame({
  required String xid,
  required int seq,
  required String dataB64,
  int? to,
}) => {
  't': 'file.chunk',
  'to': ?to,
  'xid': xid,
  'seq': seq,
  'data': dataB64,
};

Map<String, dynamic> fileEndFrame({required String xid, String? sha256, int? to}) => {
  't': 'file.end',
  'to': ?to,
  'xid': xid,
  'sha256': ?sha256,
};

Map<String, dynamic> fileCancelFrame({
  required String xid,
  String reason = '',
  int? to,
}) => {
  't': 'file.cancel',
  'to': ?to,
  'xid': xid,
  'reason': reason,
};

Map<String, dynamic> fileAckFrame({
  required String xid,
  required bool ok,
  String? savedPath,
  String? msg,
  int? to,
}) => {
  't': 'file.ack',
  'to': ?to,
  'xid': xid,
  'ok': ok,
  'savedPath': ?savedPath,
  'msg': ?msg,
};

// Metadata for an incoming transfer, taken from its file.offer frame.
class IncomingFile {
  final String xid;
  final String name; // already sanitized
  final int size;
  final String? mime;
  final int from; // sender's connId, for routing the ack back
  IncomingFile(this.xid, this.name, this.size, this.mime, this.from);
}

// FileChunkSink is the disk-write side, injected so this module stays web-safe.
// add() is called in receive order; finish() closes and returns the saved path;
// abort() discards a partial transfer. Implemented natively in file_fs_io.dart.
abstract class FileChunkSink {
  Future<void> add(List<int> bytes);
  Future<String> finish(); // returns the final saved path
  Future<void> abort();
}

// DigestCatcher captures the final Digest from a chunked sha256 conversion,
// avoiding a dependency on package:convert's AccumulatorSink. Shared by the
// receiver here and the sender in file_fs_io.dart.
class DigestCatcher implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

// _Incoming holds the live state of one transfer being received.
class _Incoming {
  _Incoming(this.info);
  final IncomingFile info;
  FileChunkSink? sink;
  // Writes are serialized on this future chain so out-of-order awaits can't
  // interleave bytes (chunks arrive in order, but each write is async).
  Future<void> chain = Future<void>.value();
  int received = 0;
  int nextSeq = 0;
  bool failed = false;
  // Streaming sha256 so we never hold the whole file in memory.
  final DigestCatcher _digestOut = DigestCatcher();
  late final ByteConversionSink _digestIn = sha256.startChunkedConversion(
    _digestOut,
  );
  String digestHex() {
    _digestIn.close();
    return _digestOut.value.toString();
  }
}

// FileReceiver assembles incoming file.* frames into files on disk. It is fed
// parsed frames by RemoteHost/RemoteClient and drives an injected sink + acks.
class FileReceiver {
  FileReceiver({
    required this.openSink,
    required this.sendFrame,
    this.onProgress,
    this.onComplete,
    this.onError,
  });

  // openSink creates a disk sink for a just-offered file (makes the landing
  // dir, opens a temp file). Native-only; never called on web.
  final Future<FileChunkSink> Function(IncomingFile info) openSink;
  // sendFrame routes a reply frame (ack/cancel) back through the channel.
  final void Function(Map<String, dynamic> frame) sendFrame;
  final void Function(IncomingFile info, int received)? onProgress;
  final void Function(IncomingFile info, String savedPath)? onComplete;
  final void Function(IncomingFile info, String reason)? onError;

  final Map<String, _Incoming> _live = {};

  // dispatch returns true if it handled the frame (a file.* type).
  bool dispatch(Map<String, dynamic> f) {
    switch (f['t']) {
      case 'file.offer':
        _onOffer(f);
        return true;
      case 'file.chunk':
        _onChunk(f);
        return true;
      case 'file.end':
        _onEnd(f);
        return true;
      case 'file.cancel':
        _onCancel(f);
        return true;
    }
    return false;
  }

  void _fail(_Incoming inc, String reason, {bool tellPeer = true}) {
    if (inc.failed) return;
    inc.failed = true;
    inc.chain = inc.chain.then((_) async {
      try {
        await inc.sink?.abort();
      } catch (_) {}
    });
    _live.remove(inc.info.xid);
    if (tellPeer) {
      sendFrame(fileCancelFrame(xid: inc.info.xid, reason: reason, to: inc.info.from));
    }
    sendFrame(fileAckFrame(xid: inc.info.xid, ok: false, msg: reason, to: inc.info.from));
    onError?.call(inc.info, reason);
  }

  void _onOffer(Map<String, dynamic> f) {
    final xid = f['xid'] as String?;
    final from = (f['from'] as num?)?.toInt() ?? 0;
    final size = (f['size'] as num?)?.toInt() ?? -1;
    if (xid == null) return;
    if (_live.containsKey(xid)) return; // duplicate offer; ignore
    if (size < 0 || size > kMaxFileBytes) {
      sendFrame(fileCancelFrame(xid: xid, reason: '文件过大或无效', to: from));
      sendFrame(fileAckFrame(xid: xid, ok: false, msg: '文件过大或无效', to: from));
      return;
    }
    final info = IncomingFile(
      xid,
      sanitizeFileName((f['name'] as String?) ?? 'file'),
      size,
      f['mime'] as String?,
      from,
    );
    final inc = _Incoming(info);
    _live[xid] = inc;
    // Open the sink asynchronously; queue it on the chain so the first chunk
    // waits for the file handle.
    inc.chain = inc.chain.then((_) async {
      try {
        inc.sink = await openSink(info);
      } catch (e) {
        _fail(inc, '无法创建文件: $e');
      }
    });
  }

  void _onChunk(Map<String, dynamic> f) {
    final xid = f['xid'] as String?;
    final inc = xid == null ? null : _live[xid];
    if (inc == null || inc.failed) return;
    final seq = (f['seq'] as num?)?.toInt() ?? -1;
    final data = f['data'] as String?;
    if (seq != inc.nextSeq || data == null) {
      _fail(inc, '分片乱序');
      return;
    }
    inc.nextSeq++;
    Uint8List bytes;
    try {
      bytes = base64Decode(data);
    } catch (_) {
      _fail(inc, '分片解码失败');
      return;
    }
    inc.received += bytes.length;
    if (inc.received > inc.info.size) {
      _fail(inc, '数据超出声明大小');
      return;
    }
    inc._digestIn.add(bytes);
    inc.chain = inc.chain.then((_) async {
      if (inc.failed) return;
      try {
        await inc.sink!.add(bytes);
        onProgress?.call(inc.info, inc.received);
      } catch (e) {
        _fail(inc, '写入失败: $e');
      }
    });
  }

  void _onEnd(Map<String, dynamic> f) {
    final xid = f['xid'] as String?;
    final inc = xid == null ? null : _live[xid];
    if (inc == null || inc.failed) return;
    final declaredSha = f['sha256'] as String?;
    inc.chain = inc.chain.then((_) async {
      if (inc.failed) return;
      if (inc.received != inc.info.size) {
        _fail(inc, '大小不符 (${inc.received}/${inc.info.size})');
        return;
      }
      if (declaredSha != null && inc.digestHex() != declaredSha) {
        _fail(inc, '校验和不符');
        return;
      }
      try {
        final path = await inc.sink!.finish();
        _live.remove(xid);
        sendFrame(fileAckFrame(xid: xid!, ok: true, savedPath: path, to: inc.info.from));
        onComplete?.call(inc.info, path);
      } catch (e) {
        _fail(inc, '保存失败: $e');
      }
    });
  }

  void _onCancel(Map<String, dynamic> f) {
    final xid = f['xid'] as String?;
    final inc = xid == null ? null : _live[xid];
    if (inc == null) return;
    // Peer-initiated cancel: clean up locally, don't echo a cancel back.
    _fail(inc, (f['reason'] as String?) ?? '已取消', tellPeer: false);
  }
}
