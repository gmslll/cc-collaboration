import 'package:libghostty/libghostty.dart' as ghostty;

class GhosttyRuntime {
  GhosttyRuntime._();

  static Future<void>? _initializing;
  static bool _initialized = false;
  static final Uri _defaultWasmUri = Uri.parse(
    'assets/assets/libghostty-wasm32-freestanding.wasm',
  );

  static bool get initialized => _initialized;

  static Future<bool> ensureInitialized({
    Uri? wasmUri,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final future = _initializing ??= _initialize(wasmUri);
    try {
      await future.timeout(timeout);
    } catch (_) {
      _initialized = false;
      _initializing = null;
    }
    return _initialized;
  }

  static Future<void> _initialize(Uri? wasmUri) async {
    try {
      await ghostty.initializeForWeb(wasmUri ?? _defaultWasmUri);
      _initialized = true;
    } catch (_) {
      _initialized = false;
      _initializing = null;
    }
  }
}
