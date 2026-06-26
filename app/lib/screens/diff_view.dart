import 'dart:io';

import 'package:flutter/material.dart';

import '../local/diff_parse.dart';
import '../local/git.dart';
import '../local/prefs.dart';
import '../syntax.dart';
import '../theme.dart';
import '../widgets.dart';
import 'diff_split.dart';
import 'editor_page.dart';

// DiffView is the GoLand-style diff: a changed-files tree (left) + the selected
// file's diff (right), toggleable between side-by-side (split) and unified.
// Shared by the local git diff page and the GitHub PR diff page. When [editRoot]
// is set (local diff), the selected file can be edited or its changes discarded;
// [onChanged] re-runs the diff afterward. PR diffs leave editRoot null (remote,
// read-only).
class DiffView extends StatefulWidget {
  final List<FileDiff> files;
  final String? editRoot;
  final VoidCallback? onChanged;
  final String? initialPath; // file to select first (else the first file)
  final bool showTree; // false = single-pane (nav driven by an external list)
  // onReloadContext re-fetches this diff with a given git context-line count
  // (3 = changed regions only, 999999 = whole file). Non-null enables the
  // 全部/相关 toggle; the closure captures the source (commit/compare/working).
  final Future<List<FileDiff>> Function(int context)? onReloadContext;
  const DiffView({
    super.key,
    required this.files,
    this.editRoot,
    this.onChanged,
    this.initialPath,
    this.showTree = true,
    this.onReloadContext,
  });

  @override
  State<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends State<DiffView> {
  FileDiff? _selected;
  String? _lang; // re_highlight language id of the selected file (null = plain)
  List<DiffRow> _rows = const [];
  bool _split = Prefs.getBool('diff.split', def: true);
  // 全部/相关: false = git's default context (changed regions only), true = whole
  // file (re-fetched via onReloadContext). _files is what we render — it starts
  // as widget.files and is swapped for the full-context fetch when toggled.
  bool _fullContext = Prefs.getBool('diff.fullContext', def: false);
  late List<FileDiff> _files;
  double _treeW = Prefs.getDouble('diff.treeW', def: 300);
  late _Dir _root; // the dir tree — built once per file list (not per build)
  int? _editingNewNo; // the new-side line number currently being inline-edited
  final _editCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _files = widget.files;
    _root = _buildTree(_files);
    _reselect(widget.initialPath);
    // Honor a persisted 「全部」 toggle on first load.
    if (_fullContext && widget.onReloadContext != null) _applyContext(true);
  }

