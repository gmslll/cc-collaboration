import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'local/prefs.dart';
import 'syntax.dart';
import 'theme.dart';

// Small UI helpers shared across screens (deduped from per-page copies).

// kIgnoredEntries are dirs/files never worth browsing — skipped by the local
// file tree and the remote-workspace file server alike.
const kIgnoredEntries = {
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

// errorText maps an exception (esp. DioException) to a short friendly message
// instead of leaking a raw stack/JSON string to the user.
String errorText(Object e) {
  if (e is DioException) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '网络超时,请重试';
      case DioExceptionType.connectionError:
        return '连不上 relay(检查网络 / 地址)';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        final body = e.response?.data;
        final msg = body is Map
            ? (body['error'] ?? body['message'])?.toString()
            : body?.toString();
        switch (code) {
          case 401:
            return '未授权(登录可能失效)';
          case 403:
            return '没有权限';
          case 404:
            return '不存在';
          case 409:
            return (msg?.isNotEmpty ?? false) ? msg! : '冲突(可能已被处理)';
        }
        return (msg?.isNotEmpty ?? false) ? msg! : '请求失败($code)';
      default:
        return e.message ?? '网络错误';
    }
  }
  return '$e';
}

void snack(
  BuildContext context,
  String message, {
  Color? background,
  Duration? duration,
  bool clearPrevious = false,
}) {
  final m = ScaffoldMessenger.of(context);
  if (clearPrevious) m.clearSnackBars();
  m.showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: background,
      duration: duration ?? const Duration(seconds: 4),
    ),
  );
}

// confirm shows a yes/no dialog; returns true only if the user confirms.
Future<bool> confirm(
  BuildContext context,
  String message, {
  String? title,
  String okLabel = '确认',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: title == null ? null : Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(okLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

// textPrompt asks for a single line of text. Returns the trimmed input, or null
// if cancelled (or left empty when allowEmpty is false).
Future<String?> textPrompt(
  BuildContext context, {
  required String title,
  String? hint,
  String initial = '',
  String okLabel = '确定',
  bool allowEmpty = false,
}) async {
  final ctl = TextEditingController(text: initial);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (_) => Navigator.pop(ctx, true),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(okLabel),
        ),
      ],
    ),
  );
  if (ok != true) return null;
  final text = ctl.text.trim();
  return (text.isEmpty && !allowEmpty) ? null : text;
}

// centerMsg is the shared muted empty/placeholder state, optionally with a retry.
Widget centerMsg(String text, {VoidCallback? onRetry}) => Center(
  child: Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: CcColors.muted, height: 1.35),
        ),
        if (onRetry != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('重试'),
          ),
        ],
      ],
    ),
  ),
);

// asyncBody renders the standard loading → spinner / error → retry / else
// content switch the data screens share.
Widget asyncBody({
  required bool loading,
  required String? error,
  required VoidCallback onRetry,
  required Widget Function() child,
}) {
  if (loading) return const Center(child: CircularProgressIndicator());
  if (error != null) return centerMsg(error, onRetry: onRetry);
  return child();
}

// tag is a small mono pill: alpha-tinted [color] background + [color] text.
Widget tag(String label, Color color, {bool bold = false}) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
  decoration: BoxDecoration(
    color: color.withValues(alpha: 0.15),
    border: Border.all(color: color.withValues(alpha: 0.30)),
    borderRadius: BorderRadius.circular(5),
  ),
  child: Text(
    label,
    style: TextStyle(
      fontFamily: CcType.mono,
      fontSize: 11.5,
      letterSpacing: 0.2,
      color: color,
      fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
    ),
  ),
);

// scrollableBar is a dense horizontal toolbar that scrolls left/right when its
// [scrolling] children don't fit, instead of overflowing (the yellow/black
// hazard stripes). [pinnedLeading]/[pinnedTrailing] stay fixed at the edges and
// never scroll. Set [alignScrollEnd] (reverse) so a trailing button cluster
// stays pinned to the right when there IS room, and reveals via scroll when not.
// NOTE: the [scrolling] list must not contain Expanded/Spacer — inside a
// horizontal scroll view the width is unbounded and flex children would throw.
Widget scrollableBar({
  List<Widget> pinnedLeading = const [],
  required List<Widget> scrolling,
  List<Widget> pinnedTrailing = const [],
  bool alignScrollEnd = false,
}) => Row(
  children: [
    ...pinnedLeading,
    Expanded(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: alignScrollEnd,
        child: Row(mainAxisSize: MainAxisSize.min, children: scrolling),
      ),
    ),
    ...pinnedTrailing,
  ],
);

