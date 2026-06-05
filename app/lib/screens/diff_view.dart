import 'package:flutter/material.dart';

import '../local/diff_parse.dart';
import '../local/prefs.dart';
import '../theme.dart';
import '../widgets.dart';

// DiffView is the GoLand-style diff: a changed-files tree (left) + the selected
// file's diff (right), toggleable between side-by-side (split) and unified.
// Shared by the local git diff page and the GitHub PR diff page.
class DiffView extends StatefulWidget {
  final List<FileDiff> files;
  const DiffView({super.key, required this.files});

  @override
  State<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends State<DiffView> {
  FileDiff? _selected;
  List<DiffRow> _rows = const [];
  bool _split = Prefs.getBool('diff.split', def: true);
  double _treeW = Prefs.getDouble('diff.treeW', def: 300);
  late _Dir _root; // the dir tree — built once per file list (not per build)

  @override
  void initState() {
    super.initState();
    _root = _buildTree(widget.files);
    _selectFirst();
  }

  @override
  void didUpdateWidget(DiffView old) {
    super.didUpdateWidget(old);
    if (!identical(old.files, widget.files)) {
      _root = _buildTree(widget.files);
      _selectFirst();
    }
  }

  void _selectFirst() {
    if (widget.files.isEmpty) {
      _selected = null;
      _rows = const [];
    } else {
      _select(widget.files.first);
    }
  }

  void _select(FileDiff f) {
    setState(() {
      _selected = f;
      _rows = parseRows(f.raw);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.files.isEmpty) return centerMsg('没有变动文件');
    return Row(children: [
      SizedBox(width: _treeW, child: _tree()),
      resizeHandle(
          prefKey: 'diff.treeW',
          get: () => _treeW,
          set: (v) => setState(() => _treeW = v),
          min: 200,
          max: 560),
      Expanded(child: _right()),
    ]);
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
      out.add(ExpansionTile(
        key: PageStorageKey('cc-dir$key'),
        initiallyExpanded: true,
        dense: true,
        visualDensity: const VisualDensity(vertical: -2),
        tilePadding: EdgeInsets.only(left: 8.0 + depth * 12, right: 8),
        childrenPadding: EdgeInsets.zero,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.folder_rounded, size: 16),
        title: Text(label,
            style: const TextStyle(fontFamily: CcType.mono, fontSize: 12.5),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        children: _treeChildren(sub, key, depth + 1),
      ));
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
                color: sel ? CcColors.accent : Colors.transparent, width: 2.5)),
      ),
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -2),
        selected: sel,
        contentPadding: EdgeInsets.only(left: 8.0 + depth * 12, right: 8),
        horizontalTitleGap: 6,
        leading: Text(_statusChar(f.status),
            style: TextStyle(
                fontFamily: CcType.mono,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: c)),
        title: Text(fname,
            style: const TextStyle(fontFamily: CcType.mono, fontSize: 12.5),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        trailing: Text('+${f.adds} −${f.dels}',
            style: const TextStyle(
                fontFamily: CcType.mono, fontSize: 11, color: CcColors.muted)),
        onTap: () => _select(f),
      ),
    );
  }

  // --------------------------------------------------------- right pane ----

  Widget _right() => Column(children: [
        Container(
          height: 40,
          padding: const EdgeInsets.only(left: 12, right: 8),
          decoration: const BoxDecoration(
            color: CcColors.panel,
            border: Border(bottom: BorderSide(color: CcColors.border)),
          ),
          child: Row(children: [
            Expanded(
              child: Text(_selected?.path ?? '',
                  style: const TextStyle(
                      fontFamily: CcType.mono,
                      fontSize: 12.5,
                      color: CcColors.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('并排')),
                ButtonSegment(value: false, label: Text('统一')),
              ],
              selected: {_split},
              onSelectionChanged: (s) {
                setState(() => _split = s.first);
                Prefs.setBool('diff.split', _split);
              },
              showSelectedIcon: false,
            ),
          ]),
        ),
        Expanded(child: _diffBody()),
      ]);

  Widget _diffBody() {
    final f = _selected;
    if (f == null) return centerMsg('选择左侧文件查看对比');
    // rename/mode-only files have no hunks → split shows nothing; the tree still
    // carries the status + counts. Binary/oversized files have empty raw.
    if (f.raw.trim().isEmpty) {
      return centerMsg('(无 diff —— 二进制或过大)');
    }
    if (!_split) {
      return ColoredBox(color: CcColors.bg, child: diffText(f.raw));
    }
    return ColoredBox(
      color: CcColors.bg,
      child: ListView.builder(
        itemCount: _rows.length,
        itemBuilder: (_, i) => _rowWidget(_rows[i]),
      ),
    );
  }

  Widget _rowWidget(DiffRow r) {
    if (r.isHunk) {
      return Container(
        width: double.infinity,
        color: CcColors.accent.withValues(alpha: 0.10),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(r.hunkText,
            style: const TextStyle(
                fontFamily: CcType.mono,
                fontSize: 12,
                color: CcColors.accentBright)),
      );
    }
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _gutter(r.oldNo),
        Expanded(child: _cell(r.left, r.leftKind)),
        const VerticalDivider(width: 1),
        _gutter(r.newNo),
        Expanded(child: _cell(r.right, r.rightKind)),
      ]),
    );
  }

  Widget _gutter(int? no) => Container(
        width: 44,
        alignment: Alignment.topRight,
        padding: const EdgeInsets.only(right: 6, top: 1),
        color: CcColors.panel,
        child: Text(no?.toString() ?? '',
            style: const TextStyle(
                fontFamily: CcType.mono, fontSize: 11, color: CcColors.subtle)),
      );

  Widget _cell(String text, DiffKind kind) {
    Color? bg;
    switch (kind) {
      case DiffKind.added:
        bg = CcColors.ok.withValues(alpha: 0.10);
      case DiffKind.removed:
        bg = CcColors.danger.withValues(alpha: 0.10);
      case DiffKind.empty:
        bg = CcColors.bgGradTop.withValues(alpha: 0.5); // padding cell, dimmed
      case DiffKind.context:
        bg = null;
    }
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Text(text,
          style: const TextStyle(
              fontFamily: CcType.mono,
              fontSize: 12.5,
              height: 1.4,
              color: CcColors.text)),
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
