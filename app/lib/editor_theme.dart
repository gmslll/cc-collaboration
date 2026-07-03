import 'package:flutter/painting.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';

// Shared syntax-highlighting theme for the code editor (editor_page.dart) and
// the diff viewers (syntax.dart) — both must point at the same theme or their
// colors drift apart. Built on re_highlight's atomOneDarkTheme, retuned to
// read closer to a JetBrains (GoLand/Darcula) palette: warm keywords, and
// types/constants as italic cyan instead of atomOneDark's plain orange. Only
// the keys called out below are overridden; every other one of
// atomOneDarkTheme's ~30 scopes (string, title, built_in, number, ...) is
// inherited unchanged, so the other 17 registered languages (see
// syntax.dart's _byId) keep their existing colors.
final ccCodeTheme = <String, TextStyle>{
  ...atomOneDarkTheme,
  // Keywords (const/if/return/func/class/...): warm orange rather than
  // atomOneDark's violet, closer to Darcula's default keyword color.
  'keyword': const TextStyle(color: Color(0xFFCC7832)),
  // Types (Go's string/error/int, Dart's String/int/List/Future/... once
  // patched into their own "type" category — see
  // third_party/re_highlight/lib/languages/dart.dart) and constants/literals
  // (nil/true/false/iota): italic cyan, matching JetBrains' convention of
  // grouping types and constants under the same accent.
  'type': const TextStyle(
    color: Color(0xFF56B6C2),
    fontStyle: FontStyle.italic,
  ),
  'literal': const TextStyle(
    color: Color(0xFF56B6C2),
    fontStyle: FontStyle.italic,
  ),
};
