import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

// MarkdownLiteEditor is a Linear/Notion-flavored "live preview" markdown
// editor for the todo body: the underlying buffer stays a literal markdown
// string (same `body_md` contract as before — no block/Delta model to
// round-trip through, so there's zero risk of silently mutating a todo's
// text), but headings, bold/italic/inline-code spans, blockquotes and list
// markers are restyled in place as you type via a custom
// TextEditingController.buildTextSpan override, and Enter continues/exits
// list items the way Notion does. Not a full block editor (no drag handles,
// no slash menu) — a "lite" WYSIWYG layer over plain markdown text.

final _headingRe = RegExp(r'^(#{1,3})(\s+)(.*)$');
final _quoteRe = RegExp(r'^(>\s?)(.*)$');
final _listItemRe = RegExp(r'^(\s*(?:[-*]|\d+\.)\s+)(.*)$');
// Bold/code/italic. Italic is `*text*` only (not `_text_`) — CommonMark
// itself special-cases intraword `_` emphasis for exactly the reason a lite
// regex can't handle well: it'd match half of every snake_case identifier
// (`foo_bar_baz`) that shows up in a todo body.
final _inlineRe = RegExp(r'(\*\*.+?\*\*)|(`[^`\n]+?`)|(\*[^*\n]+?\*)');

List<InlineSpan> _inlineSpans(String s, TextStyle base) {
  if (s.isEmpty) return [TextSpan(text: s, style: base)];
  final dim = base.copyWith(color: CcColors.subtle);
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in _inlineRe.allMatches(s)) {
    if (m.start > last) spans.add(TextSpan(text: s.substring(last, m.start), style: base));
    final token = m.group(0)!;
    if (m.group(1) != null) {
      // **bold**
      spans.add(TextSpan(text: '**', style: dim));
      spans.add(TextSpan(
          text: token.substring(2, token.length - 2),
          style: base.copyWith(fontWeight: FontWeight.w700, color: CcColors.text)));
      spans.add(TextSpan(text: '**', style: dim));
    } else if (m.group(2) != null) {
      // `code`
      spans.add(TextSpan(text: '`', style: dim));
      spans.add(TextSpan(
          text: token.substring(1, token.length - 1),
          style: base.copyWith(
              fontFamily: CcType.mono,
              fontSize: (base.fontSize ?? 14.5) * 0.92,
              color: CcColors.accentBright)));
      spans.add(TextSpan(text: '`', style: dim));
    } else {
      // *italic*
      final marker = token[0];
      spans.add(TextSpan(text: marker, style: dim));
      spans.add(TextSpan(
          text: token.substring(1, token.length - 1),
          style: base.copyWith(fontStyle: FontStyle.italic, color: CcColors.text)));
      spans.add(TextSpan(text: marker, style: dim));
    }
    last = m.end;
  }
  if (last < s.length) spans.add(TextSpan(text: s.substring(last), style: base));
  return spans;
}

List<InlineSpan> _decorateLine(String line, TextStyle base) {
  final dim = base.copyWith(color: CcColors.subtle);
  final heading = _headingRe.firstMatch(line);
  if (heading != null) {
    final hashes = heading.group(1)!, space = heading.group(2)!, rest = heading.group(3)!;
    final level = hashes.length;
    final size = (base.fontSize ?? 14.5) *
        (level == 1 ? 1.55 : level == 2 ? 1.32 : 1.16);
    final headStyle =
        base.copyWith(fontSize: size, fontWeight: FontWeight.w700, color: CcColors.text);
    return [TextSpan(text: hashes + space, style: dim), ..._inlineSpans(rest, headStyle)];
  }
  final quote = _quoteRe.firstMatch(line);
  if (quote != null) {
    final marker = quote.group(1)!, rest = quote.group(2)!;
    final quoteStyle = base.copyWith(color: CcColors.muted, fontStyle: FontStyle.italic);
    return [TextSpan(text: marker, style: dim), ..._inlineSpans(rest, quoteStyle)];
  }
  final item = _listItemRe.firstMatch(line);
  if (item != null) {
    final marker = item.group(1)!, rest = item.group(2)!;
    final markerStyle = base.copyWith(color: CcColors.accentBright, fontWeight: FontWeight.w700);
    return [TextSpan(text: marker, style: markerStyle), ..._inlineSpans(rest, base)];
  }
  return _inlineSpans(line, base);
}

List<InlineSpan> _decorate(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    spans.addAll(_decorateLine(lines[i], base));
    if (i != lines.length - 1) spans.add(TextSpan(text: '\n', style: base));
  }
  return spans;
}

