import 'dart:io';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets.dart';
import 'editor_page.dart';

// dirs/files never worth browsing — skipped in the file tree.
const _ignore = {
  '.git',
  'node_modules',
  'build',
  '.dart_tool',
  '.idea',
  'dist',
  'vendor',
  'target',
  '.gradle',
  'Pods',
  '.next',
  '__pycache__',
  '.venv',
  '.DS_Store',
};

// FileBrowserPage is a lazy file tree of a project root; tapping a file opens it
// in the editor. Each directory lists its children on first expand.
class FileBrowserPage extends StatelessWidget {
  final String root;
  final String name;
  const FileBrowserPage({super.key, required this.root, required this.name});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('文件 · $name')),
      body: DecoratedBox(
        decoration: appGradient,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 4),
          children: [
            FileTree(
              root: root,
              label: name,
              onOpenFile: (path) => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => EditorPage(path: path))),
            ),
          ],
        ),
      ),
    );
  }
}

class FileTree extends StatelessWidget {
  final String root;
  final String label;
  final ValueChanged<String> onOpenFile;
  final String? selectedPath;
  final Widget Function(String path)? fileMenuBuilder;
  final Widget Function(String path)? pathStatusBuilder;
  const FileTree({
    super.key,
    required this.root,
    required this.label,
    required this.onOpenFile,
    this.selectedPath,
    this.fileMenuBuilder,
    this.pathStatusBuilder,
  });

  @override
  Widget build(BuildContext context) => DirTile(
    dir: root,
    label: label,
    depth: 0,
    initiallyExpanded: true,
    onOpenFile: onOpenFile,
    selectedPath: selectedPath,
    fileMenuBuilder: fileMenuBuilder,
    pathStatusBuilder: pathStatusBuilder,
  );
}

class DirTile extends StatefulWidget {
  final String dir;
  final String label;
  final int depth;
  final bool initiallyExpanded;
  final ValueChanged<String> onOpenFile;
  final String? selectedPath;
  final Widget Function(String path)? fileMenuBuilder;
  final Widget Function(String path)? pathStatusBuilder;
  const DirTile({
    super.key,
    required this.dir,
    required this.label,
    required this.depth,
    required this.onOpenFile,
    this.initiallyExpanded = false,
    this.selectedPath,
    this.fileMenuBuilder,
    this.pathStatusBuilder,
  });

  @override
  State<DirTile> createState() => _DirTileState();
}

class _DirTileState extends State<DirTile> {
  List<FileSystemEntity>? _children; // null = not loaded yet
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.initiallyExpanded || _containsSelectedPath) _loadChildren();
  }

  @override
  void didUpdateWidget(DirTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedPath != widget.selectedPath &&
        _containsSelectedPath) {
      _loadChildren();
    }
  }

  bool get _containsSelectedPath {
    final selected = widget.selectedPath;
    if (selected == null || selected.isEmpty) return false;
    return selected == widget.dir || selected.startsWith('${widget.dir}/');
  }

  Future<void> _loadChildren() async {
    if (_children != null || _loading) return;
    setState(() => _loading = true);
    final entries = <FileSystemEntity>[];
    try {
      await for (final e in Directory(widget.dir).list(followLinks: false)) {
        if (!_ignore.contains(e.path.split('/').last)) entries.add(e);
      }
    } catch (_) {}
    entries.sort((a, b) {
      final ad = a is Directory, bd = b is Directory;
      if (ad != bd) return ad ? -1 : 1; // directories first
      return a.path
          .split('/')
          .last
          .toLowerCase()
          .compareTo(b.path.split('/').last.toLowerCase());
    });
    if (mounted) {
      setState(() {
        _children = entries;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedInDir = _containsSelectedPath;
    final selected = widget.selectedPath == widget.dir;
    final ancestor = selectedInDir && !selected;
    return Container(
      decoration: BoxDecoration(
        color: selected
            ? CcColors.accent.withValues(alpha: 0.10)
            : Colors.transparent,
        border: Border(
          left: BorderSide(
            color: selected ? CcColors.accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: ExpansionTile(
        key: PageStorageKey('fb-${widget.dir}'),
        initiallyExpanded: widget.initiallyExpanded || selectedInDir,
        onExpansionChanged: (open) {
          if (open) _loadChildren();
        },
        dense: true,
        visualDensity: const VisualDensity(vertical: -2),
        tilePadding: EdgeInsets.only(left: 8.0 + widget.depth * 12, right: 8),
        childrenPadding: EdgeInsets.zero,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(
          Icons.folder_rounded,
          size: 16,
          color: selected
              ? CcColors.accentBright
              : ancestor
              ? CcColors.muted
              : CcColors.subtle,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                widget.label,
                style: TextStyle(
                  fontFamily: CcType.mono,
                  fontSize: 12.5,
                  color: selected ? CcColors.text : null,
                  fontWeight: selected || ancestor
                      ? FontWeight.w700
                      : FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (widget.pathStatusBuilder != null) ...[
              const SizedBox(width: 6),
              widget.pathStatusBuilder!(widget.dir),
            ],
          ],
        ),
        children: _childWidgets(),
      ),
    );
  }

  List<Widget> _childWidgets() {
    if (_children == null) {
      return [
        Padding(
          padding: EdgeInsets.only(
            left: 12.0 + widget.depth * 12,
            top: 2,
            bottom: 4,
          ),
          child: _loading
              ? const SizedBox(
                  width: 80,
                  height: 2,
                  child: LinearProgressIndicator(),
                )
              : const SizedBox.shrink(),
        ),
      ];
    }
    final d = widget.depth + 1;
    return [
      for (final e in _children!)
        if (e is Directory)
          DirTile(
            dir: e.path,
            label: e.path.split('/').last,
            depth: d,
            onOpenFile: widget.onOpenFile,
            selectedPath: widget.selectedPath,
            fileMenuBuilder: widget.fileMenuBuilder,
            pathStatusBuilder: widget.pathStatusBuilder,
          )
        else
          _fileTile(e.path, e.path.split('/').last, d),
    ];
  }

  Widget _fileTile(String path, String name, int depth) {
    final selected = path == widget.selectedPath;
    return Container(
      decoration: BoxDecoration(
        color: selected
            ? CcColors.accent.withValues(alpha: 0.10)
            : Colors.transparent,
        border: Border(
          left: BorderSide(
            color: selected ? CcColors.accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: ListTile(
        dense: true,
        selected: selected,
        visualDensity: const VisualDensity(vertical: -2),
        contentPadding: EdgeInsets.only(left: 12.0 + depth * 12, right: 8),
        horizontalTitleGap: 6,
        leading: Icon(
          Icons.description_rounded,
          size: 15,
          color: selected ? CcColors.accentBright : CcColors.subtle,
        ),
        title: Text(
          name,
          style: TextStyle(
            fontFamily: CcType.mono,
            fontSize: 12.5,
            color: selected ? CcColors.text : null,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing:
            widget.pathStatusBuilder == null && widget.fileMenuBuilder == null
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.pathStatusBuilder != null)
                    widget.pathStatusBuilder!(path),
                  if (widget.pathStatusBuilder != null &&
                      widget.fileMenuBuilder != null)
                    const SizedBox(width: 2),
                  if (widget.fileMenuBuilder != null)
                    widget.fileMenuBuilder!(path),
                ],
              ),
        onTap: () => widget.onOpenFile(path),
      ),
    );
  }
}