// scrollableActions is a trailing button cluster for a header row that already
// has a flexible leading child (e.g. an Expanded filename): the buttons stay
// pinned to the right when there's room and scroll horizontally when the row is
// too narrow, instead of overflowing. Drop it in as a sibling of that Expanded.
Widget scrollableActions(List<Widget> children) => Flexible(
  child: SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    reverse: true,
    child: Row(mainAxisSize: MainAxisSize.min, children: children),
  ),
);

// chip is a neutral mono pill (panel bg), e.g. repo @ branch.
Widget chip(String text) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
  decoration: BoxDecoration(
    color: CcColors.panelHigh,
    border: Border.all(color: CcColors.border),
    borderRadius: BorderRadius.circular(5),
  ),
  child: Text(
    text,
    style: const TextStyle(
      fontFamily: CcType.mono,
      fontSize: 12,
      color: CcColors.text,
    ),
  ),
);

// kindBadge colors a handoff kind (delivery / request / bug).
Widget kindBadge(String kind) {
  var c = CcColors.accent;
  if (kind == 'bug') c = CcColors.danger;
  if (kind == 'request') c = CcColors.warning;
  return tag(kind, c, bold: true);
}

// relativeTime renders an ASCII age (so it's safe even in canvas text).
String relativeTime(DateTime t) {
  if (t.millisecondsSinceEpoch == 0) return '';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}

// commitDate renders a GoLand-style date column: 今天/昨天 + HH:mm for recent
// commits, M/D HH:mm within the same year, else YYYY/M/D. Manual formatting —
// no intl dependency.
String commitDate(DateTime t) {
  if (t.millisecondsSinceEpoch == 0) return '';
  String two(int n) => n < 10 ? '0$n' : '$n';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final hm = '${two(t.hour)}:${two(t.minute)}';
  final diffDays = today.difference(day).inDays;
  if (diffDays == 0) return '今天 $hm';
  if (diffDays == 1) return '昨天 $hm';
  if (t.year == now.year) return '${t.month}/${t.day} $hm';
  return '${t.year}/${t.month}/${t.day}';
}

// hostOf strips the scheme + trailing slash from a URL for compact display.
String hostOf(String url) {
  var s = url;
  final i = s.indexOf('://');
  if (i >= 0) s = s.substring(i + 3);
  return s.replaceAll(RegExp(r'/+$'), '');
}

Widget sectionTitle(String title, {String? meta, IconData? icon}) => Row(
  children: [
    if (icon != null) ...[
      Icon(icon, size: 18, color: CcColors.accent),
      const SizedBox(width: 8),
    ],
    Text(
      title,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
    ),
    if (meta != null) ...[
      const SizedBox(width: 8),
      Text(
        meta,
        style: const TextStyle(
          fontFamily: CcType.mono,
          color: CcColors.muted,
          fontSize: 12.5,
        ),
      ),
    ],
  ],
);

// collapseRail is the thin (~40px) bar shown in place of a collapsed panel: an
// expand button + an optional vertical label. Click to bring the panel back.
Widget collapseRail({
  required IconData icon,
  required String tooltip,
  required VoidCallback onExpand,
  String? label,
}) => Container(
  width: 40,
  decoration: const BoxDecoration(
    color: CcColors.panel,
    border: Border(right: BorderSide(color: CcColors.border)),
  ),
  child: Column(
    children: [
      const SizedBox(height: 6),
      IconButton(
        icon: Icon(icon, size: 18),
        tooltip: tooltip,
        onPressed: onExpand,
      ),
      if (label != null)
        Expanded(
          child: RotatedBox(
            quarterTurns: 1,
            child: Center(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: CcColors.muted,
                  fontSize: 11,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),
        ),
    ],
  ),
);

// statusDot is a small filled circle, optionally with a soft glow (for online /
// active / urgent indicators).
Widget statusDot(Color color, {double size = 8, bool glow = false}) =>
    Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: glow
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.7),
                  blurRadius: 6,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
    );

