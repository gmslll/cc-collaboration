import 'dart:convert';
import 'dart:io';

import 'agent_transcript.dart' show resolveTranscriptPath;

// Per-session token usage + estimated cost, derived from the agent's on-disk
// transcript. Sits beside agent_transcript.dart and shares its contract — pure
// I/O over (agentKind, agentSessionId, workdir), no UI/session imports — so the
// desktop pane chip, the local-bus `usage` channel, the phone broadcast, and the
// `cc-handoff msg usage` CLI / MCP tool all read ONE source of truth.
//
// Two agents, two accumulation models:
//   claude — every `type:"assistant"` line carries a per-call `message.usage`; we
//            SUM them (each turn is billed separately, mostly as cache reads), and
//            take the last main-chain message for the current context occupancy.
//   codex  — every `token_count` event already carries cumulative totals
//            (`info.total_token_usage`) + the last turn (`info.last_token_usage`)
//            + the window size (`info.model_context_window`); we OVERWRITE from the
//            newest such event — no summing.

// UsageAccumulator is the incremental scan state the host caches per session so a
// long transcript isn't re-parsed from scratch each turn: scanUsageInto reads only
// the bytes appended since [offset].
class UsageAccumulator {
  int offset = 0; // byte offset already consumed (only whole lines advance it)
  int input = 0; // non-cached input tokens
  int output = 0; // output tokens (codex: includes reasoning tokens)
  int cacheRead = 0; // cached input tokens read
  int cacheCreate = 0; // cache-creation input tokens (claude only; codex = 0)
  int contextTokens = 0; // tokens occupying the window as of the latest turn
  int? contextWindow; // codex reports this directly; claude infers from the model
  String? model;
}

int _i(dynamic v) => v is num ? v.toInt() : 0;

// scanUsageInto folds the newly-appended transcript bytes into [acc]. Only whole
// lines (up to the last '\n') are consumed, so a half-flushed final line is left
// for the next scan rather than parsed partially and lost. A shrunk file (rotation
// / resume) resets the accumulator and rescans from the top.
Future<void> scanUsageInto(
  UsageAccumulator acc, {
  required String path,
  required String agentKind,
}) async {
  final f = File(path);
  final int len;
  try {
    len = await f.length();
  } catch (_) {
    return;
  }
  if (len < acc.offset) {
    // File got smaller than what we'd consumed — it was replaced. Start over.
    acc
      ..offset = 0
      ..input = 0
      ..output = 0
      ..cacheRead = 0
      ..cacheCreate = 0
      ..contextTokens = 0
      ..contextWindow = null
      ..model = null;
  }
  if (len <= acc.offset) return;

  final raf = await f.open();
  List<int> bytes;
  try {
    await raf.setPosition(acc.offset);
    bytes = await raf.read(len - acc.offset);
  } finally {
    await raf.close();
  }
  final lastNl = bytes.lastIndexOf(0x0A);
  if (lastNl < 0) return; // no complete line yet — wait for more
  final consumed = lastNl + 1;
  acc.offset += consumed;
  final text = utf8.decode(bytes.sublist(0, consumed), allowMalformed: true);

  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty) continue;
    Map<String, dynamic> o;
    try {
      o = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    if (agentKind == 'codex') {
      final p = o['payload'];
      if (p is! Map) continue;
      if (o['type'] == 'event_msg' && p['type'] == 'token_count') {
        final info = p['info'];
        if (info is! Map) continue;
        final tot = info['total_token_usage'];
        if (tot is Map) {
          final cached = _i(tot['cached_input_tokens']);
          acc
            ..input = _i(tot['input_tokens']) - cached
            ..output = _i(tot['output_tokens'])
            ..cacheRead = cached
            ..cacheCreate = 0;
        }
        final last = info['last_token_usage'];
        if (last is Map) acc.contextTokens = _i(last['total_tokens']);
        final win = _i(info['model_context_window']);
        if (win > 0) acc.contextWindow = win;
      } else if (p['model'] is String) {
        acc.model = p['model'] as String; // turn_context / session_meta
      }
    } else {
      if (o['type'] != 'assistant') continue;
      final msg = o['message'];
      if (msg is! Map) continue;
      final u = msg['usage'];
      if (u is! Map) continue;
      acc
        ..input += _i(u['input_tokens'])
        ..output += _i(u['output_tokens'])
        ..cacheRead += _i(u['cache_read_input_tokens'])
        ..cacheCreate += _i(u['cache_creation_input_tokens']);
      // Current context occupancy = the latest MAIN-chain turn (subagent
      // sidechains have their own small context and shouldn't drive the gauge,
      // but their tokens still count toward cumulative consumption above).
      if (o['isSidechain'] != true) {
        acc
          ..contextTokens = _i(u['input_tokens']) +
              _i(u['cache_read_input_tokens']) +
              _i(u['cache_creation_input_tokens']) +
              _i(u['output_tokens'])
          ..model = msg['model'] is String ? msg['model'] as String : acc.model;
      }
    }
  }
}

// Per-model price in USD per 1M tokens: [input, output, cacheWrite5m, cacheRead].
// Sourced from the claude-api skill (cached 2026-06): cache write (5m) = 1.25x
// input, cache read = 0.1x input. Approximate — keep this table the single place
// to update when prices change. Unknown models (incl. codex/gpt) → null cost; we
// still report tokens + context%.
const Map<String, List<double>> _claudePrices = {
  'claude-opus-4-8': [5, 25, 6.25, 0.5],
  'claude-opus-4-7': [5, 25, 6.25, 0.5],
  'claude-opus-4-6': [5, 25, 6.25, 0.5],
  'claude-opus-4-5': [5, 25, 6.25, 0.5],
  'claude-sonnet-4-6': [3, 15, 3.75, 0.3],
  'claude-sonnet-4-5': [3, 15, 3.75, 0.3],
  'claude-haiku-4-5': [1, 5, 1.25, 0.1],
  'claude-fable-5': [10, 50, 12.5, 1.0],
};

