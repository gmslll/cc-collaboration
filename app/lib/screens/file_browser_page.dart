import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
class FileBrowserPage extends StatefulWidget {
  final String root;
  final String name;
  const FileBrowserPage({super.key, required this.root, required this.name});

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  int _refreshToken = 0;
  String? _selectedPath;

  String _join(String dir, String name) =>
      dir.endsWith('/') || dir.endsWith(r'\') ? '$dir$name' : '$dir/$name';

  String _baseName(String path) {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf(r'\');
    final i = slash > backslash ? slash : backslash;
    return i < 0 ? path : path.substring(i + 1);
  }

  String _parentDir(String path) {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf(r'\');
    final i = slash > backslash ? slash : backslash;
    return i < 0 ? '' : path.substring(0, i);
  }

  void _markChanged([String? selectedPath]) {
    setState(() {
      _refreshToken++;
      if (selectedPath != null) _selectedPath = selectedPath;
    });
  }

  bool _validName(String name) =>
      name.trim().isNotEmpty && !name.contains('/') && !name.contains(r'\');

  Future<String?> _nameDialog(
    String title,
    String label, {
    String initial = '',
    String hint = '',
  }) async {
    final ctl = TextEditingController(text: initial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(labelText: label, hintText: hint),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true) return null;
    final name = ctl.text.trim();
    if (!_validName(name)) {
      if (!mounted) return null;
      snack(context, '名称不能为空，也不能包含路径分隔符');
      return null;
    }
    return name;
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _newFile(String dir) async {
    final name = await _nameDialog('新建文件', '文件名', hint: 'README.md');
    if (name == null) return;
    final path = _join(dir, name);
    try {
      await File(path).create(exclusive: true);
      _markChanged(path);
      if (mounted) {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => EditorPage(path: path)));
      }
    } catch (e) {
      if (mounted) snack(context, '新建文件失败：$e');
    }
  }

  Future<void> _newDirectory(String dir) async {
    final name = await _nameDialog('新建目录', '目录名', hint: 'src');
    if (name == null) return;
    final path = _join(dir, name);
    try {
      await Directory(path).create();
      _markChanged(path);
    } catch (e) {
      if (mounted) snack(context, '新建目录失败：$e');
    }
  }

  Future<void> _renamePath(String path, bool isDir) async {
    if (path == widget.root) {
      snack(context, '不能重命名项目根目录');
      return;
    }
    final name = await _nameDialog('重命名', '名称', initial: _baseName(path));
    if (name == null) return;
    final target = _join(_parentDir(path), name);
    try {
      if (isDir) {
        await Directory(path).rename(target);
      } else {
        await File(path).rename(target);
      }
      _markChanged(target);
    } catch (e) {
      if (mounted) snack(context, '重命名失败：$e');
    }
  }

  Future<void> _deletePath(String path, bool isDir) async {
    if (path == widget.root) {
      snack(context, '不能删除项目根目录');
      return;
    }
    final ok = await _confirm('删除「${_baseName(path)}」?', '此操作会删除磁盘文件。');
    if (!ok) return;
    try {
      if (isDir) {
        await Directory(path).delete(recursive: true);
      } else {
        await File(path).delete();
      }
      _markChanged(_parentDir(path));
    } catch (e) {
      if (mounted) snack(context, '删除失败：$e');
    }
  }

  Future<void> _revealInSystem(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', path]);
      } else {
        final target = FileSystemEntity.isDirectorySync(path)
            ? path
            : _parentDir(path);
        await Process.run('xdg-open', [target]);
      }
    } catch (e) {
      if (mounted) snack(context, '打开系统文件管理器失败：$e');
    }
  }

  Future<void> _openExternally(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      if (mounted) snack(context, '打开失败：$e');
    }
  }

