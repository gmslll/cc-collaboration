import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/relay_client.dart';
import '../api/todo_models.dart';
import '../theme.dart';
import 'markdown_lite_editor.dart' show decorateMarkdownLine;
import 'todo_attachment_thumb.dart' show fetchTodoAttachmentBytes;

// Matches the `![alt](name)` references MarkdownLiteEditor's paste/drop
// upload flow writes into body_md — same shape as CommonMark image syntax,
// but `name` is always a bare todo-attachment name, and the reference must
// be the entire (trimmed) line to count as an image: a mid-sentence
// `text ![](x) more text` renders as literal decorated text, not an image.
// That's a deliberate "lite" simplification (block-level image refs, like
// Linear/Notion, not true inline-within-paragraph CommonMark images) — it
// keeps text runs and images as separate widgets in the Column below instead
// of needing WidgetSpan-in-TextSpan plumbing.
final _imageLineRe = RegExp(r'^!\[([^\]]*)\]\(([^)]+)\)$');

double todoInlineImageMaxHeight(
  Size screenSize, {
  double preferred = 360,
  double minHeight = 160,
  double maxFraction = 0.48,
}) {
  final height = screenSize.height;
  if (!height.isFinite || height <= 0) return preferred;
  final capped = height * maxFraction.clamp(0, 1);
  if (capped >= preferred) return preferred;
  return capped < minHeight ? minHeight : capped;
}

// TodoBodyView is the read-only counterpart to MarkdownLiteEditor: same
// body_md literal-markdown-string contract, same decorateMarkdownLine/
// inlineMarkdownSpans styling for text lines, but a line that's exactly
// `![alt](name)` renders as a real inline image instead of literal text.
// body_md itself never changes shape for this — no Delta/AST conversion,
// just an alternate presentation of the same string. Non-image lines are
// grouped into contiguous SelectableText.rich blocks; each image gets its
// own widget in the Column, so one broken image never blocks the rest of
// the body from rendering.
class TodoBodyView extends StatelessWidget {
  final RelayClient client;
  final String todoId;
  final String bodyMd;
  final List<TodoAttachment> attachments;
  final TextStyle? style;

  const TodoBodyView({
    super.key,
    required this.client,
    required this.todoId,
    required this.bodyMd,
    required this.attachments,
    this.style,
  });

  TodoAttachment? _byName(String name) {
    for (final a in attachments) {
      if (a.name == name) return a;
    }
    // TRANSITIONAL — safe to delete once every Linear import rewrites body refs
    // at import time (rewriteImageRefs in internal/linear/import.go) and a final
    // backfill has run; until then this is the only net for a body imported by
    // an older relay binary. Older imports kept the original uploads.linear.app
    // URL as the ref while storing the image as an attachment named after the
    // URL's last path segment (+ a content-type extension), so resolve those by
    // matching that segment against attachment names — exact, or by stem when an
    // extension was appended.
    final base = _urlLastSegment(name);
    if (base != null) {
      for (final a in attachments) {
        if (a.name == base) return a;
        final dot = a.name.lastIndexOf('.');
        if (dot > 0 && a.name.substring(0, dot) == base) return a;
      }
    }
    return null;
  }

  // Last path segment of an http(s) URL, percent-decoded (matching Go's
  // url.URL.Path, which is how the importer derives the attachment name).
  // Returns null for anything without a scheme — a bare attachment name falls
  // through to exact match only, so this never shadows a real attachment.
  static String? _urlLastSegment(String ref) {
    final uri = Uri.tryParse(ref);
    if (uri == null || !uri.hasScheme) return null;
    final segs = uri.pathSegments;
    return segs.isEmpty || segs.last.isEmpty ? null : segs.last;
  }

