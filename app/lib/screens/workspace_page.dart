import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../local/cli.dart';
import '../local/config.dart';
import '../local/worktrees.dart';
import '../theme.dart';
import '../widgets.dart';
import 'handoff_detail_view.dart';
import 'terminal_deck.dart';
import 'terminal_pane.dart';

// WorkspacePage is the project-centric cockpit (desktop only): a terminal deck
// (left, primary) + a Workspace → Project → (Worktrees + Tasks) tree (right).
// Launch a claude/codex session in any project or worktree; tap a task for its
// 对接文档; create/remove workspaces, projects and worktrees (shells the CLI).
// Open agent sessions persist and reopen next launch (TerminalHost.persistKey).
class WorkspacePage extends StatefulWidget {
  final RelayClient client;
  final AppConfig config;
  const WorkspacePage({super.key, required this.client, required this.config});

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> with TerminalHost {
  late AppConfig _cfg = widget.config; // reloaded after config mutations
  Map<String, List<ListItem>> _tasksByRepo = const {};
  // project path -> worktrees. Key absent = not loaded; value null = loading;
  // value list = loaded (possibly empty).
  final Map<String, List<Worktree>?> _worktrees = {};
  // expansion controllers per project path, so launching a session can expand
  // its project to reveal the new session node.
  final Map<String, ExpansibleController> _proj = {};
  bool _busy = false;

  @override
  String? get persistKey => 'workspace_sessions';

  @override
  void initState() {
    super.initState();
    _loadTasks();
    // After restoring persisted sessions, expand the projects that own them so
    // the session tabs are visible in the tree.
    restoreTerms().then((_) {
      if (!mounted) return;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _expandWithSessions());
    });
  }

  ExpansibleController _ctlFor(String path) =>
      _proj.putIfAbsent(path, ExpansibleController.new);

  @override
  void dispose() {
    disposeTerms();
    super.dispose();
  }

  // ---------------------------------------------------------------- data ----

