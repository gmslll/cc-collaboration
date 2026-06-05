import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../local/config.dart';
import '../local/worktrees.dart';
import '../theme.dart';
import 'handoff_detail_view.dart';
import 'terminal_deck.dart';
import 'terminal_pane.dart';

// WorkspacePage is the project-centric cockpit (desktop only): a terminal deck
// (left, primary) + a Workspace → Project → (Worktrees + Tasks) tree (right).
// Launch a claude/codex session in any project or worktree; tap a task for its
// 对接文档. Workspaces/projects come from config.toml; worktrees from git.
class WorkspacePage extends StatefulWidget {
  final RelayClient client;
  final AppConfig config;
  const WorkspacePage({super.key, required this.client, required this.config});

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  final List<TerminalSession> _terms = [];
  int _activeTerm = 0;
  Map<String, List<ListItem>> _tasksByRepo = const {};
  final Map<String, List<Worktree>> _worktrees = {};
  final Set<String> _wtLoading = {};

  @override
  void initState() {
    super.initState();
    _loadTasks();
  }

  @override
  void dispose() {
    for (final s in _terms) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _loadTasks() async {
    try {
      final recv = await widget.client.handoffs(as: 'recipient');
      final sent = await widget.client.handoffs(as: 'sender');
      final byId = <String, ListItem>{};
      for (final it in [...recv, ...sent]) {
        byId[it.id] = it;
      }
      final byRepo = <String, List<ListItem>>{};
      for (final it in byId.values) {
        (byRepo[it.repoName] ??= []).add(it);
      }
      if (mounted) setState(() => _tasksByRepo = byRepo);
    } catch (_) {}
  }

  Future<void> _ensureWorktrees(String path) async {
    if (_worktrees.containsKey(path) || _wtLoading.contains(path)) return;
    setState(() => _wtLoading.add(path));
    final wts = await listWorktrees(path);
    if (mounted) {
      setState(() {
        _worktrees[path] = wts;
        _wtLoading.remove(path);
      });
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _worktrees.clear();
      _wtLoading.clear();
    });
    await _loadTasks();
  }

  void _launch(String dir, String agent, String preLaunch) {
    final pl = preLaunch.trim();
    final cmd = pl.isEmpty ? agent : '$pl && $agent';
    setState(() {
      _terms.add(TerminalSession(dir, cmd));
      _activeTerm = _terms.length - 1;
    });
  }

  void _addTerm(String workdir, String command) {
    setState(() {
      _terms.add(TerminalSession(workdir, command));
      _activeTerm = _terms.length - 1;
    });
  }

  void _closeTerm(int i) {
    _terms[i].dispose();
    setState(() {
      _terms.removeAt(i);
      if (_activeTerm >= _terms.length) {
        _activeTerm = _terms.isEmpty ? 0 : _terms.length - 1;
      }
    });
  }

