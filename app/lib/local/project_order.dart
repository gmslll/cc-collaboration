import 'dart:convert';

import 'prefs.dart';

// Per-device project ordering: a presentation-only overlay stored in Prefs and
// applied at render time to the project list (desktop sidebar + 会话总览) or the
// phone's root list. Kept out of config.toml on purpose — order is a per-device
// preference, and this is what lets the phone keep an order independent of the
// desktop (each device has its own Prefs store). See project_order plan.

// applyOrder stable-sorts [items] so keys present in [order] come first in the
// order's sequence; keys absent from [order] (e.g. a newly-added project) keep
// their original relative order at the end. Deterministic (original index breaks
// ties), so a duplicate/ambiguous key never reshuffles unpredictably.
List<T> applyOrder<T>(
  List<T> items,
  List<String> order,
  String Function(T) keyOf,
) {
  if (order.isEmpty || items.length < 2) return items;
  final rank = <String, int>{};
  for (var i = 0; i < order.length; i++) {
    rank.putIfAbsent(order[i], () => i);
  }
  final n = order.length;
  final decorated = <(int, T)>[
    for (var i = 0; i < items.length; i++) (i, items[i]),
  ];
  decorated.sort((a, b) {
    final ra = rank[keyOf(a.$2)] ?? (n + a.$1);
    final rb = rank[keyOf(b.$2)] ?? (n + b.$1);
    final c = ra.compareTo(rb);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final d in decorated) d.$2];
}

// loadOrder/saveOrder persist an ordered key list as a JSON string (Prefs has no
// list type) — mirrors remote_workspace_page's _loadKeyButtons/_saveKeyButtons.
List<String> loadOrder(String prefKey) {
  final raw = Prefs.getString(prefKey, def: '');
  if (raw.isEmpty) return const [];
  try {
    final d = jsonDecode(raw);
    if (d is List) return [for (final e in d) e.toString()];
  } catch (_) {}
  return const [];
}

void saveOrder(String prefKey, List<String> order) =>
    Prefs.setString(prefKey, jsonEncode(order));

// Desktop keys per workspace by project NAME (a project's identity within its
// workspace; both the sidebar and the overview group by name).
String desktopProjectOrderKey(String workspaceName) =>
    'ws.projOrder.$workspaceName';

// Phone keys a single global list by absolute PATH (names can collide across
// workspaces; path is the stable cross-device id).
const String kPhoneProjectOrderKey = 'remote.projectOrder.v1';
