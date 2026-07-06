import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

// crash_log writes uncaught Dart errors + lifecycle breadcrumbs to a rolling
// <appSupport>/crash.log. On Windows the app can vanish outright ("闪退") on a
// NATIVE crash (ConPTY / text-input), which no Dart error handler can catch —
// so the value here is the breadcrumb trail: the tail of the file shows the
// last thing that happened before the process died (e.g. `pty.spawn ts3` or
// `ime.focus ts2`), which localizes the crash even when nothing is thrown.
//
// Everything is best-effort: logging must never itself throw or block startup.

File? _logFile;

// Trim the log when it grows past this so it can't balloon across many runs.
const int _maxBytes = 256 * 1024;

// initCrashLog resolves the app-support crash.log path (same dir as
// session_kv.json / terminal persistence) and rolls it if it got large. Call
// once at startup, before installCrashHandlers.
Future<void> initCrashLog() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/crash.log');
    try {
      if (await f.exists() && await f.length() > _maxBytes) {
        await f.writeAsString('');
      }
    } catch (_) {}
    _logFile = f;
    logBreadcrumb('=== app start · pid $pid · ${Platform.operatingSystem} ===');
  } catch (_) {
    // No writable app-support dir → skip logging entirely, never block startup.
  }
}

void _append(String line) {
  final f = _logFile;
  if (f == null) return;
  try {
    f.writeAsStringSync(line, mode: FileMode.append, flush: true);
  } catch (_) {}
}

String _ts() => DateTime.now().toIso8601String();

// logBreadcrumb records a lifecycle event (session spawn/exit, IME focus, …).
// Cheap enough to call on hot lifecycle paths.
void logBreadcrumb(String msg) => _append('${_ts()} · $msg\n');

// logCrash records an uncaught error + stack.
void logCrash(Object error, StackTrace? stack) =>
    _append('${_ts()} !! $error\n${stack ?? StackTrace.current}\n');

// installCrashHandlers routes Flutter framework errors and uncaught async
// (platform-dispatcher) errors into crash.log, while preserving the existing
// on-screen behavior (FlutterError still presents; the app keeps running). It
// does NOT replace ErrorWidget.builder — main() sets that separately.
void installCrashHandlers() {
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    logCrash(details.exception, details.stack);
    if (prev != null) {
      prev(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logCrash(error, stack);
    return true; // handled — a stray async error shouldn't hard-crash the app
  };
}
