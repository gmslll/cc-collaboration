import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'local/prefs.dart';
import 'theme.dart';

// Small UI helpers shared across screens (deduped from per-page copies).

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

void snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
}

// centerMsg is the shared muted empty/placeholder state, optionally with a retry.
Widget centerMsg(String text, {VoidCallback? onRetry}) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: CcColors.muted, height: 1.35)),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('重试')),
          ],
        ]),
      ),
    );

// tag is a small mono pill: alpha-tinted [color] background + [color] text.
Widget tag(String label, Color color, {bool bold = false}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(label,
          style: TextStyle(
              fontFamily: CcType.mono,
              fontSize: 11.5,
              letterSpacing: 0.2,
              color: color,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w400)),
    );

// chip is a neutral mono pill (panel bg), e.g. repo @ branch.
Widget chip(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: CcColors.panelHigh,
        border: Border.all(color: CcColors.border),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(text,
          style: const TextStyle(
              fontFamily: CcType.mono, fontSize: 12, color: CcColors.text)),
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
        Text(title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        if (meta != null) ...[
          const SizedBox(width: 8),
          Text(meta,
              style: const TextStyle(
                  fontFamily: CcType.mono,
                  color: CcColors.muted,
                  fontSize: 12.5)),
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
}) =>
    Container(
      width: 40,
      decoration: const BoxDecoration(
        color: CcColors.panel,
        border: Border(right: BorderSide(color: CcColors.border)),
      ),
      child: Column(children: [
        const SizedBox(height: 6),
        IconButton(
            icon: Icon(icon, size: 18), tooltip: tooltip, onPressed: onExpand),
        if (label != null)
          Expanded(
            child: RotatedBox(
              quarterTurns: 1,
              child: Center(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: CcColors.muted,
                        fontSize: 11,
                        letterSpacing: 1.5)),
              ),
            ),
          ),
      ]),
    );

// statusDot is a small filled circle, optionally with a soft glow (for online /
// active / urgent indicators).
Widget statusDot(Color color, {double size = 8, bool glow = false}) => Container(
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
                    spreadRadius: 0.5)
              ]
            : null,
      ),
    );

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
              duration:
                  noMotion ? Duration.zero : const Duration(milliseconds: 120),
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
}) =>
    DragHandle(
      onDelta: (dx) => set((get() + (invert ? -dx : dx)).clamp(min, max)),
      onEnd: () => Prefs.setDouble(prefKey, get()),
    );

// BlinkingCaret is a terminal-style block cursor — blinks ~1s on/off, honors
// reduced-motion (stays solid). Used in the empty-terminal "prompt" placeholder.
class BlinkingCaret extends StatefulWidget {
  final Color color;
  final double width;
  final double height;
  const BlinkingCaret(
      {super.key,
      this.color = CcColors.accentBright,
      this.width = 8,
      this.height = 17});

  @override
  State<BlinkingCaret> createState() => _BlinkingCaretState();
}

class _BlinkingCaretState extends State<BlinkingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1060))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = Container(
        width: widget.width, height: widget.height, color: widget.color);
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
      cursor:
          widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration:
              noMotion ? Duration.zero : const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _h ? -1.5 : 0, 0),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: CcColors.panel,
            borderRadius: BorderRadius.circular(CcRadius.md),
            border: Border.all(
                color: _h
                    ? CcColors.accent.withValues(alpha: 0.5)
                    : CcColors.borderSoft),
            boxShadow: _h
                ? [
                    BoxShadow(
                        color: CcColors.accent.withValues(alpha: 0.16),
                        blurRadius: 16,
                        offset: const Offset(0, 4))
                  ]
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
