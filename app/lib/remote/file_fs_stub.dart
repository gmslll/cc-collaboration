import 'file_transfer.dart';

// Web stub for the file-transfer disk layer (see file_fs.dart). The web bundle
// has no dart:io, so file transfer is unavailable there; the UI is gated by
// platform and never calls these, but they must compile. Each throws so a stray
// call fails loudly rather than silently corrupting a transfer.

const bool kFileTransferSupported = false;

Future<FileChunkSink> openReceiveSink(
  IncomingFile info, {
  required bool host,
}) async {
  throw UnsupportedError('file transfer is not supported on web');
}

class FileSendHandle {
  FileSendHandle(this.xid, this._cancel, this.done);
  final String xid;
  final void Function() _cancel;
  final Future<void> done;
  void cancel() => _cancel();
}

FileSendHandle sendFileOverChannel({
  required String path,
  required void Function(Map<String, dynamic> frame) send,
  int? to,
  String? sid,
  void Function(int sent, int total)? onProgress,
  void Function(bool ok, String msg)? onDone,
}) {
  throw UnsupportedError('file transfer is not supported on web');
}