  Future<void> _loadTasks() async {
    try {
      final lists = await Future.wait([
        widget.client.handoffs(as: 'recipient'),
        widget.client.handoffs(as: 'sender'),
      ]);
      final byId = <String, ListItem>{};
      for (final it in [...lists[0], ...lists[1]]) {
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
    if (_worktrees.containsKey(path)) return;
    setState(() => _worktrees[path] = null); // mark loading
    final wts = await listWorktrees(path);
    if (mounted) setState(() => _worktrees[path] = wts);
  }

  Future<void> _reloadConfig() async {
    final cfg = await AppConfig.load();
    if (cfg != null && mounted) setState(() => _cfg = cfg);
  }

  Future<void> _reloadWorktrees(String path) async {
    setState(() => _worktrees.remove(path));
    await _ensureWorktrees(path);
  }

  Future<void> _refresh() async {
    setState(() => _worktrees.clear());
    await _reloadConfig();
    await _loadTasks();
  }

  void _snack(String s) {
    if (mounted) snack(context, s);
  }

  // _runCli runs a CLI mutation with a busy indicator + friendly errors, then an
  // optional refresh (reload config / worktrees).
  Future<void> _runCli(Future<void> Function() action, String okMsg,
      {Future<void> Function()? after}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (after != null) await after();
      _snack(okMsg);
    } catch (e) {
      _snack(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _launch(String dir, String agent, String preLaunch) {
    final pl = preLaunch.trim();
    addTerm(dir, pl.isEmpty ? agent : '$pl && $agent');
  }

  // _openAgent launches a session in [dir] under project [p], then expands the
  // project so its new session node (the "tab") is visible in the tree.
  void _openAgent(ProjectCfg p, String dir, String agent, String preLaunch) {
    _launch(dir, agent, preLaunch);
    final ctl = _ctlFor(p.path);
    if (!ctl.isExpanded) ctl.expand();
  }

  void _expandWithSessions() {
    for (final ws in _cfg.workspaces) {
      for (final p in ws.projects) {
        if (_sessionsFor(p).isEmpty) continue;
        final ctl = _ctlFor(p.path);
        if (!ctl.isExpanded) ctl.expand();
      }
    }
  }

  // ----------------------------------------------------------- mutations ----

  Future<void> _newWorkspace() async {
    final v = await _fieldsDialog('新建工作区', '创建', [
      (label: '名称', hint: 'kunlun', required: true),
      (label: '根目录(可选)', hint: '默认 ~/cc-handoff-workspaces/<名>', required: false),
    ]);
    if (v == null) return;
    await _runCli(
        () => Cli.workspaceCreate(v[0], path: v[1].isEmpty ? null : v[1]),
        '已建工作区 ${v[0]}',
        after: _reloadConfig);
  }

  Future<void> _addProject(WorkspaceCfg ws) async {
    final v = await _fieldsDialog('给「${ws.name}」添加项目', '添加', [
      (
        label: 'GitHub URL 或本地路径',
        hint: 'https://github.com/org/repo.git',
        required: true
      ),
    ]);
    if (v == null) return;
    await _runCli(() => Cli.workspaceAdd(ws.name, v[0]), '已添加(URL 会先 clone)',
        after: _reloadConfig);
  }

  Future<void> _removeWorkspace(WorkspaceCfg ws) async {
    if (!await _confirm('删除工作区「${ws.name}」?', '只从 config 移除,磁盘文件保留。')) return;
    await _runCli(
        () => Cli.workspaceRemove(ws.name), '已删除', after: _reloadConfig);
  }

  Future<void> _removeProject(WorkspaceCfg ws, ProjectCfg p) async {
    if (!await _confirm('从「${ws.name}」移除项目「${p.name}」?', '只从 config 移除,磁盘文件保留。')) {
      return;
    }
    await _runCli(() => Cli.projectRemove(ws.name, p.name), '已移除',
        after: _reloadConfig);
  }

  Future<void> _newWorktree(WorkspaceCfg ws, ProjectCfg p) async {
    final v = await _fieldsDialog('在「${p.name}」新建 worktree', '创建', [
      (label: '分支名', hint: 'feature/x', required: true),
      (label: '起点 ref(可选)', hint: '默认当前 HEAD', required: false),
    ]);
    if (v == null) return;
    await _runCli(
        () => Cli.worktreeAdd(p.name, v[0],
            workspace: ws.name, start: v[1].isEmpty ? null : v[1]),
        '已建 worktree',
        after: () => _reloadWorktrees(p.path));
  }

  Future<void> _deleteWorktree(
      WorkspaceCfg ws, ProjectCfg p, Worktree w) async {
    final br = w.branch.isEmpty ? w.name : w.branch;
    if (!await _confirm('删除 worktree「$br」?', '会执行 git worktree remove --force。')) {
      return;
    }
    await _runCli(
        () => Cli.worktreeRemove(p.name, br, workspace: ws.name, force: true),
        '已删除',
        after: () => _reloadWorktrees(p.path));
  }

  // ------------------------------------------------------------- dialogs ----

  Future<List<String>?> _fieldsDialog(String title, String okLabel,
      List<({String label, String? hint, bool required})> fields) async {
    final ctls = [for (final _ in fields) TextEditingController()];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < fields.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
              child: TextField(
                controller: ctls[i],
                autofocus: i == 0,
                decoration: InputDecoration(
                    labelText: fields[i].label, hintText: fields[i].hint),
              ),
            ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(okLabel)),
        ],
      ),
    );
    if (ok != true) return null;
    final vals = [for (final c in ctls) c.text.trim()];
    for (var i = 0; i < fields.length; i++) {
      if (fields[i].required && vals[i].isEmpty) {
        _snack('${fields[i].label} 不能为空');
        return null;
      }
    }
    return vals;
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    return ok == true;
  }

