import 'package:flutter/painting.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

import 'editor_theme.dart';
import 'local/word_diff.dart';

// Shared syntax-highlighting for the code editor and the diff viewers. Languages
// are registered once into a single Highlight; the diff renderers highlight
// line-by-line (memoized) — see highlightLine.

final Map<String, Mode> _byId = {
  'dart': langDart,
  'go': langGo,
  'typescript': langTypescript,
  'javascript': langJavascript,
  'python': langPython,
  'json': langJson,
  'yaml': langYaml,
  'markdown': langMarkdown,
  'bash': langBash,
  'xml': langXml,
  'css': langCss,
  'java': langJava,
  'kotlin': langKotlin,
  'rust': langRust,
  'cpp': langCpp,
  'sql': langSql,
  'ruby': langRuby,
  'php': langPhp,
  'ini': langIni,
};

final Highlight _hl = Highlight()..registerLanguages(_byId);

// langIdForPath maps a file extension to a registered language id (null = none).
String? langIdForPath(String path) =>
    switch (path.split('.').last.toLowerCase()) {
      'dart' => 'dart',
      'go' => 'go',
      'ts' || 'tsx' => 'typescript',
      'js' || 'jsx' || 'mjs' => 'javascript',
      'py' => 'python',
      'json' => 'json',
      'yaml' || 'yml' => 'yaml',
      'md' || 'markdown' => 'markdown',
      'sh' || 'bash' || 'zsh' => 'bash',
      'xml' || 'html' || 'htm' => 'xml',
      'css' => 'css',
      'java' => 'java',
      'kt' || 'kts' => 'kotlin',
      'rs' => 'rust',
      'c' || 'cc' || 'cpp' || 'cxx' || 'h' || 'hpp' => 'cpp',
      'sql' => 'sql',
      'rb' => 'ruby',
      'php' => 'php',
      'toml' || 'ini' || 'cfg' || 'conf' || 'properties' => 'ini',
      _ => null,
    };

// modeForPath returns the re_highlight Mode for a path (for the re_editor theme).
Mode? modeForPath(String path) {
  final id = langIdForPath(path);
  return id == null ? null : _byId[id];
}

final Map<String, TextSpan?> _spanCache = {};

// highlightLine returns a syntax-highlighted TextSpan for one line of [code] in
// language [langId], or null to fall back to a plain Text (unknown language,
// blank line, or a highlighter error). Token colors come from ccCodeTheme
// rendered over [base] (no background, so a diff cell's +/- tint shows through).
// Memoized by (langId, line) so per-frame rebuilds don't re-tokenize.
TextSpan? highlightLine(String code, String? langId, {required TextStyle base}) {
  if (langId == null || code.trim().isEmpty) return null;
  final key = '$langId $code';
  final hit = _spanCache[key];
  if (hit != null || _spanCache.containsKey(key)) return hit;
  TextSpan? span;
  try {
    final result = _hl.highlight(
      code: code,
      language: langId,
      ignoreIllegals: true,
    );
    final renderer = TextSpanRenderer(base, ccCodeTheme);
    result.render(renderer);
    span = renderer.span;
  } catch (_) {
    span = null;
  }
  if (_spanCache.length > 4000) _spanCache.clear();
  _spanCache[key] = span;
  return span;
}

// applyDiffBackground overlays per-word diff highlighting onto one already
// syntax-highlighted line: it keeps every token's foreground color and only
// paints a [diffBg] background behind the character ranges that [wordSpans]
// marks as changed (GoLand's "Highlight words"). [line] is the exact text the
// spans and [syntaxSpan] describe (post-expandLeadingTabs); [base] is the cell
// style used when a stretch has no syntax color.
//
// Fast path: with no word spans — the vast majority of lines — it returns
// [syntaxSpan] unchanged (reference-identical), so every diffCell call site can
// invoke it unconditionally at zero cost. An empty line likewise passes through.
TextSpan? applyDiffBackground(
  String line,
  TextSpan? syntaxSpan, {
  required TextStyle base,
  List<WordDiffSpan>? wordSpans,
  Color? diffBg,
}) {
  if (wordSpans == null || wordSpans.isEmpty || line.isEmpty) return syntaxSpan;

  // Flatten the (possibly nested) syntax tree into contiguous styled runs. With
  // no syntax span (unknown language / highlighter miss), the whole line is one
  // base-styled run so it still gets the diff background.
  final runs = <(String, TextStyle)>[];
  if (syntaxSpan == null) {
    runs.add((line, base));
  } else {
    _flattenSpan(syntaxSpan, base, runs);
  }

  final ranges = [
    for (final w in wordSpans)
      (start: w.start, end: w.end, bg: w.kind == WordDiffKind.diff ? diffBg : null),
  ];
  return TextSpan(style: base, children: _overlayRanges(line, base, runs, ranges));
}

