import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../local/local_bus.dart';
import '../local/project_order.dart';
import '../local/session_overview.dart';
import '../terminal_theme.dart';
import '../theme.dart';
import '../widgets.dart';

// SessionOverviewPage is the desktop top-level "会话总览": every open session
// laid out flat, grouped by 工作区 → 项目 → worktree, each as a card showing the
// agent's latest reply preview + status + token usage — so the user can glance
// and spot which sessions finished and need review. It's a read-only projection
// of SessionOverviewStore (fed by WorkspacePage); tapping a card routes back via
// onOpenSession (HomeShell switches to 工作区 + focuses the session).
class SessionOverviewPage extends StatefulWidget {
  final SessionOverviewStore store;
  final void Function(String sid) onOpenSession;
  // active = this page is the currently-selected nav destination. Drives the
  // store's `observed` flag so the workspace runs its preview ticker only while
  // the overview is on screen.
  final bool active;
  const SessionOverviewPage({
    super.key,
    required this.store,
    required this.onOpenSession,
    this.active = false,
  });

  @override
  State<SessionOverviewPage> createState() => _SessionOverviewPageState();
}

class _SessionOverviewPageState extends State<SessionOverviewPage> {
  SessionOverviewStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStore);
    _store.observed.value = widget.active;
  }

  @override
  void didUpdateWidget(SessionOverviewPage old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _store.observed.value = widget.active;
  }

  @override
  void dispose() {
    _store.removeListener(_onStore);
    _store.observed.value = false;
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  // _openQuickReply pops the preview + quick-reply dialog for a session, so the
  // user can read its latest screen and confirm/reply without switching to the
  // workspace. The dialog's "在工作区打开" escape hatch still jumps there.
  void _openQuickReply(SessionCard c) {
    showDialog<void>(
      context: context,
      builder: (_) => _QuickReplyDialog(
        card: c,
        store: _store,
        onOpenInWorkspace: () {
          Navigator.of(context).pop();
          widget.onOpenSession(c.sid);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cards = _store.cards;
    final reviewCount = cards
        .where((c) => c.status == SessionStatus.needsReview)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(cards.length, reviewCount),
        const Divider(height: 1),
        Expanded(
          child: cards.isEmpty
              ? centerMsg('暂无会话。\n在「工作区」启动 Claude/Codex 会话后会出现在这里。')
              : _grouped(cards),
        ),
      ],
    );
  }

  Widget _header(int total, int reviewCount) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 16, 14),
    child: Row(
      children: [
        const Icon(Icons.grid_view_rounded, size: 20, color: CcColors.accent),
        const SizedBox(width: 10),
        const Text(
          '会话总览',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 10),
        Text(
          '$total 个会话',
          style: CcType.code(size: 12.5, color: CcColors.muted),
        ),
        const SizedBox(width: 8),
        // TEMP build marker — confirms this (capsule) build is the one running.
        // Remove once verified.
        tag('capsule ✦', CcColors.accent),
        const Spacer(),
        if (reviewCount > 0)
          tag('待 review $reviewCount', CcColors.warning, bold: true),
        if (kDebugMode) ..._debugDispatchActions(),
      ],
    ),
  );

  // TEMP debug entry (Track G manual verification of
  // SessionOverviewStore.dispatchHandler/spawnHandler) — kDebugMode-only, so it
  // never ships in a release build. Exercises both handlers against a real
  // session without waiting for the 待办 page's (Track I) assign dialog. Safe to
  // delete once that dialog lands and supersedes it.
  List<Widget> _debugDispatchActions() => [
    const SizedBox(width: 8),
    IconButton(
      tooltip: '调试: 投递测试消息到第一个会话 (dispatchHandler)',
      icon: const Icon(Icons.bug_report_outlined, size: 18),
      onPressed: _store.cards.isEmpty ? null : _debugDispatch,
    ),
    IconButton(
      tooltip: '调试: 在第一个会话所在项目新建一个 shell 会话 (spawnHandler)',
      icon: const Icon(Icons.add_box_outlined, size: 18),
      onPressed: _store.cards.isEmpty ? null : _debugSpawn,
    ),
  ];

  void _debugDispatch() {
    final target = _store.cards.first;
    final err = _store.dispatch(
      LocalMsg('', target.sid, '[调试] Track G dispatchHandler 测试消息', true),
    );
    _debugToast(err == null ? '已投递到 ${target.label}' : '投递失败: $err');
  }

  Future<void> _debugSpawn() async {
    final ref = _store.cards.first;
    final (sid, err) = await _store.spawn(
      workspace: ref.workspace,
      project: ref.project,
      kind: 'shell',
    );
    _debugToast(err == null ? '已新建会话 $sid' : '新建失败: $err');
  }

  void _debugToast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // _grouped lays out cards under 工作区 → 项目 → worktree headers, preserving the
  // snapshot's order (newest sessions last). Orphan (unmapped) sessions fall
  // under "其他".
  Widget _grouped(List<SessionCard> cards) {
    // Stable, insertion-ordered nesting: ws -> proj -> (worktree-or-null) -> [].
    final byWs = <String, Map<String, Map<String?, List<SessionCard>>>>{};
    for (final c in cards) {
      final ws = c.workspace.isEmpty ? '其他' : c.workspace;
      final proj = c.project.isEmpty ? '其他' : c.project;
      ((byWs[ws] ??= {})[proj] ??= {}).putIfAbsent(c.worktree, () => []).add(c);
    }

    final sections = <Widget>[];
    for (final wsEntry in byWs.entries) {
      sections.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          child: sectionTitle(wsEntry.key, icon: Icons.workspaces_rounded),
        ),
      );
      // Follow the per-device project order overlay the sidebar writes. '其他'
      // (empty workspace name) maps back to '' so the default workspace matches.
      final wsName = wsEntry.key == '其他' ? '' : wsEntry.key;
      final projEntries = applyOrder(
        wsEntry.value.entries.toList(),
        loadOrder(desktopProjectOrderKey(wsName)),
        (e) => e.key,
      );
      for (final projEntry in projEntries) {
        sections.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 6, 20, 4),
            child: Row(
              children: [
                const Icon(
                  Icons.folder_rounded,
                  size: 15,
                  color: CcColors.muted,
                ),
                const SizedBox(width: 6),
                Text(
                  projEntry.key,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: CcColors.text,
                  ),
                ),
              ],
            ),
          ),
        );
        for (final wtEntry in projEntry.value.entries) {
          if (wtEntry.key != null) {
            sections.add(
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 4, 20, 2),
                child: Row(
                  children: [
                    const Icon(
                      Icons.account_tree_rounded,
                      size: 13,
                      color: CcColors.subtle,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      wtEntry.key!,
                      style: CcType.code(size: 12, color: CcColors.subtle),
                    ),
                  ],
                ),
              ),
            );
          }
          sections.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 4, 16, 4),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [for (final c in wtEntry.value) _card(c)],
              ),
            ),
          );
        }
      }
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: sections,
    );
  }

  Widget _card(SessionCard c) {
    return SizedBox(
      width: 320,
      child: BreathingGlow(
        active: sessionStatusIsActive(c.status),
        child: HoverLift(
          onTap: () => _openQuickReply(c),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SessionActivityAvatar(
                    seed: c.sid,
                    isAgent: c.isAgent,
                    status: c.status,
                    size: 26,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      c.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    c.sid,
                    style: CcType.code(size: 10.5, color: CcColors.subtle),
                  ),
                  // Always-visible "打成胶囊" entry (agent sessions only) so it
                  // doesn't hide behind the quick-reply popup; shows a busy
                  // spinner + is debounced while its capsule is distilling.
                  if (c.isAgent && (c.workdir?.isNotEmpty ?? false)) ...[
                    const SizedBox(width: 2),
                    if (_store.isCapsuleInFlight(c.sid))
                      const Padding(
                        padding: EdgeInsets.all(6),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      IconButton(
                        tooltip: '打成胶囊',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        icon: const Icon(Icons.science_rounded, size: 16),
                        onPressed: () => startCapsuleFlow(context, _store, c),
                      ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              sessionStatusRow(
                c.status,
                c.usageLabel,
                statusDetail: c.statusDetail,
              ),
              if (c.recentActivity.isNotEmpty) ...[
                const SizedBox(height: 8),
                sessionActivityList(c.recentActivity),
              ],
              const SizedBox(height: 8),
              sessionPreviewBox(c.preview),
            ],
          ),
        ),
      ),
    );
  }
}