// MarkdownLiteController is a drop-in TextEditingController: `.text` is
// always the plain markdown string (identical contract to a plain
// TextEditingController), only the painted TextSpan differs.
class MarkdownLiteController extends TextEditingController {
  MarkdownLiteController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    // Mid-IME-composition (e.g. typing Chinese pinyin), fall back to the
    // stock underline-the-composing-range rendering: offset math for a
    // partially-composed syllable is fiddly to keep in sync with the
    // decorator, and the composing window is a few hundred ms anyway — the
    // markdown styling simply resumes once the character commits.
    if (withComposing && value.composing.isValid) {
      return TextSpan(style: base, children: [
        TextSpan(text: value.composing.textBefore(value.text)),
        TextSpan(
            text: value.composing.textInside(value.text),
            style: const TextStyle(decoration: TextDecoration.underline)),
        TextSpan(text: value.composing.textAfter(value.text)),
      ]);
    }
    return TextSpan(style: base, children: _decorate(text, base));
  }
}

// _ListContinuationFormatter makes Enter behave like Notion/Linear inside a
// list: pressing Enter on a "- item" / "1. item" line continues the list
// (carries the marker, auto-increments numbers); pressing Enter on an EMPTY
// list line exits the list (drops the marker instead of continuing it).
// Only fires for a genuine single-Enter keystroke (text grew by exactly one
// inserted '\n') so paste of multi-line text is left untouched.
class _ListContinuationFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final sel = newValue.selection;
    if (!sel.isValid || !sel.isCollapsed) return newValue;
    final pos = sel.baseOffset;
    if (pos <= 0 || pos > newValue.text.length) return newValue;
    if (newValue.text.length != oldValue.text.length + 1) return newValue;
    if (newValue.text[pos - 1] != '\n') return newValue;

    final before = newValue.text.substring(0, pos - 1);
    final lineStart = before.lastIndexOf('\n') + 1;
    final line = before.substring(lineStart);

    final bullet = RegExp(r'^(\s*)([-*])(\s+)(.*)$').firstMatch(line);
    final numbered = RegExp(r'^(\s*)(\d+)\.(\s+)(.*)$').firstMatch(line);
    if (bullet == null && numbered == null) return newValue;

    final content = (bullet ?? numbered)!.group(4)!;
    if (content.trim().isEmpty) {
      // Empty list line + Enter: drop the marker, don't continue the list.
      final newText = newValue.text.substring(0, lineStart) + newValue.text.substring(pos);
      return TextEditingValue(text: newText, selection: TextSelection.collapsed(offset: lineStart));
    }
    final indent = (bullet ?? numbered)!.group(1)!;
    final prefix = bullet != null
        ? '$indent${bullet.group(2)} '
        : '$indent${int.parse(numbered!.group(2)!) + 1}. ';
    final newText = newValue.text.substring(0, pos) + prefix + newValue.text.substring(pos);
    return TextEditingValue(
        text: newText, selection: TextSelection.collapsed(offset: pos + prefix.length));
  }
}

// MarkdownLiteEditor is the borderless TextField wired to a
// MarkdownLiteController — pass it wherever a plain multi-line TextField used
// to hold a todo's body_md.
class MarkdownLiteEditor extends StatefulWidget {
  final MarkdownLiteController controller;
  final FocusNode? focusNode;
  final String? hintText;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;
  final TextStyle? style;

  const MarkdownLiteEditor({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText,
    this.onChanged,
    this.autofocus = false,
    this.minLines,
    this.maxLines,
    this.style,
  });

  @override
  State<MarkdownLiteEditor> createState() => _MarkdownLiteEditorState();
}

class _MarkdownLiteEditorState extends State<MarkdownLiteEditor> {
  void _wrapSelection(String marker) {
    final sel = widget.controller.selection;
    if (!sel.isValid) return;
    final text = widget.controller.text;
    if (sel.isCollapsed) {
      final newText = text.replaceRange(sel.start, sel.start, '$marker$marker');
      widget.controller.value = TextEditingValue(
          text: newText, selection: TextSelection.collapsed(offset: sel.start + marker.length));
      widget.onChanged?.call(newText);
      return;
    }
    final selected = text.substring(sel.start, sel.end);
    final newText = text.replaceRange(sel.start, sel.end, '$marker$selected$marker');
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
          baseOffset: sel.start + marker.length, extentOffset: sel.end + marker.length),
    );
    widget.onChanged?.call(newText);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyB): () => _wrapSelection('**'),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyB): () =>
            _wrapSelection('**'),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyI): () => _wrapSelection('*'),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyI): () =>
            _wrapSelection('*'),
      },
      child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        onChanged: widget.onChanged,
        style: widget.style ??
            const TextStyle(fontSize: 14.5, height: 1.55, color: CcColors.text),
        cursorColor: CcColors.accentBright,
        decoration: InputDecoration(
          isDense: true,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          hintText: widget.hintText,
          hintStyle: const TextStyle(color: CcColors.subtle, fontSize: 14.5),
          contentPadding: EdgeInsets.zero,
        ),
        inputFormatters: [_ListContinuationFormatter()],
      ),
    );
  }
}