// _overlayRanges is the general "keep each run's own style, overlay a
// background over specific sub-ranges" merge: two independent boundary
// systems — [runs] (styled text runs) and [ranges] (background overlays) —
// each covering [0, line.length) with no gaps, combined into one flat span
// list at their shared finest-grained partition. applyDiffBackground is the
// only caller today (mapping WordDiffSpan into this range shape), but the
// sweep itself carries no word-diff-specific assumption, so a second overlay
// concern (e.g. search-hit highlighting) can reuse it directly.
List<TextSpan> _overlayRanges(
  String line,
  TextStyle base,
  List<(String, TextStyle)> runs,
  List<({int start, int end, Color? bg})> ranges,
) {
  final runEnds = List<int>.filled(runs.length, 0);
  var acc = 0;
  for (var k = 0; k < runs.length; k++) {
    acc += runs[k].$1.length;
    runEnds[k] = acc;
  }
  final out = <TextSpan>[];
  var runIdx = 0, rangeIdx = 0, cursor = 0;
  while (cursor < line.length) {
    while (runIdx < runs.length && runEnds[runIdx] <= cursor) {
      runIdx++;
    }
    while (rangeIdx < ranges.length && ranges[rangeIdx].end <= cursor) {
      rangeIdx++;
    }
    final runEnd = runIdx < runs.length ? runEnds[runIdx] : line.length;
    final runStyle = runIdx < runs.length ? runs[runIdx].$2 : base;
    final rangeEnd = rangeIdx < ranges.length ? ranges[rangeIdx].end : line.length;
    final bg = rangeIdx < ranges.length ? ranges[rangeIdx].bg : null;
    var segEnd = runEnd < rangeEnd ? runEnd : rangeEnd;
    if (segEnd > line.length) segEnd = line.length;
    if (segEnd <= cursor) break; // safety: guarantee forward progress
    final style = bg == null ? runStyle : runStyle.copyWith(backgroundColor: bg);
    out.add(TextSpan(text: line.substring(cursor, segEnd), style: style));
    cursor = segEnd;
  }
  return out;
}

// _flattenSpan walks a highlightLine span tree depth-first into a flat list of
// (text, effectiveStyle) runs. Matching re_highlight's _TextSpanRenderer, only
// leaf text nodes carry a token color; container nodes just re-assert [base].
// Each child inherits its parent's effective style (child fields win on merge).
void _flattenSpan(
  InlineSpan span,
  TextStyle inherited,
  List<(String, TextStyle)> out,
) {
  if (span is! TextSpan) return; // no WidgetSpans from highlightLine
  final effective =
      span.style == null ? inherited : inherited.merge(span.style);
  final text = span.text;
  if (text != null && text.isNotEmpty) out.add((text, effective));
  final children = span.children;
  if (children != null) {
    for (final child in children) {
      _flattenSpan(child, effective, out);
    }
  }
}

// Default display width of one TAB, matching VS Code's default.
const int kCodeTabWidth = 4;

// expandLeadingTabs replaces each leading TAB on every line with [width] spaces so
// tab-indented code (Go, Makefiles) shows real indentation. dart:ui's paragraph
// engine renders a raw \t at zero width, so both re_editor and the Text-based diff
// viewers otherwise collapse tab indentation to column 0. Only *leading* tabs are
// expanded — rare in-line alignment tabs are left untouched (keeps the save-side
// round-trip in collapseLeadingIndent unambiguous).
String expandLeadingTabs(String s, {int width = kCodeTabWidth}) {
  if (!s.contains('\t')) return s;
  final spaces = ' ' * width;
  final lines = s.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    var t = 0;
    while (t < line.length && line.codeUnitAt(t) == 0x09) {
      t++;
    }
    if (t > 0) lines[i] = (spaces * t) + line.substring(t);
  }
  return lines.join('\n');
}

// collapseLeadingIndent is the inverse of expandLeadingTabs for the save path:
// every group of [width] leading spaces becomes one TAB (remainder kept as spaces),
// so a file that was tab-indented on disk keeps its indentation style after edit.
String collapseLeadingIndent(String s, {int width = kCodeTabWidth}) {
  final lines = s.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    var sp = 0;
    while (sp < line.length && line.codeUnitAt(sp) == 0x20) {
      sp++;
    }
    if (sp >= width) {
      lines[i] = ('\t' * (sp ~/ width)) + (' ' * (sp % width)) + line.substring(sp);
    }
  }
  return lines.join('\n');
}