// diffText renders a unified-diff string with +/− line coloring (mono), lazily
// via ListView so big diffs stay smooth. Shared by the local git diff viewer
// and the GitHub PR view (PR file `patch`). Pass [scrollable]=false to embed in
// an outer scroll (renders a non-lazy Column instead).
Widget diffText(String diff, {bool scrollable = true, bool highlight = false}) {
  final lines = diff.split('\n');
  // When highlight is on, resolve each line's language up front (the file can
  // change mid-diff via `diff --git`/`+++` headers) so lazy items stay correct.
  final langs = highlight ? _lineLanguages(lines) : null;
  if (!scrollable) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < lines.length; i++)
          _diffLine(lines[i], langId: langs?[i]),
      ],
    );
  }
  return ListView.builder(
    itemCount: lines.length,
    itemBuilder: (_, i) => _diffLine(lines[i], langId: langs?[i]),
  );
}

// _lineLanguages tags each unified-diff line with the current file's language id
// (tracked from `diff --git a/.. b/<path>` and `+++ b/<path>` headers).
List<String?> _lineLanguages(List<String> lines) {
  final out = List<String?>.filled(lines.length, null);
  String? cur;
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (l.startsWith('diff --git ')) {
      final m = RegExp(r' b/(.+)$').firstMatch(l);
      cur = m == null ? null : langIdForPath(m.group(1)!);
    } else if (l.startsWith('+++ b/')) {
      cur = langIdForPath(l.substring('+++ b/'.length));
    }
    out[i] = cur;
  }
  return out;
}

Widget _diffLine(String line, {String? langId}) {
  const baseStyle = TextStyle(
    fontFamily: CcType.mono,
    fontSize: 12.5,
    height: 1.4,
    color: CcColors.text,
  );
  Color fg = CcColors.text; // context
  Color? bg;
  bool isCode = false; // a +/-/context content line (highlightable)
  // Order matters: file-header checks (+++/---) must precede the +/- checks.
  if (line.startsWith('@@')) {
    fg = CcColors.accentBright;
  } else if (line.startsWith('+++') ||
      line.startsWith('---') ||
      line.startsWith('diff ') ||
      line.startsWith('index ') ||
      line.startsWith('new file') ||
      line.startsWith('deleted file') ||
      line.startsWith('similarity ') ||
      line.startsWith('rename ') ||
      line.startsWith('\\')) {
    fg = CcColors.subtle; // file headers / "No newline"
  } else if (line.startsWith('+')) {
    fg = CcColors.ok;
    bg = CcColors.ok.withValues(alpha: 0.06);
    isCode = true;
  } else if (line.startsWith('-')) {
    fg = CcColors.danger;
    bg = CcColors.danger.withValues(alpha: 0.06);
    isCode = true;
  } else {
    isCode = true; // context line (leading space)
  }
  final Widget child;
  if (isCode && langId != null) {
    // keep the +/- prefix in the line color, syntax-highlight the rest.
    final prefix = line.isEmpty ? ' ' : line.substring(0, 1);
    final content = line.isEmpty ? '' : line.substring(1);
    final span = highlightLine(content, langId, base: baseStyle);
    child = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: prefix, style: baseStyle.copyWith(color: fg)),
          span ?? TextSpan(text: content, style: baseStyle),
        ],
      ),
    );
  } else {
    child = Text(line.isEmpty ? ' ' : line, style: baseStyle.copyWith(color: fg));
  }
  return Container(
    color: bg,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
    child: child,
  );
}

// highlightedCode is a read-only, syntax-highlighted code viewer (line-numbered,
// lazy ListView). Pure Dart/Flutter (+ syntax.dart) so it works on phone & web —
// the remote clients can't use the desktop re_editor. Pass [langId] from
// langIdForPath(path); null/unknown → plain mono text.
Widget highlightedCode(String text, String? langId) {
  final lines = text.split('\n');
  const baseStyle = TextStyle(
    fontFamily: CcType.mono,
    fontSize: 12.5,
    height: 1.4,
    color: CcColors.text,
  );
  return ListView.builder(
    itemCount: lines.length,
    itemBuilder: (_, i) {
      final line = lines[i];
      final span = (langId == null || line.isEmpty)
          ? null
          : highlightLine(line, langId, base: baseStyle);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 40,
              child: Text(
                '${i + 1}',
                textAlign: TextAlign.right,
                style: baseStyle.copyWith(color: CcColors.subtle),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: span != null
                  ? Text.rich(span)
                  : Text(line.isEmpty ? ' ' : line, style: baseStyle),
            ),
          ],
        ),
      );
    },
  );
}