// _QuickReplyDialog previews a session's live screen and lets the user
// confirm/reply to it in place — no workspace switch. It pulls a deeper screen
// snapshot (via the store) on open and on a short timer so a running agent's
// output and any permission prompt stay current; sends route back through the
// store to the live session.
class _QuickReplyDialog extends StatefulWidget {
  final SessionCard card;
  final SessionOverviewStore store;
  final VoidCallback onOpenInWorkspace;
  const _QuickReplyDialog({
    required this.card,
    required this.store,
    required this.onOpenInWorkspace,
  });

  @override
  State<_QuickReplyDialog> createState() => _QuickReplyDialogState();
}

class _QuickReplyDialogState extends State<_QuickReplyDialog> {
  final _ctl = TextEditingController();
  // A throwaway terminal we paint the session's coloured screen snapshot into —
  // a real xterm view, not stripped text. Independent of the live session's
  // Terminal so it never fights it for PTY size; small buffer = cheap rewrites.
  final Terminal _term = ccTerminal(maxLines: 200);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Opening the preview = the user is looking at this session → clear its
    // 待 review flag (mirrors local foregrounding / a phone watching it), so a
    // reviewed-from-here session stops showing as "完成待查看".
    widget.store.markReviewed(widget.card.sid);
    _refresh();
    _timer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final ansi = await widget.store.loadPreview(widget.card.sid);
    if (!mounted || ansi == null) return;
    _term.write('\x1b[3J\x1b[2J\x1b[H'); // clear scrollback + screen, home
    _term.write(ansi);
  }

  // _bump re-reads the screen shortly after a send so the agent's reaction shows
  // without waiting for the next timer tick.
  void _bump() => Future.delayed(const Duration(milliseconds: 350), _refresh);

  void _keys(String keys) {
    widget.store.sendInput(widget.card.sid, keys);
    _bump();
  }

  void _confirm() {
    widget.store.sendInput(widget.card.sid, '', submit: true);
    _bump();
  }

  void _sendText() {
    final t = _ctl.text;
    if (t.trim().isEmpty) return;
    widget.store.sendInput(widget.card.sid, t, submit: true);
    _ctl.clear();
    _bump();
  }

  Widget _quick(String label, VoidCallback onTap) => OutlinedButton(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      minimumSize: const Size(0, 32),
    ),
    child: Text(label, style: CcType.code(size: 12.5)),
  );

  @override
  Widget build(BuildContext context) {
    final c = widget.card;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SessionActivityAvatar(
                    seed: c.sid,
                    isAgent: c.isAgent,
                    status: c.status,
                    size: 24,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      c.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    onPressed: _refresh,
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              sessionStatusRow(
                c.status,
                c.usageLabel,
                statusDetail: c.statusDetail,
              ),
              const SizedBox(height: 10),
              Container(
                height: 280,
                width: double.infinity,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: ccTerminalTheme.background,
                  borderRadius: BorderRadius.circular(CcRadius.sm),
                  border: Border.all(color: CcColors.border),
                ),
                child: TerminalView(
                  _term,
                  theme: ccTerminalTheme,
                  textStyle: const TerminalStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12,
                  ),
                  padding: const EdgeInsets.all(8),
                  readOnly: true,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _quick('↵ 确认', _confirm),
                  _quick('1', () => _keys('1')),
                  _quick('2', () => _keys('2')),
                  _quick('3', () => _keys('3')),
                  _quick('y', () => _keys('y')),
                  _quick('n', () => _keys('n')),
                  _quick('Esc', () => _keys('\x1b')),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctl,
                      autofocus: true,
                      maxLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendText(),
                      decoration: const InputDecoration(
                        hintText: '快捷回复…（回车发送）',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _sendText, child: const Text('发送')),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: widget.onOpenInWorkspace,
                    icon: const Icon(Icons.open_in_full_rounded, size: 16),
                    label: const Text('在工作区打开'),
                  ),
                  const Spacer(),
                  // Only agent sessions with a working dir can be frozen into a
                  // capsule (a shell session has no transcript to distill).
                  if (c.isAgent && (c.workdir?.isNotEmpty ?? false))
                    TextButton.icon(
                      onPressed: () => startCapsuleFlow(context, widget.store, c),
                      icon: const Icon(Icons.science_rounded, size: 16),
                      label: const Text('打成胶囊'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// startCapsuleFlow runs the whole "打成胶囊" UX from either entry point (the
// always-visible card button or the quick-reply popup): when the session is
// idle, first pick a distill strategy; then capture+distill behind a spinner;
// then open the review/submit dialog. Uses context.mounted since it outlives no
// single State — both call sites pass their own BuildContext.
Future<void> startCapsuleFlow(
  BuildContext context,
  SessionOverviewStore store,
  SessionCard card,
) async {
  if (store.isCapsuleInFlight(card.sid)) return; // debounce repeat clicks

  var preferSelf = false;
  if (!sessionStatusIsActive(card.status)) {
    final choice = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('怎么蒸馏这个会话?'),
        content: const Text(
          '「让它自己蒸馏」更懂上下文,但会占用该会话一会儿;「后台蒸馏」不打扰它,读转录来做。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('后台蒸馏'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('让它自己蒸馏'),
          ),
        ],
      ),
    );
    if (choice == null) return; // cancelled
    preferSelf = choice;
  }
  if (!context.mounted) return;

  // No blocking modal: a self-distill runs *inside* the session (the user should
  // keep watching/working while it does), and even the headless path can take a
  // while. So just announce it — the distill runs in the background (the card
  // shows a busy spinner meanwhile) and the review dialog pops when it's ready.
  store.markCapsuleInFlight(card.sid);
  snack(
    context,
    preferSelf
        ? '已让会话 ${card.sid} 自己蒸馏胶囊,完成后自动弹出复查'
        : '正在后台蒸馏胶囊,完成后自动弹出复查',
  );

  CapsuleDraft? draft;
  String? err;
  try {
    (draft, err) = await store.captureCapsule(card, preferSelfDistill: preferSelf);
  } finally {
    store.clearCapsuleInFlight(card.sid); // distill done → stop the card spinner
  }
  if (!context.mounted) return;
  final ready = draft;
  if (ready == null) {
    snack(context, '打成胶囊失败: ${err ?? "未知错误"}');
    return;
  }
  // The review dialog is modal — the card behind can't be re-clicked — so the
  // in-flight guard isn't needed here.
  await showDialog(
    context: context,
    builder: (_) => _CapsuleReviewDialog(store: store, draft: ready),
  );
}

