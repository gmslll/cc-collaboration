// file_fs.dart is the conditional facade for the file-transfer disk layer:
// native (macOS host / iOS client) gets file_fs_io.dart; the web bundle gets
// file_fs_stub.dart (file transfer is a no-op on web). Same pattern as
// ws_connect.dart / prefs_store.dart in this repo. Consumers import THIS file
// and only ever see the API below (openReceiveSink / sendFileOverChannel /
// FileSendHandle), keeping remote_client.dart dart:io-free for the web build.
export 'file_fs_stub.dart' if (dart.library.io) 'file_fs_io.dart';