  List<InlineSpan> _decorateBlock(List<String> lines, TextStyle base) {
    final spans = <InlineSpan>[];
    for (var i = 0; i < lines.length; i++) {
      spans.addAll(decorateMarkdownLine(lines[i], base, hideMarkers: true));
      if (i != lines.length - 1) spans.add(TextSpan(text: '\n', style: base));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final base =
        style ??
        const TextStyle(fontSize: 14.5, height: 1.55, color: CcColors.text);
    if (bodyMd.trim().isEmpty) {
      return Text('添加描述…', style: base.copyWith(color: CcColors.subtle));
    }

    final children = <Widget>[];
    var block = <String>[];
    void flushBlock() {
      if (block.isEmpty) return;
      children.add(
        SelectableText.rich(TextSpan(children: _decorateBlock(block, base))),
      );
      block = [];
    }

    for (final line in bodyMd.split('\n')) {
      final m = _imageLineRe.firstMatch(line.trim());
      if (m == null) {
        block.add(line);
        continue;
      }
      flushBlock();
      final name = m.group(2)!;
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: _InlineImage(
            client: client,
            todoId: todoId,
            name: name,
            alt: m.group(1)!,
            attachment: _byName(name),
          ),
        ),
      );
    }
    flushBlock();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

class _InlineImage extends StatefulWidget {
  final RelayClient client;
  final String todoId;
  final String name;
  final String alt;
  // Metadata for this attachment from the todo's `attachments` list, when
  // available — carries the sha256 the shared thumb cache keys on. May be
  // null right after a paste/drop upload if body_md was saved (and this view
  // rebuilt) before the next full-todo reload backfilled `attachments`; the
  // fetch below just skips the cache in that case rather than failing.
  final TodoAttachment? attachment;

  const _InlineImage({
    required this.client,
    required this.todoId,
    required this.name,
    required this.alt,
    required this.attachment,
  });

  @override
  State<_InlineImage> createState() => _InlineImageState();
}

class _InlineImageState extends State<_InlineImage> {
  Uint8List? _bytes;
  bool _failed = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_InlineImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.client, widget.client) ||
        oldWidget.todoId != widget.todoId ||
        oldWidget.name != widget.name ||
        oldWidget.attachment?.sha256 != widget.attachment?.sha256) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  bool _isCurrentImage(
    RelayClient client,
    String todoId,
    String name,
    TodoAttachment? attachment,
  ) =>
      mounted &&
      identical(client, widget.client) &&
      todoId == widget.todoId &&
      name == widget.name &&
      attachment?.name == widget.attachment?.name &&
      attachment?.sha256 == widget.attachment?.sha256;

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final client = widget.client;
    final todoId = widget.todoId;
    final name = widget.name;
    final attachment = widget.attachment;
    setState(() => _failed = false);
    try {
      final Uint8List bytes;
      if (attachment != null) {
        bytes = await fetchTodoAttachmentBytes(client, todoId, attachment);
      } else {
        final data = await client.todoAttachment(todoId, name);
        bytes = data is Uint8List ? data : Uint8List.fromList(data);
      }
      if (generation != _loadGeneration ||
          !_isCurrentImage(client, todoId, name, attachment)) {
        return;
      }
      setState(() => _bytes = bytes);
    } catch (_) {
      if (generation != _loadGeneration ||
          !_isCurrentImage(client, todoId, name, attachment)) {
        return;
      }
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(CcRadius.md),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: todoInlineImageMaxHeight(MediaQuery.sizeOf(context)),
              maxWidth: 520,
            ),
            child: Image.memory(
              _bytes!,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => _statusBox(broken: true),
            ),
          ),
        ),
      );
    }
    if (_failed) return _statusBox(broken: true);
    return _statusBox(broken: false);
  }

  Widget _statusBox({required bool broken}) => GestureDetector(
    onTap: broken ? _load : null,
    child: Container(
      width: 200,
      height: 100,
      decoration: BoxDecoration(
        color: CcColors.panelHigh,
        border: Border.all(color: CcColors.border),
        borderRadius: BorderRadius.circular(CcRadius.md),
      ),
      child: Center(
        child: broken
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.broken_image_rounded,
                    size: 16,
                    color: CcColors.danger,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      widget.alt.isEmpty ? widget.name : widget.alt,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: CcColors.subtle,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              )
            : const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
      ),
    ),
  );
}