  void _openTask(ListItem it) {
    showDialog(
      context: context,
      builder: (dctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 660),
          child: HandoffDetailView(
            client: widget.client,
            config: widget.config,
            item: it,
            onOpenTerminal: (wt, cmd) {
              _addTerm(wt, cmd);
              Navigator.pop(dctx);
            },
            onSendToTerminal:
                _terms.isNotEmpty ? (t) => _terms[_activeTerm].sendText(t) : null,
            onChanged: _loadTasks,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: _termArea()),
      const VerticalDivider(width: 1),
      SizedBox(width: 340, child: _sidebar()),
    ]);
  }

  Widget _termArea() {
    if (_terms.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('从右侧工作区,在项目或 worktree 上起一个 claude / codex 会话',
              textAlign: TextAlign.center,
              style: TextStyle(color: CcColors.muted)),
        ),
      );
    }
    return TerminalDeck(
      terms: _terms,
      active: _activeTerm,
      onSwitch: (i) => setState(() => _activeTerm = i),
      onClose: _closeTerm,
    );
  }

  Widget _sidebar() {
    final wss = widget.config.workspaces;
    return Column(children: [
      Container(
        height: 44,
        padding: const EdgeInsets.only(left: 12, right: 4),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: CcColors.border))),
        child: Row(children: [
          const Text('工作区',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const Spacer(),
          IconButton(
              onPressed: _refresh,
              tooltip: '刷新',
              icon: const Icon(Icons.refresh, size: 18)),
        ]),
      ),
      Expanded(
        child: wss.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('config.toml 里没有 workspace / project',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: CcColors.muted)),
                ),
              )
            : ListView(
                children: wss
                    .map((ws) => ExpansionTile(
                          title: Text(ws.name.isEmpty ? '(默认)' : ws.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          leading: const Icon(Icons.workspaces_outline, size: 18),
                          initiallyExpanded: true,
                          shape: const Border(),
                          children:
                              ws.projects.map((p) => _projectTile(ws, p)).toList(),
                        ))
                    .toList(),
              ),
      ),
    ]);
  }

  Widget _projectTile(WorkspaceCfg ws, ProjectCfg p) {
    return ExpansionTile(
      title: Text(p.name, style: const TextStyle(fontSize: 14)),
      leading: const Icon(Icons.folder_outlined, size: 18),
      trailing: _agentMenu(ws, p.path),
      tilePadding: const EdgeInsets.only(left: 16, right: 4),
      childrenPadding: const EdgeInsets.only(left: 16),
      shape: const Border(),
      onExpansionChanged: (open) {
        if (open) _ensureWorktrees(p.path);
      },
      children: [
        ..._worktreeNodes(ws, p),
        ..._taskNodes(p),
        if (_worktrees[p.path]?.isEmpty == true &&
            (_tasksByRepo[p.name]?.isEmpty ?? true))
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('无 worktree / 任务',
                style: TextStyle(color: CcColors.muted, fontSize: 12)),
          ),
      ],
    );
  }

  List<Widget> _worktreeNodes(WorkspaceCfg ws, ProjectCfg p) {
    if (!_worktrees.containsKey(p.path)) {
      return _wtLoading.contains(p.path)
          ? const [
              ListTile(
                  dense: true,
                  title: Text('worktrees 加载中…',
                      style: TextStyle(color: CcColors.muted, fontSize: 12)))
            ]
          : const [];
    }
    final wts = _worktrees[p.path]!;
    if (wts.isEmpty) return const [];
    return [
      _sectionLabel('WORKTREES'),
      ...wts.map((w) => ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 8, right: 0),
            leading: Icon(Icons.account_tree_outlined,
                size: 16, color: w.isHandoff ? CcColors.accent : CcColors.muted),
            title: Text(w.branch.isEmpty ? w.name : w.branch,
                style: const TextStyle(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            subtitle: w.isHandoff
                ? const Text('handoff',
                    style: TextStyle(color: CcColors.accent, fontSize: 10))
                : null,
            trailing: _agentMenu(ws, w.path),
          )),
    ];
  }

  List<Widget> _taskNodes(ProjectCfg p) {
    final ts = _tasksByRepo[p.name] ?? const [];
    if (ts.isEmpty) return const [];
    return [
      _sectionLabel('任务 (${ts.length})'),
      ...ts.map((it) => ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 8, right: 8),
            leading: Icon(Icons.circle,
                size: 8,
                color:
                    it.urgency == 'urgent' ? CcColors.danger : CcColors.muted),
            title: Text(it.headline.isNotEmpty ? it.headline : it.sender,
                style: const TextStyle(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            subtitle: Text('${it.sender} · ${it.state}',
                style: const TextStyle(color: CcColors.muted, fontSize: 10)),
            onTap: () => _openTask(it),
          )),
    ];
  }

  Widget _agentMenu(WorkspaceCfg ws, String dir) {
    final def = ws.agent;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      tooltip: '起 agent',
      onSelected: (a) => _launch(dir, a, ws.preLaunch),
      itemBuilder: (_) => [
        PopupMenuItem(
            value: 'claude',
            child: Text('起 claude${def == 'claude' ? '  (默认)' : ''}')),
        PopupMenuItem(
            value: 'codex',
            child: Text('起 codex${def == 'codex' ? '  (默认)' : ''}')),
      ],
    );
  }

  Widget _sectionLabel(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 0, 2),
        child: Text(s,
            style: const TextStyle(
                color: CcColors.muted,
                fontSize: 10,
                fontWeight: FontWeight.bold)),
      );
}
