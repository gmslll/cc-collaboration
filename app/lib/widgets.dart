import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'local/hook_activity.dart';
import 'local/prefs.dart';
import 'local/path_utils.dart';
import 'local/session_overview.dart';
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

OverlayEntry? _topSnackEntry;
Timer? _topSnackTimer;

void _removeTopSnack() {
  _topSnackTimer?.cancel();
  _topSnackTimer = null;
  final entry = _topSnackEntry;
  _topSnackEntry = null;
  entry?.remove();
}

void snack(
  BuildContext context,
  String message, {
  Color? background,
  Duration? duration,
  bool clearPrevious = false,
}) {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  _removeTopSnack();
  final d = duration ?? const Duration(seconds: 4);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => Positioned(
      bottom: MediaQuery.paddingOf(ctx).bottom + 16,
      left: 12,
      right: 12,
      child: _TopSnack(
        message: message,
        background: background,
        onClose: () {
          if (_topSnackEntry == entry) _removeTopSnack();
        },
      ),
    ),
  );
  _topSnackEntry = entry;
  overlay.insert(entry);
  _topSnackTimer = Timer(d, () {
    if (_topSnackEntry == entry) _removeTopSnack();
  });
}

class _TopSnack extends StatelessWidget {
  final String message;
  final Color? background;
  final VoidCallback onClose;

  const _TopSnack({
    required this.message,
    required this.background,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: background ?? const Color(0xF0181B20),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x33FFFFFF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: CcColors.text, fontSize: 13),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                tooltip: '关闭',
                padding: EdgeInsets.zero,
                iconSize: 18,
                color: CcColors.muted,
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
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

// --- session overview (会话总览) shared card bits ---------------------------
//
// The desktop overview page and the phone overview grid render the same card
// shell differently (the desktop has hierarchy headers + a fixed width; the
// phone adds a path subtitle + a ⋮ menu + a flexible width), but these inner
// leaves — the status colour, the status row, and the preview pane — are
// identical, so they live here and both compose them.

// sessionStatusStyle maps a SessionStatus to its dot/label colour, glowing for
// the attention states (working / needs-review).
({Color color, bool glow}) sessionStatusStyle(SessionStatus s) => switch (s) {
  SessionStatus.working => (color: CcColors.accentBright, glow: true),
  SessionStatus.runningTool => (color: CcColors.accentBright, glow: true),
  SessionStatus.toolDone => (color: CcColors.ok, glow: true),
  SessionStatus.toolFailed => (color: CcColors.danger, glow: true),
  SessionStatus.waitingPermission => (color: CcColors.warning, glow: true),
  SessionStatus.compacting => (color: CcColors.accent, glow: true),
  SessionStatus.subagent => (color: CcColors.accent, glow: true),
  SessionStatus.needsReview => (color: CcColors.warning, glow: true),
  SessionStatus.waitingInput => (color: CcColors.muted, glow: false),
  SessionStatus.idle => (color: CcColors.ok, glow: false),
  SessionStatus.shell => (color: CcColors.subtle, glow: false),
};

// sessionStatusRow is the status line + (when present) the full token-usage
// label on its OWN line below it — usage (model · ctx% · tokens · cost) is too
// long to share the status row without being truncated, so it gets the full card
// width and may wrap to 2 lines. A `working` session animates (breathing dot +
// cycling 思考中… ellipsis); the calmer states stay static.
Widget sessionStatusRow(
  SessionStatus status,
  String? usageLabel, {
  String statusDetail = '',
}) {
  final st = sessionStatusStyle(status);
  final Widget statusPart = sessionStatusIsActive(status)
      ? _WorkingIndicator(label: statusLabel(status), color: st.color)
      : Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            statusDot(st.color, glow: st.glow),
            const SizedBox(width: 6),
            Text(
              statusLabel(status),
              style: TextStyle(
                color: st.color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
  final detail = statusDetail.trim();
  if ((usageLabel == null || usageLabel.isEmpty) && detail.isEmpty) {
    return Align(alignment: Alignment.centerLeft, child: statusPart);
  }
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      statusPart,
      if (detail.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(
          detail,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: CcColors.muted, fontSize: 11),
        ),
      ],
      if (usageLabel != null && usageLabel.isNotEmpty) ...[
        const SizedBox(height: 5),
        Text(
          usageLabel,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: CcType.code(size: 10.5, color: CcColors.muted),
        ),
      ],
    ],
  );
}

// _WorkingIndicator is the animated active status: a breathing glow dot and a
// cycling 0-3 dot ellipsis (in a fixed-width box so the row doesn't reflow each
// frame). Honours the platform reduce-motion setting (falls back to a static
// glow dot + label).
class _WorkingIndicator extends StatefulWidget {
  final String label;
  final Color color;
  const _WorkingIndicator({required this.label, required this.color});

