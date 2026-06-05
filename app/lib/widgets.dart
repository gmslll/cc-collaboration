import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

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
              style: const TextStyle(color: CcColors.muted)),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ]),
      ),
    );

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
