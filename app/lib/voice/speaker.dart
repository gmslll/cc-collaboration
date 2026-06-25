import 'package:flutter_tts/flutter_tts.dart';

// Speaker is the web-safe text-to-speech capability shared by the desktop
// (VoiceService) and the phone/web remote workspace. It depends ONLY on
// flutter_tts (which has a web implementation via the Web Speech *synthesis*
// API — supported broadly, including iOS Safari, unlike speech recognition), so
// it's safe to import into the web bundle. A new utterance interrupts the
// previous one.
class Speaker {
  final FlutterTts _tts = FlutterTts();
  bool _inited = false;

  Future<void> _ensureInit() async {
    if (_inited) return;
    _inited = true;
    await _tts.setLanguage('zh-CN');
    await _tts.awaitSpeakCompletion(true);
  }

  Future<void> speak(String text) async {
    await _ensureInit();
    await _tts.stop(); // interrupt any in-progress utterance
    await _tts.speak(text);
  }

  Future<void> stop() => _tts.stop();
}
