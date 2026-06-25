// Session persistence backend, picked per platform: the OS secure store
// (Keychain/Keystore) on desktop/mobile, browser localStorage on web. The web
// split avoids flutter_secure_storage's secure-context (HTTPS-only) requirement,
// which otherwise breaks the web client over plain http. Both expose
// kvRead / kvWrite / kvDelete.
export 'session_kv_io.dart' if (dart.library.html) 'session_kv_web.dart';
