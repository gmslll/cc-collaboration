import 'dart:convert';

import 'package:libghostty/libghostty.dart' as ghostty;

class GhosttySequenceTools {
  GhosttySequenceTools._();

  static ghostty.OscCommand? parseOsc(String payload, {int terminator = 0x07}) {
    final parser = ghostty.OscParser();
    try {
      parser.feedBytes(utf8.encode(payload));
      return parser.end(terminator);
    } catch (_) {
      return null;
    } finally {
      parser.dispose();
    }
  }

  static List<ghostty.SgrAttribute> parseSgr(Iterable<int> params) {
    final parser = ghostty.SgrParser();
    try {
      return parser.parse(params.toList(growable: false));
    } catch (_) {
      return const [];
    } finally {
      parser.dispose();
    }
  }
}
