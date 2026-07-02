import 'package:desktop_drop/desktop_drop.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../api/relay_client.dart';
import '../theme.dart';
import '../widgets.dart';
import 'html_to_markdown.dart';
import 'todo_attachment_thumb.dart' show isImageAttachmentName;

// MarkdownLiteEditor is a Linear/Notion-flavored "live preview" markdown
// editor for the todo body: the underlying buffer stays a literal markdown
// string (same `body_md` contract as before — no block/Delta model to
// round-trip through, so there's zero risk of silently mutating a todo's
// text), but headings, bold/italic/inline-code spans, blockquotes and list
// markers are restyled in place as you type via a custom
// TextEditingController.buildTextSpan override, and Enter continues/exits
// list items the way Notion does. Not a full block editor (no drag handles,
// no slash menu) — a "lite" WYSIWYG layer over plain markdown text.
//
// Pasted/dropped images upload via RelayClient.uploadTodoAttachment and get
// inserted as a literal `![](name)` reference at the cursor — same "zero
// transformation" contract as everything else here. todo_body_view.dart is
// the read-only counterpart that turns that reference back into a real
// inline image.
//
// Paste also tries the clipboard's HTML representation (via super_clipboard
// — the `pasteboard` package above can't read `public.html` on macOS at
// all) so copying a formatted snippet from Linear/Notion/a browser keeps
// its headings/bold/links/lists instead of landing as flattened plain text;
// see html_to_markdown.dart and _pasteHtmlIfAvailable below.

final _headingRe = RegExp(r'^(#{1,3})(\s+)(.*)$');
final _quoteRe = RegExp(r'^(>\s?)(.*)$');
final _listItemRe = RegExp(r'^(\s*(?:[-*]|\d+\.)\s+)(.*)$');
// Bold/code/italic. Italic is `*text*` only (not `_text_`) — CommonMark
// itself special-cases intraword `_` emphasis for exactly the reason a lite
// regex can't handle well: it'd match half of every snake_case identifier
// (`foo_bar_baz`) that shows up in a todo body.
final _inlineRe = RegExp(r'(\*\*.+?\*\*)|(`[^`\n]+?`)|(\*[^*\n]+?\*)');

// inlineMarkdownSpans/decorateMarkdownLine are public because
// todo_body_view.dart's read-only renderer reuses them verbatim for the
// non-image lines of a todo body — one regex-driven decorator, two
// presentations (live-editing TextSpan tree here, static Text.rich there).
List<InlineSpan> inlineMarkdownSpans(String s, TextStyle base) {
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

List<InlineSpan> decorateMarkdownLine(String line, TextStyle base) {
  final dim = base.copyWith(color: CcColors.subtle);
  final heading = _headingRe.firstMatch(line);
  if (heading != null) {
    final hashes = heading.group(1)!, space = heading.group(2)!, rest = heading.group(3)!;
    final level = hashes.length;
    final size = (base.fontSize ?? 14.5) *
        (level == 1 ? 1.55 : level == 2 ? 1.32 : 1.16);
    final headStyle =
        base.copyWith(fontSize: size, fontWeight: FontWeight.w700, color: CcColors.text);
    return [TextSpan(text: hashes + space, style: dim), ...inlineMarkdownSpans(rest, headStyle)];
  }
  final quote = _quoteRe.firstMatch(line);
  if (quote != null) {
    final marker = quote.group(1)!, rest = quote.group(2)!;
    final quoteStyle = base.copyWith(color: CcColors.muted, fontStyle: FontStyle.italic);
    return [TextSpan(text: marker, style: dim), ...inlineMarkdownSpans(rest, quoteStyle)];
  }
  final item = _listItemRe.firstMatch(line);
  if (item != null) {
    final marker = item.group(1)!, rest = item.group(2)!;
    final markerStyle = base.copyWith(color: CcColors.accentBright, fontWeight: FontWeight.w700);
    return [TextSpan(text: marker, style: markerStyle), ...inlineMarkdownSpans(rest, base)];
  }
  return inlineMarkdownSpans(line, base);
}

List<InlineSpan> _decorate(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    spans.addAll(decorateMarkdownLine(lines[i], base));
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
  // When both are set, pasting (Cmd/Ctrl+V) or dropping an image file onto
  // this editor uploads it via RelayClient.uploadTodoAttachment and inserts
  // a literal `![](name)` reference at the cursor. Left null wherever there's
  // no todo yet to attach to (e.g. the "new todo" composer) — paste there
  // just falls back to plain text, drop is disabled.
  final RelayClient? client;
  final String? todoId;

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
    this.client,
    this.todoId,
  });

  @override
  State<MarkdownLiteEditor> createState() => _MarkdownLiteEditorState();
}