  void _openTask(ListItem it) {
    showDialog(
      context: context,
      builder: (dctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 660),
          child: HandoffDetailView(
            client: widget.client,
            config: _cfg,
            item: it,
            onOpenTerminal: (wt, cmd) {
              addTerm(wt, cmd);
              Navigator.pop(dctx);
            },
            onSendToTerminal: sendToTerminal,
            onChanged: _loadTasks,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- view ----

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: _termArea()),
      const VerticalDivider(width: 1),
      SizedBox(width: 340, child: _sidebar()),
    ]);
  }

  Widget _termArea() {
    if (terms.isEmpty) {
      return DecoratedBox(
        decoration: appGradient,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: const [
            Icon(Icons.terminal_outlined, size: 40, color: CcColors.subtle),
            SizedBox(height: 14),
            Text('从右侧工作区,在项目或 worktree 上起一个会话',
                style: TextStyle(color: CcColors.muted)),
            SizedBox(height: 6),
            Text('claude · codex',
                style: TextStyle(
                    fontFamily: CcType.mono,
                    color: CcColors.subtle,
                    fontSize: 12,
                    letterSpacing: 0.5)),
          ]),
        ),
      );
    }
    return terminalBody();
  }

  Widget _sidebar() {
    final wss = _cfg.workspaces;
    return Column(children: [
      Container(
        height: 44,
        padding: const EdgeInsets.only(left: 12, right: 4),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [CcColors.panelHigh, CcColors.panel],
          ),
          border: Border(bottom: BorderSide(color: CcColors.border)),
        ),
        child: Row(children: [
          sectionTitle('工作区',
              meta: '${wss.length}', icon: Icons.workspaces_outlined),
          const Spacer(),
          IconButton(
              onPressed: _busy ? null : _newWorkspace,
              tooltip: '新建工作区',
              icon: const Icon(Icons.add, size: 18)),
          IconButton(
              onPressed: _busy ? null : _refresh,
              tooltip: '刷新',
              icon: const Icon(Icons.refresh, size: 18)),
        ]),
      ),
      if (_busy) const LinearProgressIndicator(minHeight: 2),
      Expanded(
        child: wss.isEmpty
            ? centerMsg('config.toml 里没有 workspace —— 点右上 + 新建,或 `cc-handoff workspace create`')
            : ListView(
                children: wss
                    .map((ws) => ExpansionTile(
                          title: Text(ws.name.isEmpty ? '(默认)' : ws.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          leading: const Icon(Icons.workspaces_outline, size: 18),
                          trailing: _workspaceMenu(ws),
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
      trailing: _projectMenu(ws, p),
      controller: _ctlFor(p.path),
      tilePadding: const EdgeInsets.only(left: 16, right: 4),
      childrenPadding: const EdgeInsets.only(left: 16),
      shape: const Border(),
      onExpansionChanged: (open) {
        if (open) _ensureWorktrees(p.path);
      },
      children: [
        ..._sessionNodes(p),
        ..._worktreeNodes(ws, p),
        ..._taskNodes(p),
        if (_projectEmpty(p))
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('无 worktree / 任务',
                style: TextStyle(color: CcColors.muted, fontSize: 12)),
          ),
      ],
    );
  }

  // The empty hint shows only once worktrees have LOADED empty and there are no
  // tasks — not while still loading or before the tile is expanded.
  bool _projectEmpty(ProjectCfg p) {
    final wts = _worktrees[p.path];
    final wtLoadedEmpty =
        _worktrees.containsKey(p.path) && wts != null && wts.isEmpty;
    return wtLoadedEmpty &&
        (_tasksByRepo[p.name]?.isEmpty ?? true) &&
        _sessionsFor(p).isEmpty;
  }

  // _sessionsFor returns the open terminal sessions whose workdir is this
  // project's root or one of its worktrees, paired with their index in `terms`.
  List<({int idx, TerminalSession s})> _sessionsFor(ProjectCfg p) {
    final out = <({int idx, TerminalSession s})>[];
    for (var i = 0; i < terms.length; i++) {
      final wd = terms[i].workdir;
      if (wd == p.path || wd.startsWith('${p.path}/.worktrees/')) {
        out.add((idx: i, s: terms[i]));
      }
    }
    return out;
  }

  List<Widget> _sessionNodes(ProjectCfg p) {
    final ss = _sessionsFor(p);
    if (ss.isEmpty) return const [];
    return [
      _sectionLabel('会话 (${ss.length})'),
      ...ss.map((e) {
        final active = e.idx == activeTerm;
        final agent = e.s.command.contains('codex') ? 'codex' : 'claude';
        return Container(
          decoration: BoxDecoration(
            border: Border(
                left: BorderSide(
                    color: active ? CcColors.accent : Colors.transparent,
                    width: 2)),
          ),
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 8, right: 0),
            selected: active,
            leading: Icon(Icons.terminal,
                size: 16,
                color: active ? CcColors.accentBright : CcColors.muted),
            title: Text('$agent · ${e.s.title}',
                style: TextStyle(
                    fontFamily: CcType.mono,
                    fontSize: 12.5,
                    color: active ? CcColors.text : CcColors.muted,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            onTap: () => setState(() => activeTerm = e.idx),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (active)
                Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: statusDot(CcColors.ok, size: 7, glow: true)),
              IconButton(
                icon: const Icon(Icons.close, size: 16, color: CcColors.muted),
                tooltip: '关闭会话',
                onPressed: () => closeTerm(e.idx),
              ),
            ]),
          ),
        );
      }),
    ];
  }

  List<Widget> _worktreeNodes(WorkspaceCfg ws, ProjectCfg p) {
    if (!_worktrees.containsKey(p.path)) return const [];
    final wts = _worktrees[p.path];
    if (wts == null) {
      return const [
        ListTile(
            dense: true,
            title: Text('worktrees 加载中…',
                style: TextStyle(color: CcColors.muted, fontSize: 12)))
      ];
    }
    if (wts.isEmpty) return const [];
    return [
      _sectionLabel('WORKTREES'),
      ...wts.map((w) => ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 8, right: 0),
            leading: Icon(Icons.account_tree_outlined,
                size: 16, color: w.isHandoff ? CcColors.accent : CcColors.muted),
            title: Text(w.branch.isEmpty ? w.name : w.branch,
                style: const TextStyle(fontFamily: CcType.mono, fontSize: 12.5),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            subtitle: w.isHandoff
                ? const Text('handoff',
                    style: TextStyle(color: CcColors.accent, fontSize: 10))
                : null,
            trailing: _worktreeMenu(ws, p, w),
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

  // ------------------------------------------------------------- menus ----

  List<PopupMenuEntry<String>> _agentItems(String def) => [
        PopupMenuItem(
            value: 'claude',
            child: Text('起 claude${def == 'claude' ? '  (默认)' : ''}')),
        PopupMenuItem(
            value: 'codex',
            child: Text('起 codex${def == 'codex' ? '  (默认)' : ''}')),
      ];

  Widget _workspaceMenu(WorkspaceCfg ws) => PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 18),
        tooltip: '工作区操作',
        onSelected: (v) {
          if (v == 'add') _addProject(ws);
          if (v == 'remove') _removeWorkspace(ws);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'add', child: Text('添加项目')),
          PopupMenuItem(value: 'remove', child: Text('删除工作区')),
        ],
      );

  Widget _projectMenu(WorkspaceCfg ws, ProjectCfg p) => PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 18),
        tooltip: '项目操作',
        onSelected: (v) {
          switch (v) {
            case 'claude':
            case 'codex':
              _openAgent(p, p.path, v, ws.preLaunch);
            case 'worktree':
              _newWorktree(ws, p);
            case 'remove':
              _removeProject(ws, p);
          }
        },
        itemBuilder: (_) => [
          ..._agentItems(ws.agent),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'worktree', child: Text('新建 worktree')),
          const PopupMenuItem(value: 'remove', child: Text('移除项目')),
        ],
      );

  Widget _worktreeMenu(WorkspaceCfg ws, ProjectCfg p, Worktree w) =>
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 18),
        tooltip: 'worktree 操作',
        onSelected: (v) {
          switch (v) {
            case 'claude':
            case 'codex':
              _openAgent(p, w.path, v, ws.preLaunch);
            case 'delete':
              _deleteWorktree(ws, p, w);
          }
        },
        itemBuilder: (_) => [
          ..._agentItems(ws.agent),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'delete', child: Text('删除 worktree')),
        ],
      );

  Widget _sectionLabel(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 0, 2),
        child: Text(s,
            style: const TextStyle(
                fontFamily: CcType.mono,
                color: CcColors.subtle,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6)),
      );
}