// _CapsuleReviewDialog previews the distilled persona/seed, lets the user edit
// them in place (the user's "先落草稿供编辑再发" choice), pick a visibility
// (个人 / 公开), and publish the capsule to the plaza.
class _CapsuleReviewDialog extends StatefulWidget {
  final SessionOverviewStore store;
  final CapsuleDraft draft;
  const _CapsuleReviewDialog({required this.store, required this.draft});

  @override
  State<_CapsuleReviewDialog> createState() => _CapsuleReviewDialogState();
}

class _CapsuleReviewDialogState extends State<_CapsuleReviewDialog> {
  final _persona = TextEditingController();
  final _seed = TextEditingController();
  final _summary = TextEditingController();
  bool _public = false; // default 个人 (private)
  bool _submitting = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _summary.text = '来自会话「${widget.draft.label}」的专职胶囊';
    _load();
  }

  Future<void> _load() async {
    final p = File('${widget.draft.draftDir}/persona.md');
    final s = File('${widget.draft.draftDir}/seed.md');
    if (await p.exists()) _persona.text = await p.readAsString();
    if (await s.exists()) _seed.text = await s.readAsString();
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _persona.dispose();
    _seed.dispose();
    _summary.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    // Persist the user's edits back to the draft before shipping.
    if (_persona.text.trim().isNotEmpty) {
      await File('${widget.draft.draftDir}/persona.md').writeAsString(_persona.text);
    }
    if (_seed.text.trim().isNotEmpty) {
      await File('${widget.draft.draftDir}/seed.md').writeAsString(_seed.text);
    }
    final (ok, err) = await widget.store.submitCapsule(
      widget.draft,
      visibility: _public ? 'public' : 'private',
      summary: _summary.text.trim(),
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok) {
      Navigator.of(context).pop();
      snack(context, '胶囊已发出');
    } else {
      snack(context, '发送失败: ${err ?? "未知错误"}');
    }
  }

  // _labeledCodeField is a titled multiline code editor — the shared shape of
  // the persona and seed draft boxes.
  Widget _labeledCodeField({
    required String label,
    required TextEditingController controller,
    required int minLines,
    required int maxLines,
    String? hint,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          minLines: minLines,
          maxLines: maxLines,
          style: CcType.code(size: 12),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            isDense: true,
            hintText: hint,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _loading
              ? const SizedBox(
                  height: 120,
                  child: Center(child: CircularProgressIndicator()),
                )
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.science_rounded, size: 20),
                          const SizedBox(width: 8),
                          const Text(
                            '复查并发送胶囊',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: '关闭',
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '源工具 ${d.sourceAgent} · ①快照 ${d.hasTranscript ? "有" : "无"} · '
                        '②角色 ${d.hasPersona ? "有" : "无(蒸馏未产出)"}',
                        style: CcType.code(size: 11.5, color: CcColors.subtle),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _summary,
                        decoration: const InputDecoration(
                          labelText: '说明',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _labeledCodeField(
                        label: '② 角色 (persona.md) — 可编辑',
                        controller: _persona,
                        minLines: 3,
                        maxLines: 8,
                        hint: '(蒸馏未产出角色,可留空 — 只发 ① 快照)',
                      ),
                      const SizedBox(height: 12),
                      _labeledCodeField(
                        label: 'seed 摘要 (seed.md) — 可编辑',
                        controller: _seed,
                        minLines: 2,
                        maxLines: 6,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(
                                value: false,
                                label: Text('个人'),
                                icon: Icon(Icons.lock_outline_rounded, size: 16),
                              ),
                              ButtonSegment(
                                value: true,
                                label: Text('公开'),
                                icon: Icon(Icons.public_rounded, size: 16),
                              ),
                            ],
                            selected: {_public},
                            onSelectionChanged: (s) =>
                                setState(() => _public = s.first),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _public
                                  ? '团队所有人能在广场看到'
                                  : '只有你自己能在广场看到',
                              style: CcType.code(size: 11.5, color: CcColors.subtle),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: _submitting
                                ? null
                                : () => Navigator.of(context).pop(),
                            child: const Text('取消'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: _submitting ? null : _submit,
                            icon: _submitting
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.send_rounded, size: 16),
                            label: const Text('发送'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