double? _estimateCostUsd(
  String? model,
  int input,
  int output,
  int cacheCreate,
  int cacheRead,
) {
  if (model == null) return null;
  List<double>? p;
  for (final e in _claudePrices.entries) {
    if (model == e.key || model.startsWith('${e.key}-')) {
      p = e.value;
      break;
    }
  }
  if (p == null) return null;
  return input / 1e6 * p[0] +
      output / 1e6 * p[1] +
      cacheCreate / 1e6 * p[2] +
      cacheRead / 1e6 * p[3];
}

// contextLimitFor: codex hands us the exact window; for claude, current opus /
// sonnet / fable are 1M and haiku is 200K. Approximate for anything unrecognized.
int contextLimitFor(String? model, int? reported) {
  if (reported != null && reported > 0) return reported;
  if (model != null && model.contains('haiku')) return 200000;
  return 1000000;
}

// SessionUsage is the snapshot served to the UI / bus / CLI / phone.
class SessionUsage {
  final String agentKind;
  final String? model;
  final int input;
  final int output;
  final int cacheRead;
  final int cacheCreate;
  final int contextTokens;
  final int contextLimit;
  final double? costUsd;
  final bool busy;

  const SessionUsage({
    required this.agentKind,
    required this.model,
    required this.input,
    required this.output,
    required this.cacheRead,
    required this.cacheCreate,
    required this.contextTokens,
    required this.contextLimit,
    required this.costUsd,
    required this.busy,
  });

  int get totalTokens => input + output + cacheRead + cacheCreate;
  double get contextPercent =>
      contextLimit <= 0 ? 0 : contextTokens / contextLimit * 100;

  factory SessionUsage.fromAccumulator(
    UsageAccumulator a, {
    required String agentKind,
    required bool busy,
  }) {
    return SessionUsage(
      agentKind: agentKind,
      model: a.model,
      input: a.input,
      output: a.output,
      cacheRead: a.cacheRead,
      cacheCreate: a.cacheCreate,
      contextTokens: a.contextTokens,
      contextLimit: contextLimitFor(a.model, a.contextWindow),
      costUsd: _estimateCostUsd(a.model, a.input, a.output, a.cacheCreate, a.cacheRead),
      busy: busy,
    );
  }

  Map<String, dynamic> toJson() => {
        'agent': agentKind,
        'model': model,
        'input': input,
        'output': output,
        'cacheRead': cacheRead,
        'cacheCreate': cacheCreate,
        'totalTokens': totalTokens,
        'contextTokens': contextTokens,
        'contextLimit': contextLimit,
        'contextPercent': double.parse(contextPercent.toStringAsFixed(1)),
        'costUsd': costUsd == null ? null : double.parse(costUsd!.toStringAsFixed(4)),
        'busy': busy,
      };

  factory SessionUsage.fromJson(Map<String, dynamic> j) => SessionUsage(
        agentKind: (j['agent'] ?? '').toString(),
        model: j['model'] as String?,
        input: _i(j['input']),
        output: _i(j['output']),
        cacheRead: _i(j['cacheRead']),
        cacheCreate: _i(j['cacheCreate']),
        contextTokens: _i(j['contextTokens']),
        contextLimit: _i(j['contextLimit']),
        costUsd: (j['costUsd'] is num) ? (j['costUsd'] as num).toDouble() : null,
        busy: j['busy'] == true,
      );

  // Compact one-line label for the pane chip / Live Activity, e.g.
  // "opus · ctx 45% · 1.2M tok · ~$3.40". Pieces with no data are dropped.
  String shortLabel() {
    final parts = <String>[];
    final m = model;
    if (m != null && m.isNotEmpty) parts.add(_shortModel(m));
    if (contextLimit > 0) parts.add('ctx ${contextPercent.toStringAsFixed(0)}%');
    parts.add('${_humanTokens(totalTokens)} tok');
    if (costUsd != null) parts.add('~\$${costUsd!.toStringAsFixed(2)}');
    return parts.join(' · ');
  }

  static String _shortModel(String m) {
    // claude-opus-4-8 -> opus 4.8; gpt-5.5 -> gpt-5.5
    final cm = RegExp(r'claude-([a-z]+)-(\d+)-(\d+)').firstMatch(m);
    if (cm != null) return '${cm.group(1)} ${cm.group(2)}.${cm.group(3)}';
    return m;
  }

  static String _humanTokens(int n) {
    if (n >= 1000000) return '${(n / 1e6).toStringAsFixed(n >= 10000000 ? 0 : 1)}M';
    if (n >= 1000) return '${(n / 1e3).toStringAsFixed(n >= 100000 ? 0 : 1)}K';
    return '$n';
  }
}

// computeSessionUsage is the one-shot path (no incremental cache): resolve the
// transcript, scan it whole, return the snapshot. Used by the bus/CLI/MCP read of
// a peer session and as the desktop pane's first compute. Returns null when the
// session isn't an agent or has no transcript yet.
Future<SessionUsage?> computeSessionUsage({
  required String agentKind,
  required String? agentSessionId,
  required String workdir,
  required bool busy,
}) async {
  if (agentKind != 'claude' && agentKind != 'codex') return null;
  final path = await resolveTranscriptPath(
    agentKind: agentKind,
    agentSessionId: agentSessionId,
    workdir: workdir,
  );
  if (path == null) return null;
  final acc = UsageAccumulator();
  await scanUsageInto(acc, path: path, agentKind: agentKind);
  return SessionUsage.fromAccumulator(acc, agentKind: agentKind, busy: busy);
}
