import 'package:flutter/material.dart';

import '../local/session_overview.dart';
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

  @override
  Widget build(BuildContext context) {
    final cards = _store.cards;
    final reviewCount =
        cards.where((c) => c.status == SessionStatus.needsReview).length;
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
        if (reviewCount > 0) tag('待 review $reviewCount', CcColors.warning, bold: true),
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
                const Icon(Icons.folder_rounded, size: 15, color: CcColors.muted),
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
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: sections);
  }

  Widget _card(SessionCard c) {
    return SizedBox(
      width: 320,
      child: HoverLift(
        onTap: () => widget.onOpenSession(c.sid),
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
            sessionStatusRow(c.status, c.usageLabel),
            const SizedBox(height: 8),
            sessionPreviewBox(c.preview),
          ],
        ),
      ),
    );
  }
}