  @override
  State<_WorkingIndicator> createState() => _WorkingIndicatorState();
}

class _WorkingIndicatorState extends State<_WorkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color;
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          statusDot(color, glow: true),
          const SizedBox(width: 6),
          Text(
            widget.label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final pulse = 1 - (2 * _c.value - 1).abs(); // triangle 0→1→0
        final dots = (_c.value * 4).floor() % 4; // 0,1,2,3 cycling
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.25 + 0.55 * pulse),
                    blurRadius: 3 + 7 * pulse,
                    spreadRadius: 0.6 * pulse,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Text(
              widget.label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(
              width: 14, // reserve 3 dots so the row width stays stable
              child: Text(
                '.' * dots,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// BreathingGlow wraps a card with a soft, slowly-pulsing outer glow while
// [active] (used to make a "working" session pop in the overview grid). Zero
// overhead when inactive (returns the child untouched); a static glow under
// reduce-motion. The [radius] should match the wrapped card's corner radius so
// the glow hugs its shape.
class BreathingGlow extends StatefulWidget {
  final Widget child;
  final bool active;
  final Color color;
  final double radius;
  const BreathingGlow({
    super.key,
    required this.child,
    required this.active,
    this.color = CcColors.accent,
    this.radius = CcRadius.md,
  });

  @override
  State<BreathingGlow> createState() => _BreathingGlowState();
}

class _BreathingGlowState extends State<BreathingGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      if (_c.isAnimating) _c.stop();
      return widget.child;
    }
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final radius = BorderRadius.circular(widget.radius);
    if (reduce) {
      if (_c.isAnimating) _c.stop();
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.22),
              blurRadius: 16,
              spreadRadius: 0.5,
            ),
          ],
        ),
        child: widget.child,
      );
    }
    if (!_c.isAnimating) _c.repeat(reverse: true); // 0→1→0 breathing
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) {
        final t = _c.value;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.12 + 0.30 * t),
                blurRadius: 10 + 16 * t,
                spreadRadius: 0.5 + 1.5 * t,
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

// sessionPreviewBox is the bordered monospace pane showing an agent's latest
// reply (or a muted placeholder when there's nothing yet).
Widget sessionPreviewBox(String preview, {double height = 100}) {
  final empty = preview.trim().isEmpty;
  return Container(
    width: double.infinity,
    height: height,
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: CcColors.bg.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(CcRadius.sm),
      border: Border.all(color: CcColors.borderSoft),
    ),
    child: Text(
      empty ? '（暂无输出）' : preview,
      maxLines: 6,
      overflow: TextOverflow.ellipsis,
      style: CcType.code(
        size: 11,
        color: empty ? CcColors.subtle : CcColors.muted,
      ),
    ),
  );
}

Widget sessionActivityList(List<HookActivity> items, {int take = 3}) {
  if (items.isEmpty) {
    return const SizedBox.shrink();
  }
  return _SessionActivityDisclosure(items: items, take: take);
}

class _SessionActivityDisclosure extends StatefulWidget {
  final List<HookActivity> items;
  final int take;

