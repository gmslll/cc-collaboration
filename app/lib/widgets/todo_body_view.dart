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
    return null;
  }

  List<InlineSpan> _decorateBlock(List<String> lines, TextStyle base) {
    final spans = <InlineSpan>[];
    for (var i = 0; i < lines.length; i++) {
      spans.addAll(decorateMarkdownLine(lines[i], base));
      if (i != lines.length - 1) spans.add(TextSpan(text: '\n', style: base));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final base =
        style ?? const TextStyle(fontSize: 14.5, height: 1.55, color: CcColors.text);
    if (bodyMd.trim().isEmpty) {
      return Text('添加描述…', style: base.copyWith(color: CcColors.subtle));
    }

    final children = <Widget>[];
    var block = <String>[];
    void flushBlock() {
      if (block.isEmpty) return;
      children.add(SelectableText.rich(TextSpan(children: _decorateBlock(block, base))));
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
      children.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _InlineImage(
          client: client,
          todoId: todoId,
          name: name,
          alt: m.group(1)!,
          attachment: _byName(name),
        ),
      ));
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_InlineImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name ||
        oldWidget.attachment?.sha256 != widget.attachment?.sha256) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final att = widget.attachment;
      final Uint8List bytes;
      if (att != null) {
        bytes = await fetchTodoAttachmentBytes(widget.client, widget.todoId, att);
      } else {
        final data = await widget.client.todoAttachment(widget.todoId, widget.name);
        bytes = data is Uint8List ? data : Uint8List.fromList(data);
      }
      if (!mounted) return;
      setState(() => _bytes = bytes);
    } catch (_) {
      if (!mounted) return;
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
            constraints: const BoxConstraints(maxHeight: 360, maxWidth: 520),
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
                      const Icon(Icons.broken_image_rounded,
                          size: 16, color: CcColors.danger),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          widget.alt.isEmpty ? widget.name : widget.alt,
                          style: const TextStyle(fontSize: 11.5, color: CcColors.subtle),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  )
                : const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        ),
      );
}