  @override
  void dispose() {
    _editCtl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(DiffView old) {
    super.didUpdateWidget(old);
    final pathChanged =
        widget.initialPath != null && widget.initialPath != old.initialPath;
    if (!identical(old.files, widget.files)) {
      // a re-diff (after edit/revert) or a re-pointed tab (new commit) replaces
      // the list — adopt the parent's (default-context) list, keep the user on
      // the same file by path unless explicitly pointed at a new one.
      _files = widget.files;
      _root = _buildTree(_files);
      _reselect(pathChanged ? widget.initialPath : _selected?.path);
      // Re-apply a persisted 「全部」 view to the new source.
      if (_fullContext && widget.onReloadContext != null) _applyContext(true);
    } else if (pathChanged) {
      // same file list, but the commit list selected a different file — follow.
      _reselect(widget.initialPath);
    }
  }

  // _applyContext re-fetches the diff at the requested context (全部 vs 相关) via
  // the parent's closure and swaps in the result, keeping the current selection.
  Future<void> _applyContext(bool full) async {
    final reload = widget.onReloadContext;
    if (reload == null) return;
    if (_fullContext != full) setState(() => _fullContext = full);
    try {
      final fs = await reload(full ? 999999 : 3);
      if (!mounted) return;
      setState(() {
        _files = fs;
        _root = _buildTree(_files);
      });
      _reselect(_selected?.path);
    } catch (_) {
      // keep the current diff on failure
    }
  }

  void _reselect(String? path) {
    if (_files.isEmpty) {
      setState(() {
        _selected = null;
        _rows = const [];
        _editingNewNo = null;
      });
      return;
    }
    var target = _files.first;
    if (path != null) {
      for (final f in _files) {
        if (f.path == path) {
          target = f;
          break;
        }
      }
    }
    _select(target);
  }

  void _select(FileDiff f) {
    setState(() {
      _selected = f;
      _lang = langIdForPath(f.path);
      _rows = parseRows(f.raw);
      _editingNewNo = null;
    });
  }

  // ---- line-level edit + per-hunk revert (local diff only) ----

  void _startEdit(DiffRow r) {
    _editCtl.text = r.right;
    setState(() => _editingNewNo = r.newNo);
  }

  void _cancelEdit() => setState(() => _editingNewNo = null);

  // _commitEdit replaces line [r.newNo] in the working file with the edited text.
  Future<void> _commitEdit(DiffRow r) async {
    final newNo = r.newNo, root = widget.editRoot, f = _selected;
    setState(() => _editingNewNo = null);
    if (newNo == null || root == null || f == null) return;
    try {
      final file = File('$root/${f.path}');
      final lines = (await file.readAsString()).split('\n');
      // guard against a stale line number: the diff said this line is `r.right`;
      // if the file changed under us, refuse rather than clobber another line.
      if (newNo - 1 < 0 ||
          newNo - 1 >= lines.length ||
          lines[newNo - 1] != r.right) {
        if (mounted) snack(context, '文件已变,请刷新后再改');
        return;
      }
      lines[newNo - 1] = _editCtl.text;
      await file.writeAsString(lines.join('\n'));
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  // _revertHunk reverts just hunk [i] in the working file via git apply -R.
  Future<void> _revertHunk(int i) async {
    final root = widget.editRoot, f = _selected;
    if (root == null || f == null) return;
    final (header, hunks) = splitHunks(f.raw);
    if (i < 0 || i >= hunks.length) return;
    try {
      await gitApplyReverse(root, '$header\n${hunks[i]}\n');
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  Future<void> _edit() async {
    final f = _selected;
    final root = widget.editRoot;
    if (f == null || root == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => EditorPage(path: '$root/${f.path}')),
    );
    widget.onChanged?.call();
  }

  Future<void> _discard() async {
    final f = _selected;
    final root = widget.editRoot;
    if (f == null || root == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('丢弃改动?'),
        content: Text('${f.path}\n\ngit checkout -- 丢弃未提交改动,不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('丢弃'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await gitRestore(root, f.path);
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_files.isEmpty) return centerMsg('没有变动文件');
    // single-pane: only the diff; file navigation is driven by an external list
    // (e.g. the Commit panel) so the internal tree would be redundant.
    if (!widget.showTree) return _right();
    return Row(
      children: [
        SizedBox(width: _treeW, child: _tree()),
        resizeHandle(
          prefKey: 'diff.treeW',
          get: () => _treeW,
          set: (v) => setState(() => _treeW = v),
          min: 200,
          max: 560,
        ),
        Expanded(child: _right()),
      ],
    );
  }

  // ----------------------------------------------------------- file tree ----

  Widget _tree() => DecoratedBox(
    decoration: const BoxDecoration(
      color: CcColors.panel,
      border: Border(right: BorderSide(color: CcColors.border)),
    ),
    child: ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: _treeChildren(_root, '', 0),
    ),
  );

  List<Widget> _treeChildren(_Dir dir, String prefix, int depth) {
    final out = <Widget>[];
    for (final name in dir.dirs.keys.toList()..sort()) {
      var sub = dir.dirs[name]!;
      var label = name;
      // compact single-child dir chains (lib/api shown as one node).
      while (sub.dirs.length == 1 && sub.files.isEmpty) {
        final only = sub.dirs.keys.first;
        label = '$label/$only';
        sub = sub.dirs[only]!;
      }
      final key = '$prefix/$label';
      out.add(
        ExpansionTile(
          key: PageStorageKey('cc-dir$key'),
          initiallyExpanded: true,
          dense: true,
          visualDensity: const VisualDensity(vertical: -2),
          tilePadding: EdgeInsets.only(left: 8.0 + depth * 12, right: 8),
          childrenPadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          leading: const Icon(Icons.folder_rounded, size: 16),
          title: Text(
            label,
            style: const TextStyle(fontFamily: CcType.mono, fontSize: 12.5),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          children: _treeChildren(sub, key, depth + 1),
        ),
      );
    }
    final files = [...dir.files]..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      out.add(_fileTile(f, f.path.split('/').last, depth));
    }
    return out;
  }

  Widget _fileTile(FileDiff f, String fname, int depth) {
    final sel = identical(_selected, f);
    final c = _statusColor(f.status);
    return Container(
      decoration: BoxDecoration(
        color: sel ? CcColors.accent.withValues(alpha: 0.10) : null,
        border: Border(
          left: BorderSide(
            color: sel ? CcColors.accent : Colors.transparent,
            width: 2.5,
          ),
        ),
      ),
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -2),
        selected: sel,
        contentPadding: EdgeInsets.only(left: 8.0 + depth * 12, right: 8),
        horizontalTitleGap: 6,
        leading: Text(
          _statusChar(f.status),
          style: TextStyle(
            fontFamily: CcType.mono,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: c,
          ),
        ),
        title: Text(
          fname,
          style: const TextStyle(fontFamily: CcType.mono, fontSize: 12.5),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          '+${f.adds} −${f.dels}',
          style: const TextStyle(
            fontFamily: CcType.mono,
            fontSize: 11,
            color: CcColors.muted,
          ),
        ),
        onTap: () => _select(f),
      ),
    );
  }

  // --------------------------------------------------------- right pane ----

  Widget _right() => Column(
    children: [
      Container(
        height: 40,
        padding: const EdgeInsets.only(left: 12, right: 8),
        decoration: const BoxDecoration(
          color: CcColors.panel,
          border: Border(bottom: BorderSide(color: CcColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _selected?.path ?? '',
                style: const TextStyle(
                  fontFamily: CcType.mono,
                  fontSize: 12.5,
                  color: CcColors.muted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            scrollableActions([
              if (widget.editRoot != null && _selected != null) ...[
                TextButton.icon(
                  onPressed: _edit,
                  icon: const Icon(Icons.edit_rounded, size: 16),
                  label: const Text('编辑'),
                ),
                TextButton.icon(
                  onPressed: _discard,
                  icon: const Icon(Icons.undo_rounded, size: 16),
                  label: const Text('丢弃'),
                ),
                const SizedBox(width: 8),
              ],
              if (widget.onReloadContext != null) ...[
                diffContextToggle(_fullContext, _applyContext),
                const SizedBox(width: 8),
              ],
              diffSplitToggle(_split, (v) => setState(() => _split = v)),
            ]),
          ],
        ),
      ),
      Expanded(child: _diffBody()),
    ],
  );

  Widget _diffBody() {
    final f = _selected;
    if (f == null) return centerMsg('选择左侧文件查看对比');
    // rename/mode-only files have no hunks → split shows nothing; the tree still
    // carries the status + counts. Binary/oversized files have empty raw.
    if (f.raw.trim().isEmpty) {
      return centerMsg('(无 diff —— 二进制或过大)');
    }
    if (!_split) {
      return ColoredBox(
        color: CcColors.bg,
        child: diffText(f.raw, highlight: true),
      );
    }
    return ColoredBox(
      color: CcColors.bg,
      child: ListView.builder(
        itemCount: _rows.length,
        itemBuilder: (_, i) => _rowWidget(_rows[i]),
      ),
    );
  }

  Widget _rowWidget(DiffRow r) => diffSplitRow(
    r,
    langId: _lang,
    rightCell: _rightCell,
    hunkTrailing: widget.editRoot == null
        ? null
        : (row) => TextButton.icon(
            onPressed: () => _revertHunk(row.hunkIndex),
            icon: const Icon(Icons.undo_rounded, size: 14),
            label: const Text('还原', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              visualDensity: VisualDensity.compact,
            ),
          ),
  );

  // _rightCell is the editable new-side cell: inline TextField while editing,
  // else the text with a pencil on hover (when editing is allowed).
  Widget _rightCell(DiffRow r) {
    if (_editingNewNo != null && _editingNewNo == r.newNo) {
      return ColoredBox(
        color: CcColors.panelHigh,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _editCtl,
                autofocus: true,
                style: const TextStyle(
                  fontFamily: CcType.mono,
                  fontSize: 12.5,
                  color: CcColors.text,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                ),
                onSubmitted: (_) => _commitEdit(r),
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.check_rounded,
                size: 16,
                color: CcColors.ok,
              ),
              visualDensity: VisualDensity.compact,
              onPressed: () => _commitEdit(r),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 16),
              visualDensity: VisualDensity.compact,
              onPressed: _cancelEdit,
            ),
          ],
        ),
      );
    }
    final editable =
        widget.editRoot != null &&
        r.newNo != null &&
        r.rightKind != DiffKind.empty;
    if (!editable) return diffCell(r.right, r.rightKind, langId: _lang);
    return _EditableCell(
      text: r.right,
      kind: r.rightKind,
      langId: _lang,
      onEdit: () => _startEdit(r),
    );
  }
}