  const _SessionActivityDisclosure({required this.items, required this.take});

  @override
  State<_SessionActivityDisclosure> createState() =>
      _SessionActivityDisclosureState();
}

class _SessionActivityDisclosureState
    extends State<_SessionActivityDisclosure> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final shown = widget.items.take(widget.take).toList();
    if (shown.isEmpty) {
      return const SizedBox.shrink();
    }
    if (!_expanded) {
      return Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          borderRadius: BorderRadius.circular(CcRadius.sm),
          onTap: () => setState(() => _expanded = true),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.bolt_rounded,
                  size: 12,
                  color: CcColors.subtle,
                ),
                const SizedBox(width: 5),
                Text(
                  '执行记录 ${widget.items.length}',
                  style: CcType.code(size: 10.5, color: CcColors.subtle),
                ),
                const SizedBox(width: 3),
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 14,
                  color: CcColors.subtle,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return _sessionActivityPanel(
      shown,
      total: widget.items.length,
      onCollapse: () => setState(() => _expanded = false),
    );
  }
}

Widget _sessionActivityPanel(
  List<HookActivity> shown, {
  required int total,
  required VoidCallback onCollapse,
}) {
  if (shown.isEmpty) {
    return const SizedBox.shrink();
  }
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
    decoration: BoxDecoration(
      color: CcColors.bg.withValues(alpha: 0.28),
      borderRadius: BorderRadius.circular(CcRadius.sm),
      border: Border.all(color: CcColors.borderSoft),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.bolt_rounded, size: 12, color: CcColors.subtle),
            const SizedBox(width: 5),
            Text(
              '执行记录 $total',
              style: CcType.code(size: 10.5, color: CcColors.subtle),
            ),
            const Spacer(),
            SizedBox(
              width: 20,
              height: 20,
              child: IconButton(
                tooltip: '收起执行记录',
                padding: EdgeInsets.zero,
                iconSize: 14,
                color: CcColors.subtle,
                onPressed: onCollapse,
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        for (final a in shown) _sessionActivityLine(a),
      ],
    ),
  );
}