class _MarkdownLiteEditorState extends State<MarkdownLiteEditor> {
  bool _mediaBusy = false;
  bool _dropHover = false;
  int _pasteSeq = 0;

  bool get _canUploadMedia => widget.client != null && widget.todoId != null;

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

  void _insertAtCursor(String text) {
    final sel = widget.controller.selection;
    final base = widget.controller.text;
    final start = sel.isValid ? sel.start : base.length;
    final end = sel.isValid ? sel.end : base.length;
    final newText = base.replaceRange(start, end, text);
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    widget.onChanged?.call(newText);
  }

  String _pastedImageName() {
    // Pasteboard.image always hands back PNG bytes (it converts via
    // NSImage.png on macOS; other platforms follow the same contract) — the
    // extension is never guessed from content, just fixed.
    final ts = DateTime.now().millisecondsSinceEpoch;
    return 'pasted-$ts-${_pasteSeq++}.png';
  }

  Future<void> _uploadAndInsertImage(Uint8List bytes, String name) async {
    final client = widget.client;
    final todoId = widget.todoId;
    if (client == null || todoId == null) return;
    if (_mediaBusy) {
      if (mounted) snack(context, '已有图片正在上传，请稍候');
      return;
    }
    setState(() => _mediaBusy = true);
    if (mounted) snack(context, '正在上传图片…', duration: const Duration(seconds: 2));
    try {
      await client.uploadTodoAttachment(todoId, name, bytes);
      if (!mounted) return;
      _insertAtCursor('![]($name)');
    } catch (e) {
      if (mounted) snack(context, '图片上传失败: ${errorText(e)}');
    } finally {
      if (mounted) setState(() => _mediaBusy = false);
    }
  }

