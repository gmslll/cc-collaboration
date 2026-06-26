import 'package:flutter/material.dart';

import '../local/diff_parse.dart';
import '../local/prefs.dart';
import '../syntax.dart';
import '../theme.dart';

// diffSplitToggle is the shared 并排/统一 switch (persists the 'diff.split' pref);
// used by both the desktop DiffView and the phone diff viewer. onChanged carries
// the new value so the caller can setState its own _split.
Widget diffSplitToggle(
  bool split,
  ValueChanged<bool> onChanged, {
  ButtonStyle? style,
}) => SegmentedButton<bool>(
  segments: const [
    ButtonSegment(value: true, label: Text('并排')),
    ButtonSegment(value: false, label: Text('统一')),
  ],
  selected: {split},
  showSelectedIcon: false,
  style: style,
  onSelectionChanged: (s) {
    Prefs.setBool('diff.split', s.first);
    onChanged(s.first);
  },
);

// diffContextToggle is the 全部/相关 switch (persists the 'diff.fullContext' pref):
// 全部 = re-fetch the diff with full file context (every line shown), 相关 = only
// changed regions (git's default context). onChanged carries the new value.
Widget diffContextToggle(
  bool full,
  ValueChanged<bool> onChanged, {
  ButtonStyle? style,
}) => SegmentedButton<bool>(
  segments: const [
    ButtonSegment(value: false, label: Text('相关')),
    ButtonSegment(value: true, label: Text('全部')),
  ],
  selected: {full},
  showSelectedIcon: false,
  style: style,
  onSelectionChanged: (s) {
    Prefs.setBool('diff.fullContext', s.first);
    onChanged(s.first);
  },
);

// Shared GoLand-style split-diff rendering, used by BOTH the desktop DiffView
// (editable) and the phone's read-only SplitDiff. The primitives below + the
// per-row builder are the single source of the side-by-side look; callers inject
// an editable new-side cell and/or a per-hunk action.

const diffCellStyle = TextStyle(
  fontFamily: CcType.mono,
  fontSize: 12.5,
  height: 1.4,
  color: CcColors.text,
);

Color? diffCellBg(DiffKind kind) => switch (kind) {
  DiffKind.added => CcColors.ok.withValues(alpha: 0.10),
  DiffKind.removed => CcColors.danger.withValues(alpha: 0.10),
  DiffKind.empty => CcColors.bgGradTop.withValues(alpha: 0.5),
  DiffKind.context => null,
};

Widget diffGutter(int? no) => Container(
  width: 44,
  alignment: Alignment.topRight,
  padding: const EdgeInsets.only(right: 6, top: 1),
  color: CcColors.panel,
  child: Text(
    no?.toString() ?? '',
    style: const TextStyle(
      fontFamily: CcType.mono,
      fontSize: 11,
      color: CcColors.subtle,
    ),
  ),
);

// diffCell renders one side's line. wrap=true (desktop, Expanded cells) lets long
// lines soft-wrap within the column; wrap=false (phone, fixed-width cells) keeps
// each line on one line so the grid reads like the desktop and scrolls instead.
Widget diffCell(String text, DiffKind kind, {bool wrap = true, String? langId}) {
  final span = langId == null
      ? null
      : highlightLine(text, langId, base: diffCellStyle);
  return Container(
    color: diffCellBg(kind),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
    child: span == null
        ? Text(
            text,
            style: diffCellStyle,
            softWrap: wrap,
            maxLines: wrap ? null : 1,
          )
        : Text.rich(span, softWrap: wrap, maxLines: wrap ? null : 1),
  );
}

// fileDiffBadges renders a file's +adds / -dels counts (shared by the split
// file header and the commit/working-tree file lists).
Widget fileDiffBadges(FileDiff f) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    if (f.adds > 0)
      Text(
        '+${f.adds}',
        style: const TextStyle(color: CcColors.ok, fontSize: 11.5),
      ),
    if (f.dels > 0)
      Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Text(
          '-${f.dels}',
          style: const TextStyle(color: CcColors.danger, fontSize: 11.5),
        ),
      ),
  ],
);