Widget _sessionActivityLine(HookActivity a) {
  final detail = a.detail.trim();
  return Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 36,
          child: Text(
            _activityClock(a.at),
            style: CcType.code(size: 9.5, color: CcColors.subtle),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                a.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: CcColors.muted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (detail.isNotEmpty)
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 9.5, color: CcColors.subtle),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

String _activityClock(DateTime t) {
  final h = t.hour.toString().padLeft(2, '0');
  final m = t.minute.toString().padLeft(2, '0');
  final s = t.second.toString().padLeft(2, '0');
  return '$h:$m:$s';
}

// --- robot avatar (per-session generated icon) -----------------------------
//
// Each agent session gets a little robot drawn deterministically from its
// session id: same id → same robot, on the desktop and the mirrored phone alike
// (a stable FNV-1a hash, not String.hashCode which isn't guaranteed identical
// across runs/platforms). "Random at creation" falls out of ids being minted in
// sequence (ts0, ts1, …). Eight colours × a few eye/antenna/mouth variants give
// plenty of distinct faces so sessions are tellable apart at a glance.

const List<Color> _robotPalette = [
  Color(0xFF7EB1FF), // blue
  Color(0xFF6AAB73), // green
  Color(0xFFFFC66D), // amber
  Color(0xFFFF8FA3), // pink
  Color(0xFFB388FF), // purple
  Color(0xFF4DD0E1), // cyan
  Color(0xFFFFB74D), // orange
  Color(0xFF9CCC65), // lime
  Color(0xFFF06292), // rose
  Color(0xFF4DB6AC), // teal
  Color(0xFFBA68C8), // violet
  Color(0xFFFFD54F), // yellow
  Color(0xFFA1887F), // taupe
  Color(0xFF90A4AE), // steel
  Color(0xFFFF7043), // coral
  Color(0xFF7986CB), // indigo
];

int _fnv1a(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h;
}

// sessionAvatar is a session's leading glyph: a generated robot for an AI agent
// (distinct per session id), a terminal glyph for a plain shell. Both occupy the
// same [size] box so rows line up.
Widget sessionAvatar({
  required String seed,
  required bool isAgent,
  double size = 26,
}) => isAgent
    ? RobotAvatar(seed, size: size)
    : SizedBox(
        width: size,
        height: size,
        child: Icon(
          Icons.terminal_rounded,
          size: size * 0.66,
          color: CcColors.accentBright,
        ),
      );

// SessionActivityAvatar wraps sessionAvatar with a LIVE activity indicator for the
// workspace session tree, so you can tell at a glance whether an AI session is
// working, idle, or done. It adds a small status-coloured badge dot in the lower-
// right (idle / waiting / needs-review / working, via sessionStatusStyle) and —
// while the session is actively working — a soft breathing glow behind the whole
// avatar so a busy session visibly pulses; calm states stay static. Honours reduce-
// motion (a steady glow, no pulse). Rebuild it by wrapping in a ValueListenableBuilder
// on the session's activityRev (which bumps on every busy / needs-review transition).
class SessionActivityAvatar extends StatefulWidget {
  final String seed;
  final bool isAgent;
  final SessionStatus status;
  final double size;
  const SessionActivityAvatar({
    super.key,
    required this.seed,
    required this.isAgent,
    required this.status,
    this.size = 20,
  });

  @override
  State<SessionActivityAvatar> createState() => _SessionActivityAvatarState();
}

class _SessionActivityAvatarState extends State<SessionActivityAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = sessionStatusStyle(widget.status);
    final active = sessionStatusIsActive(
      widget.status,
    ); // working / running / …
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final animate = active && !reduce;
    // Start/stop the repeat in build (same pattern as BreathingGlow) so the pulse
    // only runs while the session is working — zero animation cost when idle.
    if (animate) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else if (_c.isAnimating) {
      _c.stop();
    }
    final glyph = sessionAvatar(
      seed: widget.seed,
      isAgent: widget.isAgent,
      size: widget.size,
    );
    final badge = widget.size * 0.4;
    // The badge sits on a panel-coloured ring so it reads against the avatar tile.
    // It glows only for a static attention state (needs-review) — while working the
    // surrounding halo already pulses, so the dot itself stays solid.
    final badgeDot = Container(
      padding: const EdgeInsets.all(1.4),
      decoration: const BoxDecoration(
        color: CcColors.panel,
        shape: BoxShape.circle,
      ),
      child: statusDot(st.color, size: badge, glow: st.glow && !active),
    );
    final radius = BorderRadius.circular(widget.size * 0.28);
    // No outer SizedBox: a loose Stack sizes to its only non-positioned child
    // (glyph, which is already size×size), so the halo (Positioned.fill) and badge
    // anchor identically.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (active)
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, _) {
                // Breathing 0→1→0 while animating; a steady mid-glow otherwise
                // (reduce-motion), so a working session still stands out.
                final p = animate ? _c.value : 0.55;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    boxShadow: [
                      BoxShadow(
                        color: st.color.withValues(alpha: 0.16 + 0.42 * p),
                        blurRadius: 3 + 7 * p,
                        spreadRadius: 0.4 + 1.4 * p,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        glyph,
        Positioned(right: 0, bottom: 0, child: badgeDot),
      ],
    );
  }
}

class RobotAvatar extends StatelessWidget {
  final String seed;
  final double size;
  const RobotAvatar(this.seed, {super.key, this.size = 26});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _RobotPainter(seed));
}

class _RobotPainter extends CustomPainter {
  final String seed;
  _RobotPainter(this.seed);

