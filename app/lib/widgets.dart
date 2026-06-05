import 'package:flutter/material.dart';

import 'theme.dart';

// Small UI helpers shared across screens (deduped from per-page copies).

void snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
}

// tag is a small rounded pill: alpha-tinted [color] background + [color] text.
Widget tag(String label, Color color, {bool bold = false}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
    );

// chip is a neutral pill (panel bg, normal text), e.g. repo @ branch.
Widget chip(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: CcColors.panelHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child:
          Text(text, style: const TextStyle(fontSize: 12, color: CcColors.text)),
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