// diffSplitRow renders one aligned old|new row (gutters + cells, Expanded so the
// two columns split the available width). [rightCell] overrides the new-side
// cell (the desktop's editable cell); [hunkTrailing] adds a trailing widget to
// hunk-header rows (the desktop's per-hunk 还原 button). Both default to null
// (read-only) for the phone.
Widget diffSplitRow(
  DiffRow r, {
  Widget Function(DiffRow r)? rightCell,
  Widget? Function(DiffRow r)? hunkTrailing,
  double?
  cellWidth, // null = Expanded (desktop); set = fixed-width (phone scroll)
  String? langId, // re_highlight language id for syntax coloring (null = plain)
}) {
  if (r.isHunk) {
    return Container(
      color: CcColors.accent.withValues(alpha: 0.10),
      padding: const EdgeInsets.only(left: 8, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              r.hunkText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: CcType.mono,
                fontSize: 12,
                color: CcColors.accentBright,
              ),
            ),
          ),
          ?hunkTrailing?.call(r),
        ],
      ),
    );
  }
  final wrap = cellWidth == null;
  Widget col(Widget child) =>
      wrap ? Expanded(child: child) : SizedBox(width: cellWidth, child: child);
  return IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        diffGutter(r.oldNo),
        col(diffCell(r.left, r.leftKind, wrap: wrap, langId: langId)),
        const VerticalDivider(width: 1),
        diffGutter(r.newNo),
        col(
          rightCell?.call(r) ??
              diffCell(r.right, r.rightKind, wrap: wrap, langId: langId),
        ),
      ],
    ),
  );
}

// SplitDiff is the phone's read-only side-by-side diff: the files aren't on
// disk, so everything comes from the raw unified-diff string. To read like the
// desktop, the columns are sized to the longest line (no wrapping) and the grid
// scrolls horizontally, rather than squeezing both columns into the screen.
class SplitDiff extends StatefulWidget {
  final String raw;
  // scroll=true (default): own horizontal scroll + lazy ListView. scroll=false:
  // natural-sized (no scroll) so an outer InteractiveViewer can pan/zoom it.
  final bool scroll;
  const SplitDiff(this.raw, {super.key, this.scroll = true});

  @override
  State<SplitDiff> createState() => _SplitDiffState();
}

class _SplitDiffState extends State<SplitDiff> {
  // Parsed once per raw value (so per-frame rebuilds — e.g. a terminal streaming
  // in the background — don't re-parse). Each item is a FileDiff header or a
  // DiffRow; _maxLen is the longest content line (to size the columns).
  List<Object> _items = const [];
  List<String?> _itemLang = const []; // language id per item (null = no highlight)
  int _maxLen = 0;

  @override
  void initState() {
    super.initState();
    _reparse();
  }

  @override
  void didUpdateWidget(SplitDiff old) {
    super.didUpdateWidget(old);
    if (old.raw != widget.raw) _reparse();
  }

  void _reparse() {
    final files = parseUnifiedDiff(widget.raw);
    final items = <Object>[];
    final langs = <String?>[];
    if (files.isEmpty) {
      final rows = parseRows(widget.raw);
      items.addAll(rows);
      langs.addAll(List.filled(rows.length, null));
    } else {
      for (final f in files) {
        final lang = langIdForPath(f.path);
        items.add(f);
        langs.add(null); // file header — not code
        final rows = parseRows(f.raw);
        items.addAll(rows);
        langs.addAll(List.filled(rows.length, lang));
      }
    }
    var maxLen = 0;
    for (final it in items) {
      if (it is DiffRow && !it.isHunk) {
        if (it.left.length > maxLen) maxLen = it.left.length;
        if (it.right.length > maxLen) maxLen = it.right.length;
      }
    }
    _items = items;
    _itemLang = langs;
    _maxLen = maxLen;
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    const charW = 7.8; // ~JetBrainsMono advance at 12.5px
    const chrome = 44.0 * 2 + 1; // two gutters + the divider
    final lineW = _maxLen * charW + 20;
    final cellW = lineW < 160 ? 160.0 : lineW;
    Widget rowAt(int i) {
      final it = _items[i];
      return it is FileDiff
          ? _fileHeader(it)
          : diffSplitRow(it as DiffRow, cellWidth: cellW, langId: _itemLang[i]);
    }

    final body = SizedBox(
      width: cellW * 2 + chrome,
      child: widget.scroll
          ? ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: _items.length,
              itemBuilder: (_, i) => rowAt(i),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [for (var i = 0; i < _items.length; i++) rowAt(i)],
            ),
    );
    return widget.scroll
        ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: body)
        : body;
  }

  Widget _fileHeader(FileDiff f) => Container(
    width: double.infinity,
    color: CcColors.panel,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            f.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CcType.code(size: 12),
          ),
        ),
        const SizedBox(width: 8),
        fileDiffBadges(f),
      ],
    ),
  );
}