  @override
  void paint(Canvas canvas, Size size) {
    final h = _fnv1a(seed);
    // Disjoint bit slices so colour/eyes/antenna/mouth vary independently.
    final color = _robotPalette[h % _robotPalette.length]; // bits 0-3
    final eyeStyle = (h >> 4) % 4; // bits 4-5
    final antennaStyle = (h >> 6) % 2; // bit 6
    final mouthStyle = (h >> 7) % 4; // bits 7-8
    final s = size.width;
    double u(double f) => f * s; // fraction of the box → px

    // rounded background tile (avatar chip)
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(u(0.22))),
      Paint()..color = color.withValues(alpha: 0.16),
    );

    final fill = Paint()..color = color;
    final cut = Paint()..color = CcColors.bg; // eye/mouth cut-outs

    // antenna(s)
    final stroke = Paint()
      ..color = color
      ..strokeWidth = u(0.05)
      ..strokeCap = StrokeCap.round;
    if (antennaStyle == 0) {
      canvas.drawLine(Offset(u(0.5), u(0.13)), Offset(u(0.5), u(0.3)), stroke);
      canvas.drawCircle(Offset(u(0.5), u(0.12)), u(0.055), fill);
    } else {
      canvas.drawLine(
        Offset(u(0.35), u(0.16)),
        Offset(u(0.41), u(0.3)),
        stroke,
      );
      canvas.drawLine(
        Offset(u(0.65), u(0.16)),
        Offset(u(0.59), u(0.3)),
        stroke,
      );
      canvas.drawCircle(Offset(u(0.35), u(0.15)), u(0.045), fill);
      canvas.drawCircle(Offset(u(0.65), u(0.15)), u(0.045), fill);
    }

    // head + side ears
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(u(0.18), u(0.3), u(0.82), u(0.85)),
        Radius.circular(u(0.16)),
      ),
      fill,
    );
    for (final earX in [
      Rect.fromLTRB(u(0.11), u(0.46), u(0.18), u(0.64)),
      Rect.fromLTRB(u(0.82), u(0.46), u(0.89), u(0.64)),
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(earX, Radius.circular(u(0.03))),
        fill,
      );
    }

    // eyes
    const eyeY = 0.52;
    final lx = u(0.37), rx = u(0.63), ey = u(eyeY);
    if (eyeStyle == 0) {
      canvas.drawCircle(Offset(lx, ey), u(0.07), cut);
      canvas.drawCircle(Offset(rx, ey), u(0.07), cut);
    } else if (eyeStyle == 1) {
      for (final x in [lx, rx]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(x, ey),
              width: u(0.14),
              height: u(0.14),
            ),
            Radius.circular(u(0.02)),
          ),
          cut,
        );
      }
    } else if (eyeStyle == 2) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(u(0.3), u(0.46), u(0.7), u(0.58)),
          Radius.circular(u(0.06)),
        ),
        cut,
      );
    } else {
      // sleepy: two short horizontal dashes
      for (final x in [lx, rx]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(x, ey),
              width: u(0.15),
              height: u(0.045),
            ),
            Radius.circular(u(0.02)),
          ),
          cut,
        );
      }
    }

    // mouth (style 2 → none, eyes-only)
    final my = u(0.71);
    if (mouthStyle == 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(u(0.37), my, u(0.63), u(0.76)),
          Radius.circular(u(0.02)),
        ),
        cut,
      );
    } else if (mouthStyle == 1) {
      for (var i = 0; i < 3; i++) {
        canvas.drawRect(
          Rect.fromLTWH(u(0.38) + i * u(0.09), my, u(0.06), u(0.06)),
          cut,
        );
      }
    } else if (mouthStyle == 3) {
      // smile: lower half of an ellipse (0 → π sweeps the bottom arc)
      canvas.drawArc(
        Rect.fromLTRB(u(0.38), u(0.62), u(0.62), u(0.8)),
        0,
        3.14159,
        false,
        Paint()
          ..color = CcColors.bg
          ..style = PaintingStyle.stroke
          ..strokeWidth = u(0.05)
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_RobotPainter old) => old.seed != seed;
}

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
    // expand leading tabs (after the +/- prefix) so tab-indented code shows indent
    final content = expandLeadingTabs(line.isEmpty ? '' : line.substring(1));
    final span = highlightLine(content, langId, base: baseStyle);
    child = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: prefix,
            style: baseStyle.copyWith(color: fg),
          ),
          span ?? TextSpan(text: content, style: baseStyle),
        ],
      ),
    );
  } else {
    child = Text(
      line.isEmpty ? ' ' : line,
      style: baseStyle.copyWith(color: fg),
    );
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
      final line = expandLeadingTabs(lines[i]);
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

// DragHandle is a thin divider the user drags to resize an adjacent pane. By
// default it's a vertical line reporting horizontal drag delta (for
// left/right panes); pass [vertical]: true for a horizontal line reporting
// vertical drag delta (for stacked top/bottom panes) instead. The parent
// clamps + persists the new size. Shows a resize cursor and an accent line on
// hover/drag. (8px hit area for an easy grab; the visible line stays 1–2px.)
class DragHandle extends StatefulWidget {
  final ValueChanged<double> onDelta;
  final VoidCallback? onEnd; // e.g. persist the new width once, on release
  final bool vertical;
  const DragHandle({
    super.key,
    required this.onDelta,
    this.onEnd,
    this.vertical = false,
  });

  @override
  State<DragHandle> createState() => _DragHandleState();
}

class _DragHandleState extends State<DragHandle> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final noMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final line = AnimatedContainer(
      duration: noMotion ? Duration.zero : const Duration(milliseconds: 120),
      width: widget.vertical ? null : (_active ? 2 : 1),
      height: widget.vertical ? (_active ? 2 : 1) : null,
      color: _active ? CcColors.accent : CcColors.border,
    );
    return MouseRegion(
      cursor: widget.vertical
          ? SystemMouseCursors.resizeRow
          : SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _active = true),
      onExit: (_) => setState(() => _active = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: widget.vertical
            ? null
            : (d) => widget.onDelta(d.delta.dx),
        onHorizontalDragEnd: widget.vertical
            ? null
            : (_) => widget.onEnd?.call(),
        onVerticalDragUpdate: widget.vertical
            ? (d) => widget.onDelta(d.delta.dy)
            : null,
        onVerticalDragEnd: widget.vertical ? (_) => widget.onEnd?.call() : null,
        child: widget.vertical
            ? SizedBox(height: 8, child: Center(child: line))
            : SizedBox(width: 8, child: Center(child: line)),
      ),
    );
  }
}