// _EditableCell shows a new-side line with a pencil on hover; tapping it asks the
// parent to switch the cell into an inline editor.
class _EditableCell extends StatefulWidget {
  final String text;
  final DiffKind kind;
  final String? langId;
  final VoidCallback onEdit;
  const _EditableCell({
    required this.text,
    required this.kind,
    required this.onEdit,
    this.langId,
  });

  @override
  State<_EditableCell> createState() => _EditableCellState();
}

class _EditableCellState extends State<_EditableCell> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final span = widget.langId == null
        ? null
        : highlightLine(widget.text, widget.langId, base: diffCellStyle);
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: Container(
        color: diffCellBg(widget.kind),
        padding: const EdgeInsets.only(left: 8, right: 2, top: 1, bottom: 1),
        child: Row(
          children: [
            Expanded(
              child: span == null
                  ? Text(widget.text, style: diffCellStyle)
                  : Text.rich(span),
            ),
            if (_h)
              InkWell(
                onTap: widget.onEdit,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 2),
                  child: Icon(
                    Icons.edit_rounded,
                    size: 13,
                    color: CcColors.muted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- tree model ----

class _Dir {
  final Map<String, _Dir> dirs = {};
  final List<FileDiff> files = [];
}

_Dir _buildTree(List<FileDiff> files) {
  final root = _Dir();
  for (final f in files) {
    final parts = f.path.split('/');
    var node = root;
    for (var i = 0; i < parts.length - 1; i++) {
      node = node.dirs.putIfAbsent(parts[i], _Dir.new);
    }
    node.files.add(f);
  }
  return root;
}

Color _statusColor(String s) => switch (s) {
  'added' => CcColors.ok,
  'deleted' => CcColors.danger,
  'renamed' => CcColors.warning,
  _ => CcColors.accent,
};

String _statusChar(String s) => switch (s) {
  'added' => 'A',
  'deleted' => 'D',
  'renamed' => 'R',
  _ => 'M',
};
