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
  const FileTree({
    super.key,
    required this.root,
    required this.label,
    required this.onOpenFile,
  });

  @override
  Widget build(BuildContext context) => DirTile(
    dir: root,
    label: label,
    depth: 0,
    initiallyExpanded: true,
    onOpenFile: onOpenFile,
  );
}

class DirTile extends StatefulWidget {
  final String dir;
  final String label;
  final int depth;
  final bool initiallyExpanded;
  final ValueChanged<String> onOpenFile;
  const DirTile({
    super.key,
    required this.dir,
    required this.label,
    required this.depth,
    required this.onOpenFile,
    this.initiallyExpanded = false,
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
    if (widget.initiallyExpanded) _loadChildren();
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
    return ExpansionTile(
      key: PageStorageKey('fb-${widget.dir}'),
      initiallyExpanded: widget.initiallyExpanded,
      onExpansionChanged: (open) {
        if (open) _loadChildren();
      },
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      tilePadding: EdgeInsets.only(left: 8.0 + widget.depth * 12, right: 8),
      childrenPadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      leading: const Icon(
        Icons.folder_rounded,
        size: 16,
        color: CcColors.muted,
      ),
      title: Text(
        widget.label,
        style: const TextStyle(fontFamily: CcType.mono, fontSize: 12.5),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      children: _childWidgets(),
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
          )
        else
          _fileTile(e.path, e.path.split('/').last, d),
    ];
  }

  Widget _fileTile(String path, String name, int depth) => ListTile(
    dense: true,
    visualDensity: const VisualDensity(vertical: -2),
    contentPadding: EdgeInsets.only(left: 12.0 + depth * 12, right: 8),
    horizontalTitleGap: 6,
    leading: const Icon(
      Icons.description_rounded,
      size: 15,
      color: CcColors.subtle,
    ),
    title: Text(
      name,
      style: const TextStyle(fontFamily: CcType.mono, fontSize: 12.5),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    onTap: () => widget.onOpenFile(path),
  );
}