// resizeHandle is a DragHandle pre-wired to clamp + persist a pane size: it
// reads/writes the size via [get]/[set] (set should setState), clamps to
// [min]/[max], and persists to Prefs[prefKey] on release. [invert] flips the
// drag direction for a pane sitting to the LEFT (or, when [vertical], ABOVE)
// the handle (drag toward it = bigger). [vertical] passes through to
// DragHandle for a stacked top/bottom layout instead of side-by-side.
// Collapses the per-cockpit resize boilerplate to one call per handle.
Widget resizeHandle({
  required String prefKey,
  required double Function() get,
  required ValueChanged<double> set,
  required double min,
  required double max,
  bool invert = false,
  bool vertical = false,
}) => DragHandle(
  vertical: vertical,
  onDelta: (delta) => set((get() + (invert ? -delta : delta)).clamp(min, max)),
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
  return splitPathNameDir(path);
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
    height: 24,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: Row(
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: danger && on
                ? const TextStyle(color: CcColors.danger)
                : null,
          ),
        ),
        if (shortcut != null) ...[
          const SizedBox(width: 12),
          Text(shortcut, style: CcType.code(size: 10, color: CcColors.subtle)),
        ],
      ],
    ),
  );
}

// SendTarget is one "send to session" menu target: a session id + its label.
typedef SendTarget = ({String id, String label});

