import 'dart:io';

import 'package:flutter/material.dart';

import '../file_icons.dart';
import '../theme.dart';
import '../widgets.dart';
import 'editor_page.dart';

// GoLand-style tree metrics (Project panel look): a left disclosure chevron,
// per-type SVG icons, a full-row selection band, and faint indent guides.
const double _kRowBaseLeft = 8; // left gutter before depth 0
const double _kIndentStep = 16; // horizontal step per nesting level
const double _kChevronW = 16; // column reserved for the disclosure chevron

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
  final PopupMenuButton<String>? Function(String path)? fileMenuBuilder;
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
  final PopupMenuButton<String>? Function(String path)? fileMenuBuilder;
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
  late bool _open;

  @override
  void initState() {
    super.initState();
    _open = widget.initiallyExpanded || _containsSelectedPath;
    if (_open) _loadChildren();
  }

  @override
  void didUpdateWidget(DirTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reveal-in-project: when the selection moves into this dir, open + load so
    // the highlighted descendant becomes visible.
    if (oldWidget.selectedPath != widget.selectedPath && _containsSelectedPath) {
      if (!_open) setState(() => _open = true);
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
        if (!kIgnoredEntries.contains(e.path.split('/').last)) entries.add(e);
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

  void _toggle() {
    setState(() => _open = !_open);
    if (_open) _loadChildren();
  }

  @override
  Widget build(BuildContext context) {
    final selectedInDir = _containsSelectedPath;
    final selected = widget.selectedPath == widget.dir;
    final ancestor = selectedInDir && !selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _treeRow(
          depth: widget.depth,
          selected: selected,
          bold: selected || ancestor,
          onTap: _toggle,
          iconAsset: folderIconAsset,
          iconSize: 16,
          label: widget.label,
          status: widget.pathStatusBuilder?.call(widget.dir),
          chevron: AnimatedRotation(
            turns: _open ? 0.25 : 0.0,
            duration: const Duration(milliseconds: 150),
            child: Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: selected || ancestor ? CcColors.muted : CcColors.subtle,
            ),
          ),
        ),
        if (_open) ..._childWidgets(),
      ],
    );
  }

  // One row of the tree, shared by folders and files. The chevron column is
  // always reserved (an empty slot for files), so a file's icon lines up with
  // the same-depth folder icon by construction — no per-row alignment fudge.
  Widget _treeRow({
    required int depth,
    required bool selected,
    required bool bold,
    required VoidCallback onTap,
    required String iconAsset,
    required double iconSize,
    required String label,
    Widget? chevron,
    Widget? status,
  }) {
    return _IndentGuides(
      depth: depth,
      child: _band(
        selected,
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.only(
              left: _kRowBaseLeft + depth * _kIndentStep,
              right: 8,
              top: 3,
              bottom: 3,
            ),
            child: Row(
              children: [
                SizedBox(width: _kChevronW, child: chevron),
                const SizedBox(width: 2),
                fileSvg(iconAsset, size: iconSize),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: CcType.mono,
                      fontSize: 12.5,
                      color: CcColors.text,
                      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (status != null) ...[const SizedBox(width: 6), status],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _childWidgets() {
    if (_children == null) {
      return [
        Padding(
          padding: EdgeInsets.only(
            left: _kRowBaseLeft + (widget.depth + 1) * _kIndentStep + _kChevronW,
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

  // Full-row GoLand-style selection band (flat translucent fill, no left rule).
  // Decorations are cached so the common unselected row allocates nothing.
  static const _noBand = BoxDecoration();
  static final _selBand = BoxDecoration(
    color: CcColors.accent.withValues(alpha: 0.16),
  );
  Widget _band(bool selected, Widget child) =>
      DecoratedBox(decoration: selected ? _selBand : _noBand, child: child);

  Widget _fileTile(String path, String name, int depth) {
    final selected = path == widget.selectedPath;
    final menu = widget.fileMenuBuilder?.call(path);
    final row = _treeRow(
      depth: depth,
      selected: selected,
      bold: selected,
      onTap: () => widget.onOpenFile(path),
      iconAsset: fileIconAsset(name),
      iconSize: 15,
      label: name,
      status: widget.pathStatusBuilder?.call(path),
    );
    if (menu == null) return row;
    // Right-click anywhere on the file row pops the same actions (no ⋮ button).
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (d) async {
        menu.onOpened?.call();
        final overlay =
            Overlay.of(context).context.findRenderObject() as RenderBox;
        final value = await showMenu<String>(
          context: context,
          position: RelativeRect.fromRect(
            d.globalPosition & const Size(1, 1),
            Offset.zero & overlay.size,
          ),
          items: menu.itemBuilder(context),
        );
        if (value != null && mounted) menu.onSelected?.call(value);
      },
      child: row,
    );
  }
}

// _IndentGuides paints one faint vertical rule per ancestor level behind a row,
// aligned under each ancestor's chevron. Stacked rows make them read as
// continuous tree guides, like GoLand's Project panel.
class _IndentGuides extends StatelessWidget {
  final int depth;
  final Widget child;
  const _IndentGuides({required this.depth, required this.child});

  @override
  Widget build(BuildContext context) {
    if (depth <= 0) return child;
    return CustomPaint(painter: _GuidePainter(depth), child: child);
  }
}

class _GuidePainter extends CustomPainter {
  final int depth;
  _GuidePainter(this.depth);

  static final Paint _paint = Paint()
    ..color = CcColors.border.withValues(alpha: 0.55)
    ..strokeWidth = 1;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < depth; i++) {
      final x = _kRowBaseLeft + i * _kIndentStep + _kChevronW / 2;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), _paint);
    }
  }

  @override
  bool shouldRepaint(_GuidePainter old) => old.depth != depth;
}
