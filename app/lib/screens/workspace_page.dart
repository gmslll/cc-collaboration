import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../local/cli.dart';
import '../local/config.dart';
import '../local/prefs.dart';
import '../local/worktrees.dart';
import '../theme.dart';
import '../widgets.dart';
import 'handoff_detail_view.dart';
import 'repo_config_page.dart';
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
  // Layout B — the terminal fills the canvas; the workspace tree (left) and a
  // task's 对接文档 (right) are slide-over drawers, both closeable → pure
  // terminal focus. Drawers open via the top-bar buttons / task tap.
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  ListItem? _detailItem; // non-null → the right detail drawer shows this task
  // drawer widths — a Prefs config knob (not drag-resizable in drawer mode), so
  // it also honours any width persisted by the old resizable-pane layout.
  final double _treeWidth = Prefs.getDouble('ws.treeWidth', def: 380);
  final double _detailWidth = Prefs.getDouble('ws.detailWidth', def: 560);
  // shared comfortable-but-compact density for the tree's leaf rows.
  static const _tileDensity = VisualDensity(vertical: -1);

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
    setState(() => _detailItem = it);
    // build the endDrawer (gated on _detailItem) first, then open it next frame.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scaffoldKey.currentState?.openEndDrawer());
  }

  // ---------------------------------------------------------------- view ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.transparent,
      // open only via the buttons (edge-swipe would fight terminal selection).
      drawerEnableOpenDragGesture: false,
      endDrawerEnableOpenDragGesture: false,
      onEndDrawerChanged: (open) {
        if (!open && _detailItem != null) setState(() => _detailItem = null);
      },
      drawer: Drawer(
        width: _treeWidth,
        backgroundColor: CcColors.panel,
        shape: const RoundedRectangleBorder(),
        child: _sidebar(),
      ),
      endDrawer: _detailItem == null
          ? null
          : Drawer(
              width: _detailWidth,
              backgroundColor: CcColors.panel,
              shape: const RoundedRectangleBorder(),
              child: _detailPanel(_detailItem!),
            ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _topBar(),
        Expanded(child: _termArea()),
      ]),
    );
  }

  // _topBar = the slim terminal chrome: a ≡ button to open the workspace tree
  // drawer, then the session tabs.
  Widget _topBar() => TerminalTabBar(
        terms: terms,
        active: activeTerm,
        onSwitch: (i) => setState(() => activeTerm = i),
        onClose: closeTerm,
        leading: Padding(
          padding: const EdgeInsets.only(left: 4, right: 2),
          child: IconButton(
            icon: const Icon(Icons.menu_rounded, size: 18),
            tooltip: '工作区',
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
        ),
      );

  // _panelHeader is the shared 44px drawer header chrome (bottom border, optional
  // gradient); pass the Row children (title + action buttons).
  Widget _panelHeader(
          {required EdgeInsetsGeometry padding,
          bool gradient = false,
          required List<Widget> children}) =>
      Container(
        height: 44,
        padding: padding,
        decoration: BoxDecoration(
          color: gradient ? null : CcColors.panel,
          gradient: gradient ? panelGradient.gradient : null,
          border: const Border(bottom: BorderSide(color: CcColors.border)),
        ),
        child: Row(children: children),
      );

  // _detailPanel hosts a task's 对接文档 inside the right drawer.
  Widget _detailPanel(ListItem it) => Column(children: [
        _panelHeader(
          padding: const EdgeInsets.only(left: 14, right: 4),
          children: [
            const Expanded(
                child: Text('对接文档',
                    style: TextStyle(fontWeight: FontWeight.w600))),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              tooltip: '关闭',
              onPressed: () => _scaffoldKey.currentState?.closeEndDrawer(),
            ),
          ],
        ),
        Expanded(
          child: HandoffDetailView(
            client: widget.client,
            config: _cfg,
            item: it,
            onOpenTerminal: (wt, cmd) {
              addTerm(wt, cmd);
              _scaffoldKey.currentState?.closeEndDrawer();
            },
            onSendToTerminal: sendToTerminal,
            onChanged: _loadTasks,
          ),
        ),
      ]);

  Widget _termArea() {
    if (terms.isEmpty) {
      final ws = _cfg.workspaces.isNotEmpty &&
              _cfg.workspaces.first.name.isNotEmpty
          ? _cfg.workspaces.first.name
          : 'workspace';
      return DecoratedBox(
        decoration: appGradient,
        child: Center(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('~/$ws',
                      style: CcType.code(size: 14.5, color: CcColors.ok)),
                  const SizedBox(width: 8),
                  Text('❯',
                      style: CcType.code(
                          size: 14.5, color: CcColors.accentBright)),
                  const SizedBox(width: 8),
                  const BlinkingCaret(),
                ]),
                const SizedBox(height: 18),
                const Text('点左上角打开工作区,在项目 / worktree 上起会话',
                    style: TextStyle(color: CcColors.muted)),
                const SizedBox(height: 8),
                Text('# claude · codex',
                    style: CcType.code(size: 12.5, color: CcColors.subtle)),
              ]),
        ),
      );
    }
    return terminalBody();
  }

  Widget _sidebar() {
    final wss = _cfg.workspaces;
    return Column(children: [
      _panelHeader(
        padding: const EdgeInsets.only(left: 12, right: 4),
        gradient: true,
        children: [
          sectionTitle('工作区',
              meta: '${wss.length}', icon: Icons.workspaces_rounded),
          const Spacer(),
          IconButton(
              onPressed: _busy ? null : _newWorkspace,
              tooltip: '新建工作区',
              icon: const Icon(Icons.add_rounded, size: 18)),
          IconButton(
              onPressed: _busy ? null : _refresh,
              tooltip: '刷新',
              icon: const Icon(Icons.refresh_rounded, size: 18)),
          IconButton(
              onPressed: () => _scaffoldKey.currentState?.closeDrawer(),
              tooltip: '收起',
              icon: const Icon(Icons.chevron_left_rounded, size: 18)),
        ],
      ),
      if (_busy) const LinearProgressIndicator(minHeight: 2),
      Expanded(
        child: wss.isEmpty
            ? centerMsg('config.toml 里没有 workspace —— 点右上 + 新建,或 `cc-handoff workspace create`')
            : ListView(
                children: wss
                    .map((ws) => ExpansionTile(
                          title: Text(ws.name.isEmpty ? '(默认)' : ws.name,
                              style: const TextStyle(
                                  fontSize: 15.5, fontWeight: FontWeight.w700)),
                          leading:
                              const Icon(Icons.workspaces_rounded, size: 20),
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
      title: _HoverZone(
        builder: (h) => Row(children: [
          Expanded(
              child: Text(p.name,
                  style:
                      const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis)),
          _rowActions(h,
              onClaude: () => _openAgent(p, p.path, 'claude', ws.preLaunch),
              onCodex: () => _openAgent(p, p.path, 'codex', ws.preLaunch),
              menu: _projectMenu(ws, p)),
        ]),
      ),
      leading: const Icon(Icons.folder_rounded, size: 19),
      controller: _ctlFor(p.path),
      tilePadding: const EdgeInsets.only(left: 16, right: 8),
      childrenPadding: const EdgeInsets.only(left: 14),
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
    final header = _sectionHeader(p.path, 'sessions', '会话 (${ss.length})');
    if (_secCollapsed(p.path, 'sessions')) return [header];
    return [
      header,
      ...ss.map((e) {
        final active = e.idx == activeTerm;
        final agent = e.s.command.contains('codex') ? 'codex' : 'claude';
        final display =
            (e.s.name?.isNotEmpty ?? false) ? e.s.name! : '$agent · ${e.s.title}';
        return Container(
          decoration: BoxDecoration(
            color: active ? CcColors.accent.withValues(alpha: 0.08) : null,
            border: Border(
                left: BorderSide(
                    color: active ? CcColors.accent : Colors.transparent,
                    width: 2.5)),
          ),
          child: ListTile(
            visualDensity: _tileDensity,
            contentPadding: const EdgeInsets.only(left: 12, right: 2),
            horizontalTitleGap: 8,
            selected: active,
            leading: Text('❯',
                style: TextStyle(
                    fontFamily: CcType.mono,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: active ? CcColors.accentBright : CcColors.muted)),
            title: Text(display,
                style: TextStyle(
                    fontFamily: CcType.mono,
                    fontSize: 13.5,
                    color: active ? CcColors.text : CcColors.muted,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            onTap: () => setState(() => activeTerm = e.idx),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (active)
                Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: statusDot(CcColors.ok, size: 7, glow: true)),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded,
                    size: 18, color: CcColors.muted),
                tooltip: '会话操作',
                onSelected: (v) {
                  if (v == 'rename') _renameSession(e.s);
                  if (v == 'close') closeTerm(e.idx);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('重命名')),
                  PopupMenuItem(value: 'close', child: Text('关闭会话')),
                ],
              ),
            ]),
          ),
        );
      }),
    ];
  }

  Future<void> _renameSession(TerminalSession s) async {
    final ctl = TextEditingController(text: s.name ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
            controller: ctl,
            autofocus: true,
            decoration: InputDecoration(labelText: '名称(留空 = 默认)', hintText: s.title)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final v = ctl.text.trim();
    setState(() => s.name = v.isEmpty ? null : v);
    persistTerms();
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
    final header = _sectionHeader(p.path, 'worktrees', 'WORKTREES (${wts.length})');
    if (_secCollapsed(p.path, 'worktrees')) return [header];
    return [
      header,
      ...wts.map((w) => _HoverZone(
            builder: (h) => ListTile(
              visualDensity: _tileDensity,
              contentPadding: const EdgeInsets.only(left: 10, right: 2),
              leading: Icon(Icons.account_tree_rounded,
                  size: 18,
                  color: w.isHandoff ? CcColors.accent : CcColors.muted),
              title: Text(w.branch.isEmpty ? w.name : w.branch,
                  style:
                      const TextStyle(fontFamily: CcType.mono, fontSize: 13.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              subtitle: w.isHandoff
                  ? const Text('handoff',
                      style: TextStyle(color: CcColors.accent, fontSize: 11))
                  : null,
              trailing: _rowActions(h,
                  onClaude: () => _openAgent(p, w.path, 'claude', ws.preLaunch),
                  onCodex: () => _openAgent(p, w.path, 'codex', ws.preLaunch),
                  menu: _worktreeMenu(ws, p, w)),
            ),
          )),
    ];
  }

  List<Widget> _taskNodes(ProjectCfg p) {
    final ts = _tasksByRepo[p.name] ?? const [];
    if (ts.isEmpty) return const [];
    final header = _sectionHeader(p.path, 'tasks', '任务 (${ts.length})');
    if (_secCollapsed(p.path, 'tasks')) return [header];
    return [
      header,
      ...ts.map((it) => ListTile(
            visualDensity: _tileDensity,
            contentPadding: const EdgeInsets.only(left: 12, right: 8),
            leading: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: statusDot(
                  it.urgency == 'urgent' ? CcColors.danger : CcColors.muted,
                  size: 9,
                  glow: it.urgency == 'urgent'),
            ),
            title: Text(it.headline.isNotEmpty ? it.headline : it.sender,
                style: const TextStyle(fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            subtitle: Text('${it.sender} · ${it.state}',
                style: const TextStyle(color: CcColors.muted, fontSize: 11.5)),
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
        icon: const Icon(Icons.more_vert_rounded, size: 18),
        tooltip: '工作区操作',
        onSelected: (v) {
          switch (v) {
            case 'add':
              _addProject(ws);
            case 'settings':
              _workspaceSettings(ws);
            case 'remove':
              _removeWorkspace(ws);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'add', child: Text('添加项目')),
          PopupMenuItem(value: 'settings', child: Text('工作区设置')),
          PopupMenuItem(value: 'remove', child: Text('删除工作区')),
        ],
      );

  Future<void> _workspaceSettings(WorkspaceCfg ws) async {
    final pre = TextEditingController(text: ws.preLaunch);
    final editor = TextEditingController(text: ws.editor);
    var agent =
        (ws.agent == 'codex' || ws.agent == 'manual') ? ws.agent : 'claude';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('「${ws.name.isEmpty ? '默认' : ws.name}」工作区设置'),
        content: StatefulBuilder(
          builder: (ctx, setLocal) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                    controller: pre,
                    decoration: const InputDecoration(
                        labelText: 'pre_launch(起 agent 前跑)',
                        hintText: 'nvm use 18')),
                const SizedBox(height: 8),
                TextField(
                    controller: editor,
                    decoration: const InputDecoration(
                        labelText: 'editor(编辑器命令)', hintText: 'code .')),
                const SizedBox(height: 8),
                Row(children: [
                  const Text('agent', style: TextStyle(color: CcColors.muted)),
                  const Spacer(),
                  DropdownButton<String>(
                    value: agent,
                    items: const [
                      DropdownMenuItem(value: 'claude', child: Text('claude')),
                      DropdownMenuItem(value: 'codex', child: Text('codex')),
                      DropdownMenuItem(value: 'manual', child: Text('manual')),
                    ],
                    onChanged: (v) => setLocal(() => agent = v ?? 'claude'),
                  ),
                ]),
              ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    await _runCli(
      () => Cli.workspaceSet(ws.name,
          preLaunch: pre.text.trim(), editor: editor.text.trim(), agent: agent),
      '已保存',
      after: _reloadConfig,
    );
  }

  Widget _projectMenu(WorkspaceCfg ws, ProjectCfg p) => PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert_rounded, size: 18),
        tooltip: '项目操作',
        onSelected: (v) {
          switch (v) {
            case 'claude':
            case 'codex':
              _openAgent(p, p.path, v, ws.preLaunch);
            case 'worktree':
              _newWorktree(ws, p);
            case 'config':
              _openRepoConfig(p);
            case 'remove':
              _removeProject(ws, p);
          }
        },
        itemBuilder: (_) => [
          ..._agentItems(ws.agent),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'worktree', child: Text('新建 worktree')),
          const PopupMenuItem(value: 'config', child: Text('项目配置')),
          const PopupMenuItem(value: 'remove', child: Text('移除项目')),
        ],
      );

  void _openRepoConfig(ProjectCfg p) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            RepoConfigPage(projectPath: p.path, projectName: p.name)));
  }

  Widget _worktreeMenu(WorkspaceCfg ws, ProjectCfg p, Worktree w) =>
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert_rounded, size: 18),
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

  bool _secCollapsed(String path, String kind) =>
      Prefs.getBool('ws.sec.$path.$kind');

  void _toggleSec(String path, String kind) {
    final k = 'ws.sec.$path.$kind';
    Prefs.setBool(k, !Prefs.getBool(k));
    setState(() {});
  }

  // _sectionHeader is a collapsible group header (会话 / WORKTREES / 任务) — tap
  // to fold/unfold; state remembered via Prefs.
  Widget _sectionHeader(String path, String kind, String label) {
    final collapsed = _secCollapsed(path, kind);
    return InkWell(
      onTap: () => _toggleSec(path, kind),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 0, 5),
        child: Row(children: [
          Icon(collapsed ? Icons.chevron_right_rounded : Icons.expand_more_rounded,
              size: 16, color: CcColors.muted),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontFamily: CcType.mono,
                  color: CcColors.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5)),
        ]),
      ),
    );
  }

  Widget _quickBtn(String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 3),
        child: Tooltip(
          message: '起 $label',
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(5),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: CcColors.accent.withValues(alpha: 0.14),
                border:
                    Border.all(color: CcColors.accent.withValues(alpha: 0.35)),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(label,
                  style: const TextStyle(
                      fontFamily: CcType.mono,
                      fontSize: 11.5,
                      color: CcColors.accentBright,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      );

  // _rowActions surfaces the common 起 claude/codex buttons on hover, keeping the
  // ⋮ menu for everything else.
  Widget _rowActions(bool hovered,
          {required VoidCallback onClaude,
          required VoidCallback onCodex,
          required Widget menu}) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        if (hovered) ...[
          _quickBtn('claude', onClaude),
          _quickBtn('codex', onCodex),
        ],
        menu,
      ]);
}

// _HoverZone exposes hover state to its builder — used to reveal a row's quick
// actions only while the pointer is over it.
class _HoverZone extends StatefulWidget {
  final Widget Function(bool hovered) builder;
  const _HoverZone({required this.builder});

  @override
  State<_HoverZone> createState() => _HoverZoneState();
}

class _HoverZoneState extends State<_HoverZone> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: widget.builder(_h),
      );
}
