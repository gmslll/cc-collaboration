import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../api/relay_client.dart';
import '../api/todo_models.dart';
import '../theme.dart';
import '../widgets.dart';

const _imageExts = {
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.bmp',
  '.heic',
};

bool isImageAttachmentName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return _imageExts.contains(name.substring(dot).toLowerCase());
}

// Process-wide decoded-bytes cache keyed by sha256 (not name+id) so identical
// content is only ever fetched once per app run, even across different todos
// or a re-uploaded attachment under a new name. Bounded because this is a
// personal-productivity-tool scale cache, not a real image pipeline — no need
// for a proper LRU package.
class _ThumbCache {
  static final Map<String, Uint8List> _bytes = {};
  static const _cap = 80;

  static Uint8List? get(String sha256) => _bytes[sha256];

  static void put(String sha256, Uint8List data) {
    if (!_bytes.containsKey(sha256) && _bytes.length >= _cap) {
      _bytes.remove(_bytes.keys.first);
    }
    _bytes[sha256] = data;
  }
}

// TodoAttachmentThumb renders one attachment for a todo's list row / detail
// attachments tab. The relay's attachment endpoint needs `Authorization:
// Bearer`, so a bare Image.network(url) can't work — bytes always go through
// RelayClient.todoAttachment() first, then Image.memory. Non-image
// attachments keep the existing handoff-attachment UX: download to a temp
// file + OpenFilex.open().
class TodoAttachmentThumb extends StatefulWidget {
  final RelayClient client;
  final String todoId;
  final TodoAttachment attachment;
  final double size;

  const TodoAttachmentThumb({
    super.key,
    required this.client,
    required this.todoId,
    required this.attachment,
    this.size = 40,
  });

  @override
  State<TodoAttachmentThumb> createState() => _TodoAttachmentThumbState();
}

class _TodoAttachmentThumbState extends State<TodoAttachmentThumb> {
  Uint8List? _bytes;
  bool _loading = false;
  bool _failed = false;

  bool get _isImage => isImageAttachmentName(widget.attachment.name);

  @override
  void initState() {
    super.initState();
    if (_isImage) _load();
  }

  @override
  void didUpdateWidget(TodoAttachmentThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isImage && oldWidget.attachment.sha256 != widget.attachment.sha256) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<Uint8List> _fetch() async {
    final data = await widget.client.todoAttachment(
        widget.todoId, widget.attachment.name);
    return data is Uint8List ? data : Uint8List.fromList(data);
  }

  Future<void> _load() async {
    final cached = _ThumbCache.get(widget.attachment.sha256);
    if (cached != null) {
      setState(() => _bytes = cached);
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final bytes = await _fetch();
      _ThumbCache.put(widget.attachment.sha256, bytes);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _downloadAndOpen() async {
    try {
      final bytes = await _fetch();
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${widget.attachment.name}');
      await file.writeAsBytes(bytes);
      final res = await OpenFilex.open(file.path);
      if (res.type != ResultType.done && mounted) {
        snack(context, '已保存到 ${file.path}');
      }
    } catch (e) {
      if (mounted) snack(context, '附件失败: ${errorText(e)}');
    }
  }

  void _openPreview() {
    final bytes = _bytes;
    if (bytes == null) return;
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        backgroundColor: Colors.transparent,
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            InteractiveViewer(
              maxScale: 6,
              child: Image.memory(bytes),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _box({required Widget child, VoidCallback? onTap}) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: widget.size,
      height: widget.size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: CcColors.panelHigh,
        border: Border.all(color: CcColors.border),
        borderRadius: BorderRadius.circular(CcRadius.sm),
      ),
      child: Center(child: child),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_isImage) {
      return _box(
        onTap: _downloadAndOpen,
        child: Icon(Icons.insert_drive_file_rounded,
            size: widget.size * 0.5, color: CcColors.muted),
      );
    }
    if (_bytes != null) {
      return _box(
        onTap: _openPreview,
        child: Image.memory(_bytes!,
            fit: BoxFit.cover, width: widget.size, height: widget.size),
      );
    }
    if (_failed) {
      return _box(
        onTap: _load,
        child: Icon(Icons.broken_image_rounded,
            size: widget.size * 0.5, color: CcColors.danger),
      );
    }
    return _box(
      child: SizedBox(
        width: widget.size * 0.4,
        height: widget.size * 0.4,
        child: _loading
            ? const CircularProgressIndicator(strokeWidth: 2)
            : const SizedBox(),
      ),
    );
  }
}