// Subtle gradients for surfaces (the "稍多表现力" lift, kept understated).
const appGradient = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [CcColors.bgGradTop, CcColors.bg],
  ),
);

const panelGradient = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [CcColors.panelHigh, CcColors.panel],
  ),
);

// DragHandle is a thin vertical divider the user drags to resize an adjacent
// pane. It reports the horizontal drag delta; the parent clamps + persists the
// new width. Shows a resize cursor and an accent line on hover/drag. (8px hit
// area for an easy grab; the visible line stays 1–2px.)
class DragHandle extends StatefulWidget {
  final ValueChanged<double> onDelta;
  final VoidCallback? onEnd; // e.g. persist the new width once, on release
  const DragHandle({super.key, required this.onDelta, this.onEnd});

  @override
  State<DragHandle> createState() => _DragHandleState();
}

class _DragHandleState extends State<DragHandle> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final noMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _active = true),
      onExit: (_) => setState(() => _active = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => widget.onDelta(d.delta.dx),
        onHorizontalDragEnd: (_) => widget.onEnd?.call(),
        child: SizedBox(
          width: 8,
          child: Center(
            child: AnimatedContainer(
              duration: noMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              width: _active ? 2 : 1,
              color: _active ? CcColors.accent : CcColors.border,
            ),
          ),
        ),
      ),
    );
  }
}

// resizeHandle is a DragHandle pre-wired to clamp + persist a pane width: it
// reads/writes the width via [get]/[set] (set should setState), clamps to
// [min]/[max], and persists to Prefs[prefKey] on release. [invert] flips the
// drag direction for a pane sitting to the LEFT of the handle (drag toward it =
// wider). Collapses the per-cockpit resize boilerplate to one call per handle.
Widget resizeHandle({
  required String prefKey,
  required double Function() get,
  required ValueChanged<double> set,
  required double min,
  required double max,
  bool invert = false,
}) => DragHandle(
  onDelta: (dx) => set((get() + (invert ? -dx : dx)).clamp(min, max)),
  onEnd: () => Prefs.setDouble(prefKey, get()),
);

// BlinkingCaret is a terminal-style block cursor — blinks ~1s on/off, honors
// reduced-motion (stays solid). Used in the empty-terminal "prompt" placeholder.
class BlinkingCaret extends StatefulWidget {
  final Color color;
  final double width;
  final double height;
  const BlinkingCaret({
    super.key,
    this.color = CcColors.accentBright,
    this.width = 8,
    this.height = 17,
  });

  @override
  State<BlinkingCaret> createState() => _BlinkingCaretState();
}

class _BlinkingCaretState extends State<BlinkingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1060),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: widget.width,
      height: widget.height,
      color: widget.color,
    );
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return box;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) =>
          Opacity(opacity: _c.value < 0.5 ? 1 : 0, child: child),
      child: box,
    );
  }
}