  void _handleMenu(String value, String path, bool isDir) {
    setState(() => _selectedPath = path);
    switch (value) {
      case 'open':
        if (isDir) {
          _markChanged(path);
        } else {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => EditorPage(path: path)));
        }
      case 'newFile':
        _newFile(isDir ? path : _parentDir(path));
      case 'newDir':
        _newDirectory(isDir ? path : _parentDir(path));
      case 'rename':
        _renamePath(path, isDir);
      case 'delete':
        _deletePath(path, isDir);
      case 'copyPath':
        Clipboard.setData(ClipboardData(text: path));
        snack(context, '已复制路径');
      case 'reveal':
        _revealInSystem(path);
      case 'openExternal':
        _openExternally(path);
      case 'refresh':
        _markChanged(path);
    }
  }

  PopupMenuButton<String> _pathMenu(String path, bool isDir) =>
      PopupMenuButton<String>(
        tooltip: 'File actions',
        icon: const Icon(Icons.more_vert_rounded, size: 16),
        padding: EdgeInsets.zero,
        onOpened: () => setState(() => _selectedPath = path),
        onSelected: (v) => _handleMenu(v, path, isDir),
        itemBuilder: (_) => [
          ccMenuItem(
            value: 'open',
            icon: isDir
                ? Icons.folder_open_rounded
                : Icons.description_outlined,
            label: isDir ? 'Open Folder' : 'Open',
          ),
          const PopupMenuDivider(),
          ccMenuItem(
            value: 'newFile',
            icon: Icons.note_add_outlined,
            label: 'New File',
          ),
          ccMenuItem(
            value: 'newDir',
            icon: Icons.create_new_folder_outlined,
            label: 'New Directory',
          ),
          const PopupMenuDivider(),
          ccMenuItem(
            value: path == widget.root ? null : 'rename',
            icon: Icons.drive_file_rename_outline_rounded,
            label: 'Rename',
          ),
          ccMenuItem(
            value: path == widget.root ? null : 'delete',
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
            danger: true,
          ),
          const PopupMenuDivider(),
          ccMenuItem(
            value: 'copyPath',
            icon: Icons.content_copy_rounded,
            label: 'Copy Path',
          ),
          ccMenuItem(
            value: 'reveal',
            icon: Icons.my_location_rounded,
            label: 'Reveal in System',
          ),
          ccMenuItem(
            value: 'openExternal',
            icon: Icons.open_in_new_rounded,
            label: 'Open In',
          ),
          const PopupMenuDivider(),
          ccMenuItem(
            value: 'refresh',
            icon: Icons.refresh_rounded,
            label: 'Reload from Disk',
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('文件 · ${widget.name}')),
      body: DecoratedBox(
        decoration: appGradient,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 4),
          children: [
            FileTree(
              root: widget.root,
              label: widget.name,
              onOpenFile: (path) => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => EditorPage(path: path))),
              selectedPath: _selectedPath,
              refreshToken: _refreshToken,
              fileMenuBuilder: (path) => _pathMenu(path, false),
              directoryMenuBuilder: (path) => _pathMenu(path, true),
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
  final PopupMenuButton<String>? Function(String path)? directoryMenuBuilder;
  final Widget Function(String path)? pathStatusBuilder;
  final int refreshToken;
  const FileTree({
    super.key,
    required this.root,
    required this.label,
    required this.onOpenFile,
    this.selectedPath,
    this.fileMenuBuilder,
    this.directoryMenuBuilder,
    this.pathStatusBuilder,
    this.refreshToken = 0,
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
    directoryMenuBuilder: directoryMenuBuilder,
    pathStatusBuilder: pathStatusBuilder,
    refreshToken: refreshToken,
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
  final PopupMenuButton<String>? Function(String path)? directoryMenuBuilder;
  final Widget Function(String path)? pathStatusBuilder;
  final int refreshToken;
  const DirTile({
    super.key,
    required this.dir,
    required this.label,
    required this.depth,
    required this.onOpenFile,
    this.initiallyExpanded = false,
    this.selectedPath,
    this.fileMenuBuilder,
    this.directoryMenuBuilder,
    this.pathStatusBuilder,
    this.refreshToken = 0,
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
    if (oldWidget.selectedPath != widget.selectedPath &&
        _containsSelectedPath) {
      if (!_open) setState(() => _open = true);
      _loadChildren();
    }
    if (oldWidget.refreshToken != widget.refreshToken) {
      _children = null;
      if (_open || _containsSelectedPath) _loadChildren();
    }
  }

  bool get _containsSelectedPath {
    final selected = widget.selectedPath;
    if (selected == null || selected.isEmpty) return false;
    return selected == widget.dir ||
        selected.startsWith('${widget.dir}/') ||
        selected.startsWith('${widget.dir}\\');
  }

  String _baseName(String path) {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf(r'\');
    final i = slash > backslash ? slash : backslash;
    return i < 0 ? path : path.substring(i + 1);
  }

  Future<void> _loadChildren() async {
    if (_children != null || _loading) return;
    setState(() => _loading = true);
    final entries = <FileSystemEntity>[];
    try {
      await for (final e in Directory(widget.dir).list(followLinks: false)) {
        if (!kIgnoredEntries.contains(_baseName(e.path))) entries.add(e);
      }
    } catch (_) {}
    entries.sort((a, b) {
      final ad = a is Directory, bd = b is Directory;
      if (ad != bd) return ad ? -1 : 1; // directories first
      return _baseName(
        a.path,
      ).toLowerCase().compareTo(_baseName(b.path).toLowerCase());
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
    final menu = widget.directoryMenuBuilder?.call(widget.dir);
    final row = _treeRow(
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
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        menu == null ? row : _menuGesture(row, menu),
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
            left:
                _kRowBaseLeft + (widget.depth + 1) * _kIndentStep + _kChevronW,
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
            label: _baseName(e.path),
            depth: d,
            onOpenFile: widget.onOpenFile,
            selectedPath: widget.selectedPath,
            fileMenuBuilder: widget.fileMenuBuilder,
            directoryMenuBuilder: widget.directoryMenuBuilder,
            pathStatusBuilder: widget.pathStatusBuilder,
            refreshToken: widget.refreshToken,
          )
        else
          _fileTile(e.path, _baseName(e.path), d),
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
    return _menuGesture(row, menu);
  }

  Widget _menuGesture(Widget row, PopupMenuButton<String> menu) {
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