// sendMenuEntries builds the first-level "发送到会话" rows: same-project targets
// inline while the list is short. Long same-project lists collapse behind
// "当前项目会话 ▸" (value 'send-same'), then a "其他会话 ▸" row (value
// 'send-others') when there are other-project targets. Each inline target is
// value 'send:<id>'.
List<PopupMenuEntry<String>> sendMenuEntries(
  List<SendTarget> same,
  List<SendTarget> others, {
  bool enabled = true,
  int inlineLimit = 6,
}) => [
  if (same.length > inlineLimit)
    ccMenuItem(
      value: 'send-same',
      icon: Icons.folder_rounded,
      label: '当前项目会话 (${same.length}) ▸',
      enabled: enabled,
    )
  else
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
      label: '其他会话 (${others.length}) ▸',
      enabled: enabled,
    ),
];

// showGroupedSendMenu shows the grouped send picker at [globalPos] and returns
// the chosen session id as 'send:<id>' (or one of [extraTop]'s values, or null).
// Same-project targets are inline while short; long lists and "其他会话" cascade a
// second menu — Flutter's showMenu has no native submenu. [extraTop] rows (e.g.
// the terminal's copy/paste/全选) render above a divider; [extraBottom] rows
// (e.g. "发送到在线用户…") render below the local targets.
Future<String?> showGroupedSendMenu(
  BuildContext context,
  Offset globalPos, {
  required List<SendTarget> same,
  required List<SendTarget> others,
  List<PopupMenuEntry<String>> extraTop = const [],
  List<PopupMenuEntry<String>> extraBottom = const [],
}) async {
  final sendItems = sendMenuEntries(same, others);
  final v = await showMenu<String>(
    context: context,
    position: menuPosAt(context, globalPos),
    items: [
      ...extraTop,
      if (extraTop.isNotEmpty &&
          (sendItems.isNotEmpty || extraBottom.isNotEmpty))
        const PopupMenuDivider(),
      ...sendItems,
      if (extraBottom.isNotEmpty && sendItems.isNotEmpty)
        const PopupMenuDivider(),
      ...extraBottom,
    ],
  );
  if (v == 'send-same') {
    if (!context.mounted) return null;
    return showPeerPicker(context, globalPos, same, 'send');
  }
  if (v != 'send-others') return v; // 'send:<id>', an extraTop value, or null
  if (!context.mounted) return null;
  return showPeerPicker(context, globalPos, others, 'send');
}

// menuPosAt converts a global tap position into the RelativeRect showMenu wants,
// anchored against the current overlay. Shared so context-menu positioning lives
// in one place (the grouped send menu + the peer picker).
RelativeRect menuPosAt(BuildContext context, Offset globalPos) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  return RelativeRect.fromRect(
    globalPos & const Size(1, 1),
    Offset.zero & overlay.size,
  );
}

// showPeerPicker shows a flat menu of [peers] at [globalPos], each returning
// '<prefix>:<id>' (or null). Backs both the "其他会话" send cascade and the
// "插话到会话" cascade — Flutter's showMenu has no native submenu, so a chosen
// parent row reopens a menu of targets here.
Future<String?> showPeerPicker(
  BuildContext context,
  Offset globalPos,
  List<SendTarget> peers,
  String prefix, {
  IconData icon = Icons.send_rounded,
  String Function(SendTarget t)? label,
}) {
  return showMenu<String>(
    context: context,
    position: menuPosAt(context, globalPos),
    items: [
      for (final t in peers)
        ccMenuItem(
          value: '$prefix:${t.id}',
          icon: icon,
          label: label?.call(t) ?? '发送到「${t.label}」',
        ),
    ],
  );
}

// fileNameDirLabel renders a path as filename (left) + small gray directory —
// shared by the desktop commit panel and the phone change / commit-file rows.
// [nameColor] tints the filename (e.g. by git change kind); null keeps the
// default text color.
Widget fileNameDirLabel(String path, {Color? nameColor}) {
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
          style: CcType.code(size: 12.5, color: nameColor ?? CcColors.text),
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