// HoverLift wraps a card-like surface: on hover it lifts slightly, brightens its
// border and casts a soft accent glow (200ms). Use for clickable cards.
class HoverLift extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  const HoverLift({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(14),
  });

  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final noMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: noMotion
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _h ? -1.5 : 0, 0),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: CcColors.panel,
            borderRadius: BorderRadius.circular(CcRadius.md),
            border: Border.all(
              color: _h
                  ? CcColors.accent.withValues(alpha: 0.5)
                  : CcColors.borderSoft,
            ),
            boxShadow: _h
                ? [
                    BoxShadow(
                      color: CcColors.accent.withValues(alpha: 0.16),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

// splitFileNameDir splits a path into (fileName, dirPath); dirPath is '' if none.
(String, String) splitFileNameDir(String path) {
  final i = path.lastIndexOf('/');
  return (
    i < 0 ? path : path.substring(i + 1),
    i < 0 ? '' : path.substring(0, i),
  );
}

// ccMenuItem is the shared JetBrains/GoLand-style popup-menu row: a leading icon,
// the label, and an optional right-aligned keyboard-shortcut hint. value == null
// (or enabled == false) renders a disabled row; danger tints it red. Used by every
// right-click / popup menu so they read consistently.
PopupMenuItem<String> ccMenuItem({
  required String? value,
  required IconData icon,
  required String label,
  String? shortcut,
  bool danger = false,
  bool? enabled,
}) {
  final on = enabled ?? (value != null);
  final color = !on
      ? CcColors.subtle
      : danger
      ? CcColors.danger
      : CcColors.muted;
  return PopupMenuItem<String>(
    value: value,
    enabled: on,
    height: 34,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: danger && on ? const TextStyle(color: CcColors.danger) : null,
          ),
        ),
        if (shortcut != null) ...[
          const SizedBox(width: 18),
          Text(shortcut, style: CcType.code(size: 11, color: CcColors.subtle)),
        ],
      ],
    ),
  );
}

// SendTarget is one "send to session" menu target: a session id + its label.
typedef SendTarget = ({String id, String label});

// sendMenuEntries builds the first-level "发送到会话" rows: same-project targets
// inline, then a "其他会话 ▸" row (value 'send-others') when there are
// other-project targets. Each target is value 'send:<id>'.
List<PopupMenuEntry<String>> sendMenuEntries(
  List<SendTarget> same,
  List<SendTarget> others, {
  bool enabled = true,
}) => [
  for (final t in same)
    ccMenuItem(
      value: 'send:${t.id}',
      icon: Icons.send_rounded,
      label: '发送到「${t.label}」',
      enabled: enabled,
    ),
  if (others.isNotEmpty)
    ccMenuItem(
      value: 'send-others',
      icon: Icons.more_horiz_rounded,
      label: '其他会话 ▸',
      enabled: enabled,
    ),
];

// showGroupedSendMenu shows the grouped send picker at [globalPos] and returns
// the chosen session id as 'send:<id>' (or one of [extraTop]'s values, or null).
// Same-project targets are inline; picking "其他会话" cascades a second menu of
// other-project targets — Flutter's showMenu has no native submenu. [extraTop]
// rows (e.g. the terminal's copy/paste/全选) render above a divider; [extraBottom]
// rows (e.g. "发送到在线用户…") render below the local targets.
Future<String?> showGroupedSendMenu(
  BuildContext context,
  Offset globalPos, {
  required List<SendTarget> same,
  required List<SendTarget> others,
  List<PopupMenuEntry<String>> extraTop = const [],
  List<PopupMenuEntry<String>> extraBottom = const [],
}) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  RelativeRect posAt(Offset p) =>
      RelativeRect.fromRect(p & const Size(1, 1), Offset.zero & overlay.size);
  final sendItems = sendMenuEntries(same, others);
  final v = await showMenu<String>(
    context: context,
    position: posAt(globalPos),
    items: [
      ...extraTop,
      if (extraTop.isNotEmpty && (sendItems.isNotEmpty || extraBottom.isNotEmpty))
        const PopupMenuDivider(),
      ...sendItems,
      if (extraBottom.isNotEmpty && sendItems.isNotEmpty)
        const PopupMenuDivider(),
      ...extraBottom,
    ],
  );
  if (v != 'send-others') return v; // 'send:<id>', an extraTop value, or null
  if (!context.mounted) return null;
  return showMenu<String>(
    context: context,
    position: posAt(globalPos),
    items: [
      for (final t in others)
        ccMenuItem(
          value: 'send:${t.id}',
          icon: Icons.send_rounded,
          label: '发送到「${t.label}」',
        ),
    ],
  );
}

// fileNameDirLabel renders a path as filename (left) + small gray directory —
// shared by the desktop commit panel and the phone change / commit-file rows.
Widget fileNameDirLabel(String path) {
  final (name, dir) = splitFileNameDir(path);
  return Row(
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Flexible(
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: CcType.code(size: 12.5),
        ),
      ),
      if (dir.isNotEmpty) ...[
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            dir,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CcType.code(size: 10.5, color: CcColors.subtle),
          ),
        ),
      ],
    ],
  );
}
