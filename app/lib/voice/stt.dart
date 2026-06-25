import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

// SpeechInput is the web-safe speech-to-text capability shared by the desktop
// (VoiceService) and the phone/web remote workspace. It depends ONLY on
// speech_to_text (which has a web implementation via the Web Speech API) — no
// dart:io / native-desktop plugins — so it's safe to import into the web bundle
// (main_web.dart → RemoteWorkspacePage). On-device recognition is forced on
// native platforms (privacy); on web the browser's recognizer is used (the Web
// Speech API has no on-device guarantee, and is unsupported on iOS Safari, where
// init() simply returns false and callers degrade gracefully).
class SpeechInput {
  final SpeechToText _stt = SpeechToText();
  bool _ready = false;
  String? _locale; // a "zh*" locale id if the platform has one, else null

  // Fires with the recognizer's listening state (true=listening) so the UI can
  // track auto-stops (silence/timeout), not just explicit stop.
  void Function(bool listening)? onListeningChange;

  bool get listening => _stt.isListening;

  Future<bool> init() async {
    if (_ready) return true;
    try {
      _ready = await _stt.initialize(
        onError: (_) => onListeningChange?.call(false),
        onStatus: (s) => onListeningChange?.call(s == 'listening'),
      );
      if (_ready) {
        for (final l in await _stt.locales()) {
          if (l.localeId.toLowerCase().startsWith('zh')) {
            _locale = l.localeId;
            break;
          }
        }
      }
    } catch (_) {
      _ready = false;
    }
    return _ready;
  }

  // start begins recognition; [onFinal] fires once with the finished transcript,
  // [onPartial] streams interim text. Returns false if STT is unavailable /
  // permission denied (e.g. iOS Safari, or the user declined the mic).
  Future<bool> start({
    required void Function(String text) onFinal,
    void Function(String text)? onPartial,
  }) async {
    if (!_ready && !await init()) return false;
    await _stt.listen(
      onResult: (SpeechRecognitionResult r) {
        if (r.finalResult) {
          onFinal(r.recognizedWords);
        } else {
          onPartial?.call(r.recognizedWords);
        }
      },
      listenOptions: SpeechListenOptions(
        onDevice: !kIsWeb, // native: on-device; web: browser recognizer
        partialResults: true,
        localeId: _locale,
        listenMode: ListenMode.dictation,
        listenFor: const Duration(minutes: 1),
        pauseFor: const Duration(seconds: 3),
      ),
    );
    return true;
  }

  Future<void> stop() => _stt.stop();

  void dispose() => _stt.cancel();
}
