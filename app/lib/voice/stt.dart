import 'dart:async';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

const bool kSpeechDebugLogging = false;

// SpeechInput is the web-safe speech-to-text capability shared by the desktop
// (VoiceService) and the phone/web remote workspace. It depends ONLY on
// speech_to_text (which has a web implementation via the Web Speech API) — no
// dart:io / native-desktop plugins — so it's safe to import into the web bundle
// (main_web.dart → RemoteWorkspacePage). Native platforms use the OS Speech
// framework (on-device when the locale supports it); iOS Safari has no Web
// Speech API, so init() returns false and callers degrade gracefully.
//
// Two ways to listen:
//   • start()/stop()                 — one-shot: a single utterance (desktop
//                                      push-to-talk).
//   • startContinuous()/stopContinuous() — keep recognizing across the
//                                      recognizer's own silence/timeout
//                                      auto-stops by restarting it. The plugin
//                                      explicitly does NOT support always-on
//                                      listening (Android force-stops after a
//                                      1–5s pause), so this is a best-effort
//                                      restart loop intended for an explicit
//                                      dictation session (mic only runs while the
//                                      user has it on), backstopped by a watchdog
//                                      so a missed/odd lifecycle callback can't
//                                      freeze it.
class SpeechInput {
  final SpeechToText _stt = SpeechToText();
  bool _ready = false;
  String? _locale; // a "zh*" locale id if the platform has one, else null

  // Continuous-mode state: while true the recognizer is auto-restarted whenever
  // a session ends (silence/timeout/transient error) until stopContinuous().
  // _paused suspends restarts (e.g. while TTS plays); _restarting guards the
  // debounced restart; _fails counts consecutive transient errors for backoff.
  bool _continuous = false;
  bool _paused = false;
  bool _restarting = false;
  int _fails = 0;
  Timer? _watchdog;
  void Function(String text)? _contFinal;
  void Function(String text)? _contPartial;

  // Fires with the recognizer's listening state (true=listening) so the UI can
  // track auto-stops (silence/timeout), not just explicit stop.
  void Function(bool listening)? onListeningChange;

  // Last error from the recognizer (permission denied, no recognizer, etc.) so
  // the UI can show WHY voice input failed instead of a generic message.
  String? lastError;

  // onError fires with each recognizer error message; onDebug emits low-level
  // lifecycle events (status/listen/restart). Both feed live on-screen
  // diagnostics so a silent failure is visible.
  void Function(String error)? onError;
  void Function(String msg)? onDebug;

  bool get listening => _stt.isListening;

