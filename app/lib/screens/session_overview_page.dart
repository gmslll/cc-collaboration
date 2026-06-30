import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

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
        const Spacer(),
        if (reviewCount > 0)
          tag('待 review $reviewCount', CcColors.warning, bold: true),
      ],
    ),
  );

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
      for (final projEntry in wsEntry.value.entries) {
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
                  sessionAvatar(seed: c.sid, isAgent: c.isAgent),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      c.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              sessionStatusRow(
                c.status,
                c.usageLabel,
                statusDetail: c.statusDetail,
              ),
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
  final Terminal _term = Terminal(maxLines: 200);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
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
                  sessionAvatar(seed: c.sid, isAgent: c.isAgent, size: 24),
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
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: widget.onOpenInWorkspace,
                  icon: const Icon(Icons.open_in_full_rounded, size: 16),
                  label: const Text('在工作区打开'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