  // Binding Cmd/Ctrl+V here fully replaces TextField's own paste handling
  // (CallbackShortcuts marks the key event handled either way), so the
  // plain-text fallback below has to be reimplemented rather than left to
  // fall through to the default — only reached once an image paste has
  // already been ruled out.
  Future<void> _handlePaste() async {
    Uint8List? image;
    try {
      image = await Pasteboard.image;
    } catch (_) {
      image = null;
    }
    if (image != null && image.isNotEmpty) {
      await _uploadAndInsertImage(image, _pastedImageName());
      return;
    }
    if (await _pasteHtmlIfAvailable()) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) _insertAtCursor(text);
  }

  // Tries the clipboard's HTML representation and converts it through
  // htmlToMarkdown; remote (http/https) <img> sources are downloaded and
  // routed through the same _uploadAndInsertImage pipeline a direct image
  // paste uses (in source order, appended after the converted text — exact
  // inline position isn't preserved, which is an acceptable simplification
  // for the todo/Linear/Notion/browser snippets this targets). Returns
  // false (having inserted nothing) whenever there's no HTML on the
  // clipboard, the reader errors, or conversion finds nothing usable, so
  // the caller can fall back to the pre-existing plain-text paste — this
  // can only add capability, never regress a paste that used to work.
  Future<bool> _pasteHtmlIfAvailable() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return false;

    String? html;
    try {
      final reader = await clipboard.read();
      if (!reader.canProvide(Formats.htmlText)) return false;
      html = await reader.readValue(Formats.htmlText);
    } catch (_) {
      return false;
    }
    if (html == null || html.trim().isEmpty) return false;

    final HtmlToMarkdownResult result;
    try {
      result = htmlToMarkdown(html);
    } catch (_) {
      return false;
    }
    if (result.isEmpty) return false;

    final text = _stripImagePlaceholders(result.markdown, result.imageSrcs.length);
    var handled = text.isNotEmpty;
    if (text.isNotEmpty) _insertAtCursor(text);

    for (final src in result.imageSrcs) {
      if (!src.startsWith('http://') && !src.startsWith('https://')) continue;
      final bytes = await _downloadRemoteImage(src);
      if (bytes == null || bytes.isEmpty) continue;
      await _uploadAndInsertImage(bytes, _remoteImageName(src));
      handled = true;
    }
    return handled;
  }

  String _stripImagePlaceholders(String markdown, int imageCount) {
    var out = markdown;
    for (var i = 0; i < imageCount; i++) {
      out = out.replaceFirst(imgPlaceholder(i), '');
    }
    return out.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  Future<Uint8List?> _downloadRemoteImage(String url) async {
    try {
      final response = await Dio()
          .get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
      final data = response.data;
      if (data == null || data.isEmpty) return null;
      return data is Uint8List ? data : Uint8List.fromList(data);
    } catch (_) {
      return null;
    }
  }

  // Downloaded bytes could be any format the source serves (jpg/gif/webp/…)
  // unlike Pasteboard.image's fixed PNG contract, so the extension is
  // sniffed from the URL path when it's a recognized image extension and
  // falls back to .png otherwise.
  String _remoteImageName(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final dot = path.lastIndexOf('.');
    final ext = dot >= 0 && isImageAttachmentName(path.substring(dot))
        ? path.substring(dot).toLowerCase()
        : '.png';
    final ts = DateTime.now().millisecondsSinceEpoch;
    return 'pasted-$ts-${_pasteSeq++}$ext';
  }

  Future<void> _handleDrop(DropDoneDetails detail) async {
    final images = detail.files.where((f) => isImageAttachmentName(f.name)).toList();
    final skipped = detail.files.length - images.length;
    for (final f in images) {
      try {
        final bytes = await f.readAsBytes();
        await _uploadAndInsertImage(bytes, f.name);
      } catch (e) {
        if (mounted) snack(context, '${f.name} 上传失败: ${errorText(e)}');
      }
    }
    if (skipped > 0 && mounted) {
      snack(context, '正文只能内嵌图片，已跳过 $skipped 个非图片文件');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bindings = <ShortcutActivator, VoidCallback>{
      LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyB): () => _wrapSelection('**'),
      LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyB): () =>
          _wrapSelection('**'),
      LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyI): () => _wrapSelection('*'),
      LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyI): () =>
          _wrapSelection('*'),
      if (_canUploadMedia) ...{
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyV): () => _handlePaste(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyV): () => _handlePaste(),
      },
    };

    Widget field = CallbackShortcuts(
      bindings: bindings,
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

    if (!_canUploadMedia) return field;

    return DropTarget(
      onDragEntered: (_) => setState(() => _dropHover = true),
      onDragExited: (_) => setState(() => _dropHover = false),
      onDragDone: (detail) {
        setState(() => _dropHover = false);
        _handleDrop(detail);
      },
      child: DecoratedBox(
        decoration: _dropHover
            ? BoxDecoration(
                color: CcColors.accent.withValues(alpha: 0.08),
                border: Border.all(color: CcColors.accent, width: 1),
                borderRadius: BorderRadius.circular(CcRadius.sm),
              )
            : const BoxDecoration(),
        child: field,
      ),
    );
  }
}