  Future<bool> init() async {
    if (_ready) return true;
    try {
      // Guard initialize with a timeout: on some devices the recognizer binding
      // hangs (e.g. no on-device service), which would otherwise leave the
      // caller awaiting forever — i.e. "the button does nothing".
      _ready = await _stt
          .initialize(
            onError: _onError,
            onStatus: _onStatus,
            debugLogging: kSpeechDebugLogging,
            finalTimeout: const Duration(seconds: 2),
          )
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () {
              lastError = '语音初始化超时(检查麦克风/语音识别权限,或设备无识别服务)';
              return false;
            },
          );
      if (!_ready) {
        lastError ??= '初始化失败:设备无可用的语音识别服务(需安装/启用 Google 语音服务)';
        return false;
      }
      // Pick a Chinese recognition locale if the platform offers one.
      for (final l in await _stt.locales()) {
        if (l.localeId.toLowerCase().startsWith('zh')) {
          _locale = l.localeId;
          break;
        }
      }
      // Clearer message if the mic permission isn't actually granted (init can
      // still report ready). We don't flip _ready — listen() will surface the
      // permission error too — but this gives the UI a precise reason up front.
      if (!await _stt.hasPermission) {
        lastError = '麦克风/语音识别权限未授予,请到系统设置开启';
      }
    } catch (e) {
      _ready = false;
      lastError = e.toString();
    }
    return _ready;
  }

  void _onStatus(String s) {
    onDebug?.call('status=$s');
    final isListening = s == 'listening';
    onListeningChange?.call(isListening);
    // The recognizer stops itself on silence/timeout; bring it back up quickly.
    // (The watchdog is the slower backstop in case this callback is missed.)
    if (!isListening && _continuous && !_paused) _scheduleRestart();
  }

  void _onError(SpeechRecognitionError e) {
    lastError = e.errorMsg;
    onError?.call(e.errorMsg);
    onListeningChange?.call(false);
    if (!_continuous) return;
    final msg = e.errorMsg.toLowerCase();
    // Permission is the only truly fatal class for a dictation session — stop.
    // (We deliberately do NOT treat e.permanent as fatal: Android marks
    // error_no_match permanent, but in a dictation loop we want to keep going.)
    if (msg.contains('permission') || msg.contains('denied')) {
      _continuous = false;
      _stopWatchdog();
      return;
    }
    // Locale unsupported/unavailable → drop the forced zh locale and retry with
    // the system default, which the device's recognizer is sure to support.
    if ((msg.contains('language') || msg.contains('locale')) &&
        _locale != null) {
      onDebug?.call('locale→system (was $_locale)');
      _locale = null;
    }
    _fails++;
    if (_fails == 5) onDebug?.call('识别服务多次无响应,降速重试');
    _scheduleRestart();
  }

  // start begins recognition; [onFinal] fires once with the finished transcript,
  // [onPartial] streams interim text. Returns false if STT is unavailable /
  // permission denied (e.g. iOS Safari, or the user declined the mic).
  Future<bool> start({
    required void Function(String text) onFinal,
    void Function(String text)? onPartial,
  }) async {
    if (!_ready && !await init()) return false;
    lastError = null;
    await _stt.listen(
      onResult: (SpeechRecognitionResult r) {
        if (r.finalResult) {
          onFinal(r.recognizedWords);
        } else {
          onPartial?.call(r.recognizedWords);
        }
      },
      listenOptions: _options(),
    );
    return true;
  }

  Future<void> stop() => _stt.stop();

  // startContinuous keeps recognizing across the recognizer's silence/timeout
  // auto-stops: [onFinal] fires once per finished utterance, [onPartial] streams
  // interim text. Returns false only if STT can't initialize at all (then check
  // lastError). Call stopContinuous() to end.
  Future<bool> startContinuous({
    required void Function(String text) onFinal,
    void Function(String text)? onPartial,
  }) async {
    if (!_ready && !await init()) return false;
    _contFinal = onFinal;
    _contPartial = onPartial;
    _continuous = true;
    _paused = false;
    _fails = 0;
    lastError = null;
    _startWatchdog();
    await _listenOnce();
    return true;
  }

  Future<void> stopContinuous() async {
    _continuous = false;
    _paused = false;
    _stopWatchdog();
    _contFinal = null;
    _contPartial = null;
    try {
      await _stt.stop();
    } catch (_) {}
  }

  // pause/resume suspend the recognizer without ending the session — e.g. while
  // TTS reads a reply, so the mic doesn't transcribe our own playback and the two
  // don't fight over the audio device. The watchdog relistens after resume().
  Future<void> pause() async {
    if (!_continuous) return;
    _paused = true;
    onDebug?.call('paused (tts)');
    try {
      await _stt.stop();
    } catch (_) {}
  }

  void resume() {
    if (!_continuous) return;
    _paused = false;
    onDebug?.call('resumed');
    _scheduleRestart();
  }

  Future<void> _listenOnce() async {
    if (!_continuous || _paused) return;
    onDebug?.call('listen()');
    try {
      await _stt.listen(
        onResult: (SpeechRecognitionResult r) {
          _fails = 0; // any audio reaching us means the pipeline works
          if (r.finalResult) {
            _contFinal?.call(r.recognizedWords);
          } else {
            _contPartial?.call(r.recognizedWords);
          }
        },
        listenOptions: _options(),
      );
    } catch (e) {
      lastError = e.toString();
      onDebug?.call('listen throw: $e');
      _scheduleRestart();
    }
  }

  // _scheduleRestart debounces restarts (a delay avoids "recognizer busy" before
  // the previous session tears down) with backoff once errors pile up, and stops
  // any half-torn-down session before relistening. (Gating on _stt.isListening
  // here proved unreliable — its state lags the status callback, which is what
  // froze the loop after the first auto-stop.)
  void _scheduleRestart() {
    if (!_continuous || _restarting || _paused) return;
    final ms = _fails >= 5 ? 3000 : 500;
    onDebug?.call('restart in ${ms}ms');
    _restarting = true;
    Future.delayed(Duration(milliseconds: ms), () async {
      _restarting = false;
      if (!_continuous || _paused) return;
      try {
        await _stt.stop();
      } catch (_) {}
      await _listenOnce();
    });
  }

  // The watchdog is the backstop: even if a status/error callback is missed or
  // arrives out of order (the original freeze), this re-arms the recognizer.
  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (_continuous && !_paused && !_restarting && !_stt.isListening) {
        _listenOnce();
      }
    });
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  // NOTE: do NOT force on-device recognition. macOS/iOS still use the local
  // Speech framework on-device when the locale supports it; requiring it
  // (requiresOnDeviceRecognition=true) just makes recognition FAIL for locales
  // without an on-device model (e.g. zh on many macOS installs) — which reads as
  // "voice input doesn't work". Leaving it off falls back gracefully. listenFor
  // is left null: a fixed cap makes some devices stop immediately; we rely on
  // pauseFor + the restart loop instead.
  SpeechListenOptions _options() => SpeechListenOptions(
    onDevice: false,
    partialResults: true,
    localeId: _locale,
    listenMode: ListenMode.dictation,
    pauseFor: const Duration(seconds: 3),
  );

  void dispose() {
    _continuous = false;
    _stopWatchdog();
    _stt.cancel();
  }
}
