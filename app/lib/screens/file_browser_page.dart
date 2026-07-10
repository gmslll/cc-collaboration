import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../file_icons.dart';
import '../fs_clipboard.dart';
import '../theme.dart';
import '../widgets.dart';
import 'editor_page.dart';

// GoLand-style tree metrics (Project panel look): a left disclosure chevron,
// per-type SVG icons, a full-row selection band, and faint indent guides.
const double _kRowBaseLeft = 8; // left gutter before depth 0
const double _kIndentStep = 16; // horizontal step per nesting level
const double _kChevronW = 16; // column reserved for the disclosure chevron

double fileNameDialogWidth(Size size, {double preferred = 420}) {
  final available = size.width - 32;
  if (!available.isFinite || available <= 0) return preferred;
  return available < preferred ? available : preferred;
}

double fileConfirmDialogWidth(Size size, {double preferred = 420}) {
  final available = size.width - 32;
  if (!available.isFinite || available <= 0) return preferred;
  return available < preferred ? available : preferred;
}

// FileBrowserPage is a lazy file tree of a project root; tapping a file opens it
// in the editor. Each directory lists its children on first expand.
class FileBrowserPage extends StatefulWidget {
  final String root;
  final String name;
  const FileBrowserPage({super.key, required this.root, required this.name});

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage>
    with FsClipboardActions {
  int _refreshToken = 0;
  String? _selectedPath;
  Offset? _lastContextMenuPosition;
  // 文件树聚焦时才响应 Cmd/Ctrl+C/X/V。
  final FocusNode _treeFocus = FocusNode(debugLabel: 'fileBrowserTree');

  @override
  void dispose() {
    _treeFocus.dispose();
    super.dispose();
  }

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
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => FileNameDialog(
        title: title,
        label: label,
        initial: initial,
        hint: hint,
      ),
    );
    if (raw == null) return null;
    if (!mounted) return null;
    final name = raw.trim();
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
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: fileConfirmDialogWidth(size),
            child: SingleChildScrollView(
              child: SelectableText(message, style: CcType.code(size: 12)),
            ),
          ),
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
        );
      },
    );
    if (!mounted) return false;
    return ok == true;
  }

  Future<void> _newFile(String dir) async {
    final name = await _nameDialog('新建文件', '文件名', hint: 'README.md');
    if (name == null) return;
    if (!mounted) return;
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
    if (!mounted) return;
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
    if (!mounted) return;
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
    if (!mounted) return;
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

  // FsClipboardActions 的三处注入点：选中项 / 提示 / 写盘后刷新。
  // 四个操作(fsCopy/fsCut/fsPaste/fsDrop) 和键盘绑定(fsShortcuts) 都来自 mixin。
  @override
  String? get fsSelectedPath => _selectedPath;

  @override
  void fsNotify(String msg) {
    if (mounted) snack(context, msg);
  }

  @override
  Future<void> fsOnWritten(String firstPath) async => _markChanged(firstPath);

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
      case 'copy':
        fsCopy([path]);
      case 'cut':
        fsCut([path]);
      case 'paste':
        fsPaste(isDir ? path : _parentDir(path));
      case 'reveal':
      case 'revealSystem':
        _revealInSystem(path);
      case 'openExternal':
        _openExternally(path);
      case 'refresh':
        _markChanged(path);
    }
  }

  Future<void> _selectPathMenu(String value, String path, bool isDir) async {
    if (value == fileMenuEdit || value == fileMenuLocate) {
      final pick = await showMenu<String>(
        context: context,
        position: menuPosAt(
          context,
          _lastContextMenuPosition ?? _fallbackMenuPosition(),
        ),
        items: fileActionSubmenuEntries(
          value,
          atRoot: path == widget.root,
          includeProjectReveal: false,
          includeTerminal: false,
        ),
      );
      if (pick == null || !mounted) return;
      _handleMenu(pick, path, isDir);
      return;
    }
    _handleMenu(value, path, isDir);
  }

  PopupMenuButton<String> _pathMenu(String path, bool isDir) =>
      PopupMenuButton<String>(
        tooltip: 'File actions',
        icon: const Icon(Icons.more_vert_rounded, size: 16),
        padding: EdgeInsets.zero,
        onOpened: () {
          _lastContextMenuPosition = null;
          setState(() => _selectedPath = path);
        },
        onSelected: (v) => unawaited(_selectPathMenu(v, path, isDir)),
        itemBuilder: (_) =>
            fileActionMenuEntries(isDir: isDir, includeVersionControl: false),
      );

  Offset _fallbackMenuPosition() {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    return overlay.localToGlobal(overlay.size.center(Offset.zero));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '文件 · ${widget.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: DecoratedBox(
        decoration: appGradient,
        // CallbackShortcuts 在外、聚焦节点在内：点进树使其聚焦后才响应 Cmd/Ctrl+C/X/V。
        child: CallbackShortcuts(
          bindings: fsShortcuts,
          child: Focus(
            focusNode: _treeFocus,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _treeFocus.requestFocus(),
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  FileTree(
                    root: widget.root,
                    label: widget.name,
                    onOpenFile: (path) => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => EditorPage(path: path)),
                    ),
                    selectedPath: _selectedPath,
                    onSelectPath: (p) => setState(() => _selectedPath = p),
                    onDropPaths: fsDrop,
                    onMenuPosition: (pos) => _lastContextMenuPosition = pos,
                    refreshToken: _refreshToken,
                    fileMenuBuilder: (path) => _pathMenu(path, false),
                    directoryMenuBuilder: (path) => _pathMenu(path, true),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FileNameDialog extends StatefulWidget {
  final String title;
  final String label;
  final String initial;
  final String hint;

  const FileNameDialog({
    super.key,
    required this.title,
    required this.label,
    this.initial = '',
    this.hint = '',
  });

  @override
  State<FileNameDialog> createState() => _FileNameDialogState();
}

class _FileNameDialogState extends State<FileNameDialog> {
  late final TextEditingController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _ctl.text);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: fileNameDialogWidth(size),
        child: SingleChildScrollView(
          child: TextField(
            controller: _ctl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: widget.hint,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}

class FileTree extends StatelessWidget {
  final String root;
  final String label;
  final ValueChanged<String> onOpenFile;
  final String? selectedPath;
  final ValueChanged<String>? onSelectPath;
  final void Function(String dir, List<String> paths)? onDropPaths;
  final ValueChanged<Offset>? onMenuPosition;
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
    this.onSelectPath,
    this.onDropPaths,
    this.onMenuPosition,
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
    onSelectPath: onSelectPath,
    onDropPaths: onDropPaths,
    onMenuPosition: onMenuPosition,
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
  // 点任意行(文件或目录)时回调,让上层把它设为当前选中项——键盘 C/X/V 据此定位目标。
  final ValueChanged<String>? onSelectPath;
  // 从访达把文件拖到某个目录行上时回调 (目录路径, 拖入的源路径列表)。
  final void Function(String dir, List<String> paths)? onDropPaths;
  final ValueChanged<Offset>? onMenuPosition;
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
    this.onSelectPath,
    this.onDropPaths,
    this.onMenuPosition,
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
  bool _dropHover = false; // 访达文件正悬停在本目录行上

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
      onTap: () {
        widget.onSelectPath?.call(widget.dir);
        _toggle();
      },
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
    var folderRow = menu == null ? row : _menuGesture(row, menu);
    // 目录行同时是拖入目标：从访达拖文件到这一行 → 复制进该目录（悬停高亮）。
    // 各目录行是 Column 里的兄弟节点、互不嵌套，因此拖放事件只命中光标下的那一行。
    if (widget.onDropPaths != null) {
      folderRow = DropTarget(
        onDragEntered: (_) => setState(() => _dropHover = true),
        onDragExited: (_) => setState(() => _dropHover = false),
        onDragDone: (detail) {
          setState(() => _dropHover = false);
          final paths = detail.files
              .map((f) => f.path)
              .where((p) => p.isNotEmpty)
              .toList();
          if (paths.isNotEmpty) widget.onDropPaths!(widget.dir, paths);
        },
        child: DecoratedBox(
          decoration: _dropHover ? _dropBand : const BoxDecoration(),
          child: folderRow,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [folderRow, if (_open) ..._childWidgets()],
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
            onSelectPath: widget.onSelectPath,
            onDropPaths: widget.onDropPaths,
            onMenuPosition: widget.onMenuPosition,
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
  // 拖入悬停：更明显的填充 + 强调色描边，提示"松手会放进这个文件夹"。
  static final _dropBand = BoxDecoration(
    color: CcColors.accent.withValues(alpha: 0.22),
    border: Border.all(color: CcColors.accent, width: 1),
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
      onTap: () {
        widget.onSelectPath?.call(path);
        widget.onOpenFile(path);
      },
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
        widget.onMenuPosition?.call(d.globalPosition);
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
