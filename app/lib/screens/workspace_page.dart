import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../local/cli.dart';
import '../local/config.dart';
import '../local/diff_parse.dart';
import '../local/git.dart';
import '../local/prefs.dart';
import '../local/worktrees.dart';
import '../theme.dart';
import '../widgets.dart';
import 'diff_page.dart';
import 'diff_view.dart';
import 'editor_page.dart';
import 'file_browser_page.dart';
import 'github_pr_page.dart';
import 'handoff_detail_view.dart';
import 'repo_config_page.dart';
import 'terminal_deck.dart';
import 'terminal_pane.dart';

enum _BottomTool { terminal, git }

enum _GitView { changes, log }

class _OpenFile {
  final String path;
  bool dirty = false;
  final GlobalKey<CodeEditorPaneState> key = GlobalKey<CodeEditorPaneState>();

  _OpenFile(this.path);

  String get name => path.split('/').last;
}

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
  ListItem? _detailItem;
  final List<_OpenFile> _codeFiles = [];
  int _activeFile = -1;
  _BottomTool _bottomTool =
      Prefs.getString('ws.bottomTool', def: 'terminal') == 'git'
      ? _BottomTool.git
      : _BottomTool.terminal;
  ProjectCfg? _gitProject;
  GitStatusSummary? _gitStatus;
  List<FileDiff> _gitFiles = const [];
  List<GitChange> _gitChanges = const [];
  List<GitCommit> _gitLog = const [];
  List<FileDiff> _commitFiles = const [];
  String? _selectedCommit;
  String? _compareTitle;
  List<FileDiff> _compareFiles = const [];
  String? _selectedGitPath;
  final Set<String> _selectedChangePaths = {};
  _GitView _gitView = _GitView.changes;
  final _commitCtl = TextEditingController();
  final _workspaceFocus = FocusNode(debugLabel: 'workspace-shell');
  final List<String> _recentFiles = [];
  String _logQuery = '';
  bool _gitLoading = false;
  String? _gitError;
  bool _projectCollapsed = Prefs.getBool('ws.projectCollapsed');
  bool _detailCollapsed = Prefs.getBool('ws.detailCollapsed');
  bool _terminalCollapsed = Prefs.getBool('ws.terminalCollapsed');
  double _treeWidth = Prefs.getDouble('ws.treeWidth', def: 340);
  double _detailWidth = Prefs.getDouble('ws.detailWidth', def: 520);
  double _terminalHeight = Prefs.getDouble('ws.terminalHeight', def: 360);
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
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _expandWithSessions(),
      );
    });
  }

  ExpansibleController _ctlFor(String path) =>
      _proj.putIfAbsent(path, ExpansibleController.new);

  @override
  void dispose() {
    _commitCtl.dispose();
    _workspaceFocus.dispose();
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
    await _refreshGit();
  }

  void _snack(String s) {
    if (mounted) snack(context, s);
  }

  // _runCli runs a CLI mutation with a busy indicator + friendly errors, then an
  // optional refresh (reload config / worktrees).
  Future<void> _runCli(
    Future<void> Function() action,
    String okMsg, {
    Future<void> Function()? after,
  }) async {
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
    _setTerminalCollapsed(false);
    final ctl = _ctlFor(p.path);
    if (!ctl.isExpanded) ctl.expand();
  }

  void _selectGitProject(ProjectCfg p, {bool openTool = false}) {
    setState(() {
      _gitProject = p;
      if (openTool) {
        _bottomTool = _BottomTool.git;
        _terminalCollapsed = false;
      }
    });
    if (openTool) {
      Prefs.setString('ws.bottomTool', 'git');
      Prefs.setBool('ws.terminalCollapsed', false);
    }
    _refreshGit();
  }

  Future<void> _refreshGit() async {
    final p = _gitProject ?? _defaultProject()?.project;
    if (p == null) return;
    if (_gitProject == null && mounted) setState(() => _gitProject = p);
    setState(() {
      _gitLoading = true;
      _gitError = null;
    });
    try {
      final status = await gitStatusSummary(p.path);
      final changes = await gitChanges(p.path);
      final diff = await gitDiffWorking(p.path);
      final log = await gitLog(p.path);
      if (!mounted) return;
      setState(() {
        _gitStatus = status;
        _gitChanges = changes;
        _selectedChangePaths.removeWhere(
          (path) => !changes.any((c) => c.path == path),
        );
        _gitFiles = parseUnifiedDiff(diff);
        _gitLog = log;
        if (_selectedCommit == null && log.isNotEmpty) {
          _selectedCommit = log.first.hash;
        }
        if (_selectedGitPath == null ||
            !_gitFiles.any((f) => f.path == _selectedGitPath)) {
          _selectedGitPath = _gitFiles.isEmpty ? null : _gitFiles.first.path;
        }
        _gitLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _gitError = errorText(e);
        _gitLoading = false;
      });
    }
  }

  void _openCodeFile(String path) {
    final existing = _codeFiles.indexWhere((f) => f.path == path);
    setState(() {
      if (existing >= 0) {
        _activeFile = existing;
      } else {
        _codeFiles.add(_OpenFile(path));
        _activeFile = _codeFiles.length - 1;
      }
      _recentFiles.remove(path);
      _recentFiles.insert(0, path);
      if (_recentFiles.length > 12) {
        _recentFiles.removeRange(12, _recentFiles.length);
      }
    });
  }

  Future<void> _closeCodeFile(int i) async {
    if (i < 0 || i >= _codeFiles.length) return;
    final f = _codeFiles[i];
    if (f.dirty) {
      final ok = await _confirm(
        '关闭未保存文件?',
        '${f.path}\n\n未保存修改会保留在编辑器里,关闭后需要重新打开。',
      );
      if (!ok) return;
    }
    setState(() {
      _codeFiles.removeAt(i);
      if (_codeFiles.isEmpty) {
        _activeFile = -1;
      } else if (_activeFile >= _codeFiles.length) {
        _activeFile = _codeFiles.length - 1;
      } else if (_activeFile > i) {
        _activeFile--;
      }
    });
  }

  Future<void> _showRecentFiles() async {
    if (_recentFiles.isEmpty) {
      _snack('暂无最近文件');
      return;
    }
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('最近文件'),
        children: [
          for (final p in _recentFiles)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: Row(
                children: [
                  Icon(_iconForFile(p), size: 16, color: CcColors.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      p,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CcType.code(size: 12.5),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (path != null) _openCodeFile(path);
  }

  Future<void> _showQuickOpen() async {
    final d = _defaultProject();
    if (d == null) {
      _snack('没有可搜索的项目');
      return;
    }
    final path = await showDialog<String>(
      context: context,
      builder: (_) => _QuickOpenDialog(workspaces: _cfg.workspaces),
    );
    if (path != null) _openCodeFile(path);
  }

  Future<void> _showShortcuts() async {
    final isMac = Platform.isMacOS;
    final mod = isMac ? 'Cmd' : 'Ctrl';
    final rows = [
      ('$mod+O', '快速打开文件'),
      ('$mod+E', '最近文件'),
      ('$mod+1', '切换 Project'),
      ('$mod+9', '打开 Git / Commit'),
      (isMac ? 'Option+F12' : 'Alt+F12', '打开 Terminal'),
      ('$mod+S', '保存当前文件'),
    ];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('快捷键'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      SizedBox(width: 112, child: chip(r.$1)),
                      const SizedBox(width: 12),
                      Expanded(child: Text(r.$2)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
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
      (
        label: '根目录(可选)',
        hint: '默认 ~/cc-handoff-workspaces/<名>',
        required: false,
      ),
    ]);
    if (v == null) return;
    await _runCli(
      () => Cli.workspaceCreate(v[0], path: v[1].isEmpty ? null : v[1]),
      '已建工作区 ${v[0]}',
      after: _reloadConfig,
    );
  }

  Future<void> _addProject(WorkspaceCfg ws) async {
    final v = await _fieldsDialog('给「${ws.name}」添加项目', '添加', [
      (
        label: 'GitHub URL 或本地路径',
        hint: 'https://github.com/org/repo.git',
        required: true,
      ),
    ]);
    if (v == null) return;
    await _runCli(
      () => Cli.workspaceAdd(ws.name, v[0]),
      '已添加(URL 会先 clone)',
      after: _reloadConfig,
    );
  }

  Future<void> _removeWorkspace(WorkspaceCfg ws) async {
    if (!await _confirm('删除工作区「${ws.name}」?', '只从 config 移除,磁盘文件保留。')) return;
    await _runCli(
      () => Cli.workspaceRemove(ws.name),
      '已删除',
      after: _reloadConfig,
    );
  }

  Future<void> _removeProject(WorkspaceCfg ws, ProjectCfg p) async {
    if (!await _confirm(
      '从「${ws.name}」移除项目「${p.name}」?',
      '只从 config 移除,磁盘文件保留。',
    )) {
      return;
    }
    await _runCli(
      () => Cli.projectRemove(ws.name, p.name),
      '已移除',
      after: _reloadConfig,
    );
  }

  Future<void> _newWorktree(WorkspaceCfg ws, ProjectCfg p) async {
    final v = await _fieldsDialog('在「${p.name}」新建 worktree', '创建', [
      (label: '分支名', hint: 'feature/x', required: true),
      (label: '起点 ref(可选)', hint: '默认当前 HEAD', required: false),
    ]);
    if (v == null) return;
    await _runCli(
      () => Cli.worktreeAdd(
        p.name,
        v[0],
        workspace: ws.name,
        start: v[1].isEmpty ? null : v[1],
      ),
      '已建 worktree',
      after: () => _reloadWorktrees(p.path),
    );
  }

  Future<void> _deleteWorktree(
    WorkspaceCfg ws,
    ProjectCfg p,
    Worktree w,
  ) async {
    final br = w.branch.isEmpty ? w.name : w.branch;
    if (!await _confirm(
      '删除 worktree「$br」?',
      '会执行 git worktree remove --force。',
    )) {
      return;
    }
    await _runCli(
      () => Cli.worktreeRemove(p.name, br, workspace: ws.name, force: true),
      '已删除',
      after: () => _reloadWorktrees(p.path),
    );
  }

  // ------------------------------------------------------------- dialogs ----

  Future<List<String>?> _fieldsDialog(
    String title,
    String okLabel,
    List<({String label, String? hint, bool required})> fields,
  ) async {
    final ctls = [for (final _ in fields) TextEditingController()];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < fields.length; i++)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                child: TextField(
                  controller: ctls[i],
                  autofocus: i == 0,
                  decoration: InputDecoration(
                    labelText: fields[i].label,
                    hintText: fields[i].hint,
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(okLabel),
          ),
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
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _openTask(ListItem it) {
    setState(() {
      _detailItem = it;
      _detailCollapsed = false;
    });
    Prefs.setBool('ws.detailCollapsed', false);
  }

  // ---------------------------------------------------------------- view ----

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true):
            _showQuickOpen,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true):
            _showQuickOpen,
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true):
            _showRecentFiles,
        const SingleActivator(LogicalKeyboardKey.keyE, control: true):
            _showRecentFiles,
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true):
            _toggleProjectShortcut,
        const SingleActivator(LogicalKeyboardKey.digit1, control: true):
            _toggleProjectShortcut,
        const SingleActivator(LogicalKeyboardKey.digit9, meta: true):
            _openGitShortcut,
        const SingleActivator(LogicalKeyboardKey.digit9, control: true):
            _openGitShortcut,
        const SingleActivator(LogicalKeyboardKey.f12, alt: true):
            _openTerminalShortcut,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
            _saveActiveFile,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true):
            _saveActiveFile,
      },
      child: Focus(
        focusNode: _workspaceFocus,
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ideToolbar(),
              Expanded(child: _ideBody()),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleProjectShortcut() => _setProjectCollapsed(!_projectCollapsed);

  void _openGitShortcut() => _setBottomTool(_BottomTool.git);

  void _openTerminalShortcut() => _setBottomTool(_BottomTool.terminal);

  void _saveActiveFile() {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) return;
    _codeFiles[_activeFile].key.currentState?.save();
  }

  Widget _ideToolbar() {
    final projects = _cfg.workspaces.fold<int>(
      0,
      (sum, ws) => sum + ws.projects.length,
    );
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: CcColors.toolbar,
        border: Border(bottom: BorderSide(color: CcColors.border)),
      ),
      child: Row(
        children: [
          _toolButton(
            icon: Icons.account_tree_outlined,
            tooltip: _projectCollapsed ? '展开 Project' : '收起 Project',
            selected: !_projectCollapsed,
            onPressed: () => _setProjectCollapsed(!_projectCollapsed),
          ),
          _toolButton(
            icon: Icons.description_outlined,
            tooltip: _detailCollapsed ? '展开 Handoff' : '收起 Handoff',
            selected: !_detailCollapsed && _detailItem != null,
            onPressed: _detailItem == null
                ? null
                : () => _setDetailCollapsed(!_detailCollapsed),
          ),
          _toolButton(
            icon: Icons.terminal_rounded,
            tooltip: _terminalCollapsed ? '展开 Terminal' : '收起 Terminal',
            selected:
                !_terminalCollapsed && _bottomTool == _BottomTool.terminal,
            onPressed: () => _setBottomTool(_BottomTool.terminal),
          ),
          _toolButton(
            icon: Icons.alt_route_rounded,
            tooltip: 'Git / Commit',
            selected: !_terminalCollapsed && _bottomTool == _BottomTool.git,
            onPressed: () => _setBottomTool(_BottomTool.git),
          ),
          const VerticalDivider(width: 14),
          _toolButton(
            icon: Icons.search_rounded,
            tooltip: '快速打开文件',
            selected: false,
            onPressed: _showQuickOpen,
          ),
          _toolButton(
            icon: Icons.history_rounded,
            tooltip: '最近文件',
            selected: false,
            onPressed: _showRecentFiles,
          ),
          _toolButton(
            icon: Icons.keyboard_command_key_rounded,
            tooltip: '快捷键',
            selected: false,
            onPressed: _showShortcuts,
          ),
          _runChip('Claude', Icons.play_arrow_rounded, _launchDefaultClaude),
          _runChip('Codex', Icons.smart_toy_outlined, _launchDefaultCodex),
          const Spacer(),
          if (_busy)
            const SizedBox(
              width: 130,
              child: LinearProgressIndicator(minHeight: 2),
            )
          else ...[
            Icon(Icons.folder_copy_outlined, size: 15, color: CcColors.muted),
            const SizedBox(width: 6),
            Text(
              '$projects projects',
              style: CcType.code(size: 11.5, color: CcColors.muted),
            ),
          ],
          const SizedBox(width: 12),
          Text(
            '${terms.length} sessions',
            style: CcType.code(size: 11.5, color: CcColors.subtle),
          ),
        ],
      ),
    );
  }

  void _setProjectCollapsed(bool v) {
    setState(() => _projectCollapsed = v);
    Prefs.setBool('ws.projectCollapsed', v);
  }

  void _setDetailCollapsed(bool v) {
    setState(() => _detailCollapsed = v);
    Prefs.setBool('ws.detailCollapsed', v);
  }

  void _setTerminalCollapsed(bool v) {
    setState(() => _terminalCollapsed = v);
    Prefs.setBool('ws.terminalCollapsed', v);
  }

  ({WorkspaceCfg ws, ProjectCfg project})? _defaultProject() {
    for (final ws in _cfg.workspaces) {
      if (ws.projects.isNotEmpty) return (ws: ws, project: ws.projects.first);
    }
    return null;
  }

  void _launchDefaultClaude() {
    final d = _defaultProject();
    if (d == null) {
      _snack('没有可启动的项目');
      return;
    }
    _openAgent(d.project, d.project.path, 'claude', d.ws.preLaunch);
    _setTerminalCollapsed(false);
  }

  void _launchDefaultCodex() {
    final d = _defaultProject();
    if (d == null) {
      _snack('没有可启动的项目');
      return;
    }
    _openAgent(d.project, d.project.path, 'codex', d.ws.preLaunch);
    _setTerminalCollapsed(false);
  }

  Widget _toolButton({
    required IconData icon,
    required String tooltip,
    required bool selected,
    required VoidCallback? onPressed,
  }) => Padding(
    padding: const EdgeInsets.only(right: 2),
    child: Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 18),
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          foregroundColor: selected ? CcColors.text : CcColors.muted,
          backgroundColor: selected
              ? CcColors.accent.withValues(alpha: 0.16)
              : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
      ),
    ),
  );

  Widget _runChip(String label, IconData icon, VoidCallback onPressed) =>
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 15),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            foregroundColor: CcColors.text,
            side: const BorderSide(color: CcColors.borderSoft),
            visualDensity: VisualDensity.compact,
          ),
        ),
      );

  Widget _toolStripe({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool right = false,
  }) => InkWell(
    onTap: onTap,
    child: Container(
      width: 32,
      decoration: BoxDecoration(
        color: CcColors.panel,
        border: Border(
          left: right
              ? const BorderSide(color: CcColors.border)
              : BorderSide.none,
          right: right
              ? BorderSide.none
              : const BorderSide(color: CcColors.border),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Icon(icon, size: 17, color: CcColors.muted),
          const SizedBox(height: 8),
          Expanded(
            child: RotatedBox(
              quarterTurns: right ? 1 : 3,
              child: Center(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: CcColors.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _ideBody() {
    final terminalOpen = !_terminalCollapsed;
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              _leftToolWindowBar(),
              if (!_projectCollapsed) ...[
                SizedBox(width: _treeWidth, child: _sidebar()),
                resizeHandle(
                  prefKey: 'ws.treeWidth',
                  get: () => _treeWidth,
                  set: (v) => setState(() => _treeWidth = v),
                  min: 260,
                  max: 520,
                ),
              ],
              Expanded(child: _editorArea()),
              if (_detailItem != null) ...[
                if (!_detailCollapsed) ...[
                  resizeHandle(
                    prefKey: 'ws.detailWidth',
                    get: () => _detailWidth,
                    set: (v) => setState(() => _detailWidth = v),
                    min: 360,
                    max: 820,
                    invert: true,
                  ),
                  SizedBox(
                    width: _detailWidth,
                    child: _detailPanel(_detailItem!),
                  ),
                ] else
                  _toolStripe(
                    icon: Icons.description_outlined,
                    label: 'Handoff',
                    right: true,
                    onTap: () => _setDetailCollapsed(false),
                  ),
              ],
            ],
          ),
        ),
        if (terminalOpen) ...[
          _horizontalResizeHandle(),
          SizedBox(height: _terminalHeight, child: _terminalToolWindow()),
        ] else
          _bottomStripe(),
      ],
    );
  }

  Widget _leftToolWindowBar() => Container(
    width: 38,
    decoration: const BoxDecoration(
      color: CcColors.toolbar,
      border: Border(right: BorderSide(color: CcColors.border)),
    ),
    child: Column(
      children: [
        const SizedBox(height: 6),
        _leftToolButton(
          icon: Icons.account_tree_outlined,
          label: 'Project',
          selected: !_projectCollapsed,
          onTap: () => _setProjectCollapsed(!_projectCollapsed),
        ),
        _leftToolButton(
          icon: Icons.alt_route_rounded,
          label: 'Commit',
          selected: !_terminalCollapsed && _bottomTool == _BottomTool.git,
          onTap: () => _setBottomTool(_BottomTool.git),
        ),
        _leftToolButton(
          icon: Icons.terminal_rounded,
          label: 'Terminal',
          selected: !_terminalCollapsed && _bottomTool == _BottomTool.terminal,
          onTap: () => _setBottomTool(_BottomTool.terminal),
        ),
        _leftToolButton(
          icon: Icons.description_outlined,
          label: 'Handoff',
          selected: _detailItem != null && !_detailCollapsed,
          enabled: _detailItem != null,
          onTap: () => _setDetailCollapsed(!_detailCollapsed),
        ),
        _leftToolButton(
          icon: Icons.search_rounded,
          label: 'Search',
          selected: false,
          onTap: _showQuickOpen,
        ),
        const Spacer(),
        _leftToolButton(
          icon: Icons.keyboard_command_key_rounded,
          label: 'Shortcuts',
          selected: false,
          onTap: _showShortcuts,
        ),
        _leftToolButton(
          icon: Icons.refresh_rounded,
          label: 'Refresh',
          selected: false,
          onTap: _refresh,
        ),
        const SizedBox(height: 6),
      ],
    ),
  );

  Widget _leftToolButton({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    bool enabled = true,
  }) => Tooltip(
    message: label,
    preferBelow: false,
    child: InkWell(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 38,
        height: 42,
        decoration: BoxDecoration(
          color: selected
              ? CcColors.accent.withValues(alpha: 0.14)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: selected ? CcColors.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Icon(
          icon,
          size: 18,
          color: !enabled
              ? CcColors.subtle.withValues(alpha: 0.55)
              : selected
              ? CcColors.accentBright
              : CcColors.muted,
        ),
      ),
    ),
  );

  Widget _editorArea() => Column(
    children: [
      _editorTabs(),
      Expanded(child: _editorCanvas()),
    ],
  );

  Widget _editorTabs() {
    final title = _detailItem?.headline.isNotEmpty == true
        ? _detailItem!.headline
        : _detailItem?.id ?? 'Workspace';
    final hasActiveFile = _activeFile >= 0 && _activeFile < _codeFiles.length;
    return Container(
      height: 36,
      decoration: const BoxDecoration(
        color: CcColors.editorTabBar,
        border: Border(bottom: BorderSide(color: CcColors.border)),
      ),
      child: Row(
        children: [
          _editorTab(
            icon: Icons.home_work_outlined,
            label: 'Workspace',
            active: !hasActiveFile && _detailItem == null,
            onTap: () => setState(() => _activeFile = -1),
          ),
          for (var i = 0; i < _codeFiles.length; i++)
            _editorTab(
              icon: _iconForFile(_codeFiles[i].path),
              label: '${_codeFiles[i].dirty ? '● ' : ''}${_codeFiles[i].name}',
              active: i == _activeFile,
              onTap: () => setState(() => _activeFile = i),
              onClose: () => _closeCodeFile(i),
            ),
          if (_detailItem != null)
            _editorTab(
              icon: Icons.description_outlined,
              label: title,
              active: !hasActiveFile,
              onTap: () {
                setState(() => _activeFile = -1);
                _setDetailCollapsed(false);
              },
              onClose: () => setState(() => _detailItem = null),
            ),
          const Spacer(),
          if (hasActiveFile)
            IconButton(
              icon: const Icon(Icons.save_rounded, size: 17),
              tooltip: '保存',
              visualDensity: VisualDensity.compact,
              onPressed: _codeFiles[_activeFile].dirty
                  ? _codeFiles[_activeFile].key.currentState?.save
                  : null,
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 17),
            tooltip: '刷新',
            visualDensity: VisualDensity.compact,
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
    );
  }

  Widget _editorTab({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
    VoidCallback? onClose,
  }) => InkWell(
    onTap: onTap,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 240),
      height: 36,
      padding: const EdgeInsets.only(left: 12, right: 6),
      decoration: BoxDecoration(
        color: active ? CcColors.editor : CcColors.editorTabBar,
        border: Border(
          right: const BorderSide(color: CcColors.border),
          top: BorderSide(
            color: active ? CcColors.accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 15,
            color: active ? CcColors.accentBright : CcColors.muted,
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: active ? CcColors.text : CcColors.muted,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
          if (onClose != null) ...[
            const SizedBox(width: 6),
            InkWell(
              onTap: onClose,
              borderRadius: BorderRadius.circular(4),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: CcColors.muted,
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _editorCanvas() {
    if (_activeFile >= 0 && _activeFile < _codeFiles.length) {
      final f = _codeFiles[_activeFile];
      return CodeEditorPane(
        key: f.key,
        path: f.path,
        onDirtyChanged: (v) {
          if (!mounted) return;
          setState(() => f.dirty = v);
        },
      );
    }
    if (terms.isNotEmpty && _terminalCollapsed) return terminalBody();
    return _workspaceWelcome();
  }

  IconData _iconForFile(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'go' => Icons.data_object_rounded,
      'dart' || 'ts' || 'tsx' || 'js' || 'jsx' => Icons.code_rounded,
      'md' || 'markdown' => Icons.article_outlined,
      'json' || 'yaml' || 'yml' || 'toml' => Icons.tune_rounded,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  Widget _workspaceWelcome() {
    final ws =
        _cfg.workspaces.isNotEmpty && _cfg.workspaces.first.name.isNotEmpty
        ? _cfg.workspaces.first.name
        : 'workspace';
    final taskCount = _tasksByRepo.values.fold<int>(
      0,
      (sum, items) => sum + items.length,
    );
    return DecoratedBox(
      decoration: appGradient,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: CcColors.panelHigh,
                        border: Border.all(color: CcColors.borderSoft),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.terminal_rounded,
                        color: CcColors.accentBright,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ws,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            'Project tool window · Terminal · Handoff',
                            style: CcType.code(
                              size: 12,
                              color: CcColors.subtle,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _welcomeAction(
                      'New Workspace',
                      Icons.add_rounded,
                      _busy ? null : _newWorkspace,
                    ),
                    _welcomeAction(
                      'Refresh',
                      Icons.refresh_rounded,
                      _busy ? null : _refresh,
                    ),
                    _welcomeAction(
                      'Open Project',
                      Icons.account_tree_outlined,
                      () => _setProjectCollapsed(false),
                    ),
                    _welcomeAction(
                      'Show Terminal',
                      Icons.terminal_rounded,
                      () => _setTerminalCollapsed(false),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    _metric('tasks', '$taskCount', CcColors.warning),
                    const SizedBox(width: 10),
                    _metric('sessions', '${terms.length}', CcColors.ok),
                    const SizedBox(width: 10),
                    _metric(
                      'workspaces',
                      '${_cfg.workspaces.length}',
                      CcColors.accent,
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

  Widget _welcomeAction(String label, IconData icon, VoidCallback? onTap) =>
      OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          visualDensity: VisualDensity.compact,
        ),
      );

  Widget _metric(String label, String value, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: CcColors.panel,
      border: Border.all(color: CcColors.border),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        statusDot(color, size: 7, glow: true),
        const SizedBox(width: 7),
        Text(value, style: CcType.code(size: 12.5, color: CcColors.text)),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(color: CcColors.muted, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _horizontalResizeHandle() => MouseRegion(
    cursor: SystemMouseCursors.resizeRow,
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: (d) {
        setState(() {
          _terminalHeight = (_terminalHeight - d.delta.dy).clamp(220.0, 620.0);
        });
      },
      onVerticalDragEnd: (_) =>
          Prefs.setDouble('ws.terminalHeight', _terminalHeight),
      child: Container(
        height: 7,
        color: CcColors.bg,
        alignment: Alignment.center,
        child: Container(height: 1, color: CcColors.border),
      ),
    ),
  );

  Widget _bottomStripe() => InkWell(
    onTap: () => _setBottomTool(_bottomTool),
    child: Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: CcColors.panel,
        border: Border(top: BorderSide(color: CcColors.border)),
      ),
      child: Row(
        children: [
          Icon(
            _bottomTool == _BottomTool.git
                ? Icons.alt_route_rounded
                : Icons.terminal_rounded,
            size: 15,
            color: CcColors.muted,
          ),
          const SizedBox(width: 8),
          Text(
            _bottomTool == _BottomTool.git ? 'Git' : 'Terminal',
            style: TextStyle(
              color: CcColors.muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _bottomTool == _BottomTool.git
                ? (_gitStatus?.branch ?? '')
                : '${terms.length}',
            style: CcType.code(size: 11, color: CcColors.subtle),
          ),
        ],
      ),
    ),
  );

  // _panelHeader is the shared tool-window header chrome.
  Widget _panelHeader({
    required EdgeInsetsGeometry padding,
    bool gradient = false,
    double height = 34,
    required List<Widget> children,
  }) => Container(
    height: height,
    padding: padding,
    decoration: BoxDecoration(
      color: gradient ? null : CcColors.panel,
      gradient: gradient ? panelGradient.gradient : null,
      border: const Border(bottom: BorderSide(color: CcColors.border)),
    ),
    child: Row(children: children),
  );

  // _detailPanel hosts a task's 对接文档 inside the right tool window.
  Widget _detailPanel(ListItem it) => Column(
    children: [
      _panelHeader(
        padding: const EdgeInsets.only(left: 10, right: 4),
        children: [
          const Icon(
            Icons.description_outlined,
            size: 16,
            color: CcColors.muted,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Handoff',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz_rounded, size: 17),
            tooltip: '收起',
            visualDensity: VisualDensity.compact,
            onPressed: () => _setDetailCollapsed(true),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 17),
            tooltip: '关闭文档',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _detailItem = null),
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
            _setTerminalCollapsed(false);
          },
          onSendToTerminal: sendToTerminal,
          onChanged: _loadTasks,
        ),
      ),
    ],
  );

  void _setBottomTool(_BottomTool tool) {
    setState(() {
      _bottomTool = tool;
      _terminalCollapsed = false;
    });
    Prefs.setString(
      'ws.bottomTool',
      tool == _BottomTool.git ? 'git' : 'terminal',
    );
    Prefs.setBool('ws.terminalCollapsed', false);
    if (tool == _BottomTool.git) _refreshGit();
  }

  Future<void> _selectCommit(ProjectCfg p, GitCommit c) async {
    setState(() {
      _selectedCommit = c.hash;
      _compareTitle = null;
      _compareFiles = const [];
      _gitLoading = true;
    });
    try {
      final diff = await gitShowCommit(p.path, c.hash);
      if (!mounted) return;
      setState(() {
        _commitFiles = parseUnifiedDiff(diff);
        _gitLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _compareBranch(ProjectCfg p, GitBranch b) async {
    final right = _gitStatus?.branch ?? 'HEAD';
    setState(() {
      _gitView = _GitView.log;
      _bottomTool = _BottomTool.git;
      _terminalCollapsed = false;
      _compareTitle = '${b.name}...$right';
      _gitLoading = true;
    });
    try {
      final diff = await gitDiffRefs(p.path, b.name, right);
      if (!mounted) return;
      setState(() {
        _compareFiles = parseUnifiedDiff(diff);
        _commitFiles = const [];
        _gitLoading = false;
      });
      Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Widget _terminalToolWindow() {
    if (_bottomTool == _BottomTool.git) return _gitToolWindow();
    return Column(
      children: [
        _panelHeader(
          padding: const EdgeInsets.only(left: 10, right: 4),
          children: [
            _bottomTab(
              icon: Icons.terminal_rounded,
              label: 'Terminal',
              selected: true,
              onTap: () => _setBottomTool(_BottomTool.terminal),
            ),
            _bottomTab(
              icon: Icons.alt_route_rounded,
              label: 'Git',
              selected: false,
              onTap: () => _setBottomTool(_BottomTool.git),
            ),
            const SizedBox(width: 10),
            Text(
              '${terms.length}',
              style: CcType.code(size: 11.5, color: CcColors.subtle),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
              tooltip: '收起 Terminal',
              visualDensity: VisualDensity.compact,
              onPressed: () => _setTerminalCollapsed(true),
            ),
          ],
        ),
        Expanded(child: _termArea()),
      ],
    );
  }

  Widget _bottomTab({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(4),
    child: Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: selected
            ? CcColors.accent.withValues(alpha: 0.14)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 15,
            color: selected ? CcColors.accentBright : CcColors.muted,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: selected ? CcColors.text : CcColors.muted,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _gitToolWindow() {
    final p = _gitProject ?? _defaultProject()?.project;
    final status = _gitStatus;
    return Column(
      children: [
        _panelHeader(
          padding: const EdgeInsets.only(left: 10, right: 4),
          children: [
            _bottomTab(
              icon: Icons.terminal_rounded,
              label: 'Terminal',
              selected: false,
              onTap: () => _setBottomTool(_BottomTool.terminal),
            ),
            _bottomTab(
              icon: Icons.alt_route_rounded,
              label: 'Git',
              selected: true,
              onTap: () => _setBottomTool(_BottomTool.git),
            ),
            _bottomTab(
              icon: Icons.list_alt_rounded,
              label: 'Changes',
              selected: _gitView == _GitView.changes,
              onTap: () => setState(() => _gitView = _GitView.changes),
            ),
            _bottomTab(
              icon: Icons.history_rounded,
              label: 'Log',
              selected: _gitView == _GitView.log,
              onTap: () => setState(() => _gitView = _GitView.log),
            ),
            const SizedBox(width: 10),
            if (p != null)
              Expanded(
                child: Row(
                  children: [
                    Text(
                      p.name,
                      style: CcType.code(size: 11.5, color: CcColors.muted),
                    ),
                    const SizedBox(width: 8),
                    _branchButton(status?.branch ?? 'branch'),
                    if (status != null &&
                        (status.ahead > 0 || status.behind > 0)) ...[
                      const SizedBox(width: 8),
                      tag(
                        '↑${status.ahead} ↓${status.behind}',
                        CcColors.warning,
                      ),
                    ],
                  ],
                ),
              )
            else
              const Expanded(child: Text('Git')),
            IconButton(
              icon: const Icon(Icons.add_task_rounded, size: 17),
              tooltip: 'Stage All',
              visualDensity: VisualDensity.compact,
              onPressed: p == null ? null : () => _gitStageAllCurrent(p),
            ),
            IconButton(
              icon: const Icon(Icons.remove_done_rounded, size: 17),
              tooltip: 'Unstage All',
              visualDensity: VisualDensity.compact,
              onPressed: p == null || (status?.staged ?? 0) == 0
                  ? null
                  : () => _gitUnstageAllCurrent(p),
            ),
            IconButton(
              icon: const Icon(Icons.upload_rounded, size: 17),
              tooltip: 'Push',
              visualDensity: VisualDensity.compact,
              onPressed: p == null ? null : () => _gitPushCurrent(p),
            ),
            IconButton(
              icon: const Icon(Icons.call_received_rounded, size: 17),
              tooltip: 'Pull --ff-only',
              visualDensity: VisualDensity.compact,
              onPressed: p == null ? null : () => _gitPullCurrent(p),
            ),
            IconButton(
              icon: const Icon(Icons.sync_rounded, size: 17),
              tooltip: 'Fetch',
              visualDensity: VisualDensity.compact,
              onPressed: p == null ? null : () => _gitFetchCurrent(p),
            ),
            IconButton(
              icon: const Icon(Icons.cleaning_services_outlined, size: 17),
              tooltip: 'Fetch --prune',
              visualDensity: VisualDensity.compact,
              onPressed: p == null
                  ? null
                  : () => _gitFetchCurrent(p, prune: true),
            ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 17),
              tooltip: '刷新 Git',
              visualDensity: VisualDensity.compact,
              onPressed: _refreshGit,
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
              tooltip: '收起 Git',
              visualDensity: VisualDensity.compact,
              onPressed: () => _setTerminalCollapsed(true),
            ),
          ],
        ),
        if (_gitLoading) const LinearProgressIndicator(minHeight: 2),
        if (p == null)
          Expanded(child: centerMsg('没有可用项目'))
        else if (_gitError != null)
          Expanded(child: centerMsg(_gitError!, onRetry: _refreshGit))
        else
          Expanded(
            child: Column(
              children: [
                _gitSummaryBar(status),
                if (_gitView == _GitView.changes) _commitBox(p, status),
                Expanded(child: _gitToolBody(p)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _gitToolBody(ProjectCfg p) {
    if (_gitView == _GitView.log) {
      if (_compareTitle == null &&
          _commitFiles.isEmpty &&
          _selectedCommit != null &&
          !_gitLoading) {
        final hit = _gitLog.where((c) => c.hash == _selectedCommit).toList();
        if (hit.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _selectCommit(p, hit.first);
          });
        }
      }
      return _gitLogView(p);
    }
    return _gitFiles.isEmpty && _gitChanges.isEmpty
        ? centerMsg('Working tree clean')
        : _localChangesView(p);
  }

  Widget _localChangesView(ProjectCfg p) {
    final selected = _selectedGitPath == null
        ? const <FileDiff>[]
        : _gitFiles.where((f) => f.path == _selectedGitPath).toList();
    return Row(
      children: [
        SizedBox(width: 320, child: _localChangesList(p)),
        const VerticalDivider(width: 1),
        Expanded(
          child: selected.isEmpty
              ? centerMsg('选择一个变更文件')
              : DiffView(
                  files: selected,
                  editRoot: p.path,
                  onChanged: _refreshGit,
                ),
        ),
      ],
    );
  }

  Widget _localChangesList(ProjectCfg p) => DecoratedBox(
    decoration: const BoxDecoration(color: CcColors.panel),
    child: Column(
      children: [
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            color: CcColors.editorTabBar,
            border: Border(bottom: BorderSide(color: CcColors.border)),
          ),
          child: Row(
            children: [
              const Text(
                'Local Changes',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              TextButton(
                onPressed: _gitChanges.isEmpty
                    ? null
                    : () => setState(() {
                        _selectedChangePaths
                          ..clear()
                          ..addAll(_gitChanges.map((c) => c.path));
                      }),
                child: const Text('All'),
              ),
              TextButton(
                onPressed: _selectedChangePaths.isEmpty
                    ? null
                    : () => setState(() => _selectedChangePaths.clear()),
                child: const Text('None'),
              ),
              Text(
                '${_gitChanges.length}',
                style: CcType.code(size: 11, color: CcColors.subtle),
              ),
            ],
          ),
        ),
        Expanded(child: ListView(children: _changeGroups(p))),
      ],
    ),
  );

  List<Widget> _changeGroups(ProjectCfg p) {
    final conflicts = _gitChanges.where((c) => c.conflicted).toList();
    final staged = _gitChanges.where((c) => c.staged && !c.conflicted).toList();
    final untracked = _gitChanges.where((c) => c.untracked).toList();
    final unstaged = _gitChanges
        .where((c) => c.unstaged && !c.untracked && !c.conflicted)
        .toList();
    return [
      ..._changeGroup(p, 'Conflicts', conflicts, CcColors.danger),
      ..._changeGroup(p, 'Staged', staged, CcColors.ok),
      ..._changeGroup(p, 'Unstaged', unstaged, CcColors.warning),
      ..._changeGroup(p, 'Untracked', untracked, CcColors.accentBright),
    ];
  }

  List<Widget> _changeGroup(
    ProjectCfg p,
    String label,
    List<GitChange> changes,
    Color color,
  ) {
    if (changes.isEmpty) return const [];
    return [
      Container(
        height: 28,
        padding: const EdgeInsets.only(left: 10, right: 8),
        color: CcColors.editorTabBar,
        child: Row(
          children: [
            statusDot(color, size: 6),
            const SizedBox(width: 7),
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 6),
            Text(
              '${changes.length}',
              style: CcType.code(size: 11, color: CcColors.subtle),
            ),
          ],
        ),
      ),
      for (final c in changes) _changeTile(p, c),
    ];
  }

  Widget _changeTile(ProjectCfg p, GitChange c) {
    final sel = c.path == _selectedGitPath;
    final checked = _selectedChangePaths.contains(c.path);
    return Container(
      decoration: BoxDecoration(
        color: sel
            ? CcColors.accent.withValues(alpha: 0.10)
            : Colors.transparent,
        border: Border(
          left: BorderSide(
            color: sel ? CcColors.accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: InkWell(
        onDoubleTap: () => _openCodeFile('${p.path}/${c.path}'),
        child: ListTile(
          dense: true,
          visualDensity: const VisualDensity(vertical: -2),
          contentPadding: const EdgeInsets.only(left: 8, right: 2),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: checked,
                visualDensity: VisualDensity.compact,
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _selectedChangePaths.add(c.path);
                  } else {
                    _selectedChangePaths.remove(c.path);
                  }
                }),
              ),
              Text(
                c.status,
                style: CcType.code(
                  size: 11.5,
                  color: _changeColor(c),
                  weight: FontWeight.w700,
                ),
              ),
            ],
          ),
          minLeadingWidth: 58,
          title: Text(
            c.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CcType.code(size: 12),
          ),
          subtitle: c.oldPath == null
              ? null
              : Text(
                  'from ${c.oldPath}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 10.5, color: CcColors.subtle),
                ),
          trailing: PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, size: 17),
            tooltip: '文件操作',
            onSelected: (v) {
              if (v == 'stage') _gitStageFileCurrent(p, c.path);
              if (v == 'unstage') _gitUnstageFileCurrent(p, c.path);
              if (v == 'open') _openCodeFile('${p.path}/${c.path}');
              if (v == 'discard') _gitDiscardFileCurrent(p, c.path);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'open', child: Text('Open')),
              if (c.unstaged)
                const PopupMenuItem(value: 'stage', child: Text('Stage')),
              if (c.staged)
                const PopupMenuItem(value: 'unstage', child: Text('Unstage')),
              const PopupMenuItem(value: 'discard', child: Text('Discard')),
            ],
          ),
          onTap: () => setState(() => _selectedGitPath = c.path),
        ),
      ),
    );
  }

  Color _changeColor(GitChange c) {
    if (c.conflicted) return CcColors.danger;
    if (c.untracked) return CcColors.accentBright;
    if (c.staged) return CcColors.ok;
    return CcColors.warning;
  }

  Widget _gitLogView(ProjectCfg p) {
    if (_gitLog.isEmpty) return centerMsg('没有 commit');
    final q = _logQuery.trim().toLowerCase();
    final commits = q.isEmpty
        ? _gitLog
        : _gitLog
              .where(
                (c) =>
                    c.subject.toLowerCase().contains(q) ||
                    c.author.toLowerCase().contains(q) ||
                    c.hash.toLowerCase().contains(q) ||
                    c.shortHash.toLowerCase().contains(q) ||
                    c.refs.toLowerCase().contains(q),
              )
              .toList();
    final selected = _compareTitle != null
        ? _compareFiles
        : _commitFiles.isNotEmpty
        ? _commitFiles
        : const <FileDiff>[];
    return Row(
      children: [
        SizedBox(
          width: 430,
          child: DecoratedBox(
            decoration: const BoxDecoration(color: CcColors.panel),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Filter log',
                      isDense: true,
                      prefixIcon: Icon(Icons.search_rounded, size: 17),
                    ),
                    onChanged: (v) => setState(() => _logQuery = v),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: commits.isEmpty
                      ? centerMsg('没有匹配 commit')
                      : ListView.separated(
                          itemCount: commits.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1, color: CcColors.border),
                          itemBuilder: (_, i) {
                            final c = commits[i];
                            final sel =
                                c.hash == _selectedCommit &&
                                _compareTitle == null;
                            final age = c.date.millisecondsSinceEpoch == 0
                                ? ''
                                : relativeTime(c.date);
                            return Container(
                              color: sel
                                  ? CcColors.accent.withValues(alpha: 0.10)
                                  : Colors.transparent,
                              child: ListTile(
                                dense: true,
                                leading: Icon(
                                  Icons.commit_rounded,
                                  size: 17,
                                  color: sel
                                      ? CcColors.accentBright
                                      : CcColors.muted,
                                ),
                                title: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        c.subject,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13.5),
                                      ),
                                    ),
                                    if (c.refs.isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: tag(
                                          c.refs,
                                          CcColors.accentBright,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                subtitle: Text(
                                  '${c.shortHash} · ${c.author}${age.isEmpty ? '' : ' · $age'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: CcType.code(
                                    size: 11.5,
                                    color: CcColors.muted,
                                  ),
                                ),
                                onTap: () => _selectCommit(p, c),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            children: [
              Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: const BoxDecoration(
                  color: CcColors.editorTabBar,
                  border: Border(bottom: BorderSide(color: CcColors.border)),
                ),
                child: Row(
                  children: [
                    Icon(
                      _compareTitle == null
                          ? Icons.commit_rounded
                          : Icons.compare_arrows_rounded,
                      size: 16,
                      color: CcColors.muted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _compareTitle ?? (_selectedCommit ?? 'Commit diff'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CcType.code(size: 12, color: CcColors.muted),
                      ),
                    ),
                    if (_compareTitle != null)
                      TextButton(
                        onPressed: () => setState(() {
                          _compareTitle = null;
                          _compareFiles = const [];
                        }),
                        child: const Text('Commit Log'),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: selected.isEmpty
                    ? centerMsg('选择 commit 查看 diff')
                    : DiffView(files: selected),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _branchButton(String branch) => OutlinedButton.icon(
    onPressed: _gitProject == null ? null : _showBranchDialog,
    icon: const Icon(Icons.account_tree_rounded, size: 15),
    label: Text(branch),
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 9),
      visualDensity: VisualDensity.compact,
    ),
  );

  Widget _gitSummaryBar(GitStatusSummary? status) {
    if (status == null) return const SizedBox.shrink();
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: CcColors.editorTabBar,
        border: Border(bottom: BorderSide(color: CcColors.border)),
      ),
      child: Row(
        children: [
          _metricTiny('staged', status.staged, CcColors.ok),
          _metricTiny('modified', status.modified, CcColors.warning),
          _metricTiny('untracked', status.untracked, CcColors.accentBright),
          _metricTiny('conflicts', status.conflicted, CcColors.danger),
          const Spacer(),
          Text(
            status.clean ? 'clean' : 'uncommitted changes',
            style: CcType.code(
              size: 11.5,
              color: status.clean ? CcColors.ok : CcColors.warning,
            ),
          ),
        ],
      ),
    );
  }

  Widget _commitBox(ProjectCfg p, GitStatusSummary? status) {
    final canCommit = (status?.staged ?? 0) > 0 && !_gitLoading;
    final selected = _selectedChangePaths.length;
    final canCommitSelected = selected > 0 && !_gitLoading;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: const BoxDecoration(
        color: CcColors.panel,
        border: Border(bottom: BorderSide(color: CcColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _commitCtl,
              minLines: 1,
              maxLines: 2,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Commit message',
                prefixIcon: Icon(Icons.commit_rounded, size: 18),
              ),
              onSubmitted: (_) {
                if (canCommit) _gitCommitCurrent(p);
              },
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: canCommit ? () => _gitCommitCurrent(p) : null,
            icon: const Icon(Icons.check_rounded, size: 16),
            label: const Text('Commit'),
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            onPressed: canCommitSelected ? () => _gitCommitSelected(p) : null,
            icon: const Icon(Icons.checklist_rounded, size: 16),
            label: Text(selected == 0 ? 'Commit Selected' : 'Commit $selected'),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            onPressed: _gitLoading ? null : () => _gitStageAllCurrent(p),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text('Stage All'),
          ),
        ],
      ),
    );
  }

  Widget _metricTiny(String label, int value, Color color) => Padding(
    padding: const EdgeInsets.only(right: 10),
    child: Row(
      children: [
        statusDot(value == 0 ? CcColors.subtle : color, size: 6),
        const SizedBox(width: 5),
        Text(
          '$label $value',
          style: CcType.code(size: 11, color: CcColors.muted),
        ),
      ],
    ),
  );

  Future<void> _gitPullCurrent(ProjectCfg p) async {
    setState(() => _gitLoading = true);
    try {
      await gitPull(p.path);
      await _refreshGit();
      _snack('Pull 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitFetchCurrent(ProjectCfg p, {bool prune = false}) async {
    setState(() => _gitLoading = true);
    try {
      await gitFetch(p.path, prune: prune);
      await _refreshGit();
      _snack(prune ? 'Fetch --prune 完成' : 'Fetch 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitStageAllCurrent(ProjectCfg p) async {
    setState(() => _gitLoading = true);
    try {
      await gitStageAll(p.path);
      await _refreshGit();
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitUnstageAllCurrent(ProjectCfg p) async {
    setState(() => _gitLoading = true);
    try {
      await gitUnstageAll(p.path);
      await _refreshGit();
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitStageFileCurrent(ProjectCfg p, String file) async {
    setState(() => _gitLoading = true);
    try {
      await gitStageFiles(p.path, [file]);
      await _refreshGit();
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitUnstageFileCurrent(ProjectCfg p, String file) async {
    setState(() => _gitLoading = true);
    try {
      await gitUnstageFiles(p.path, [file]);
      await _refreshGit();
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitDiscardFileCurrent(ProjectCfg p, String file) async {
    if (!await _confirm('丢弃文件改动?', '$file\n\n这会恢复工作区文件。')) return;
    setState(() => _gitLoading = true);
    try {
      await gitRestore(p.path, file);
      await _refreshGit();
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitCommitCurrent(ProjectCfg p) async {
    setState(() => _gitLoading = true);
    try {
      await gitCommit(p.path, _commitCtl.text);
      _commitCtl.clear();
      await _refreshGit();
      _snack('Commit 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitCommitSelected(ProjectCfg p) async {
    final files = _selectedChangePaths.toList()..sort();
    if (files.isEmpty) return;
    setState(() => _gitLoading = true);
    try {
      await gitUnstageAll(p.path);
      await gitStageFiles(p.path, files);
      await gitCommit(p.path, _commitCtl.text);
      _commitCtl.clear();
      _selectedChangePaths.clear();
      await _refreshGit();
      _snack('Commit selected 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitPushCurrent(ProjectCfg p) async {
    setState(() => _gitLoading = true);
    try {
      await gitPush(p.path);
      await _refreshGit();
      _snack('Push 完成');
    } catch (e) {
      if (!mounted) return;
      setState(() => _gitLoading = false);
      final msg = errorText(e);
      if (msg.contains('upstream') || msg.contains('no upstream')) {
        final ok = await _confirm('设置 upstream 并 push?', msg);
        if (!ok) return;
        setState(() => _gitLoading = true);
        try {
          await gitPush(p.path, setUpstream: true);
          await _refreshGit();
          _snack('Push 完成');
        } catch (e2) {
          if (mounted) {
            setState(() => _gitLoading = false);
            _snack(errorText(e2));
          }
        }
      } else {
        _snack(msg);
      }
    }
  }

  Future<void> _showBranchDialog() async {
    final p = _gitProject;
    if (p == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _BranchDialog(
        project: p,
        onCheckout: (branch) async {
          await gitCheckoutBranch(p.path, branch);
          await _refreshGit();
        },
        onCreate: (branch, start) async {
          await gitCreateBranch(p.path, branch, start: start);
          await _refreshGit();
        },
        onRename: (oldName, newName) async {
          await gitRenameBranch(p.path, oldName, newName);
          await _refreshGit();
        },
        onDelete: (branch, force) async {
          await gitDeleteBranch(p.path, branch, force: force);
          await _refreshGit();
        },
        onCompare: (branch) async => _compareBranch(p, branch),
      ),
    );
  }

  Widget _termArea() {
    if (terms.isEmpty) {
      final ws =
          _cfg.workspaces.isNotEmpty && _cfg.workspaces.first.name.isNotEmpty
          ? _cfg.workspaces.first.name
          : 'workspace';
      return DecoratedBox(
        decoration: appGradient,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '~/$ws',
                    style: CcType.code(size: 14.5, color: CcColors.ok),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '❯',
                    style: CcType.code(
                      size: 14.5,
                      color: CcColors.accentBright,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const BlinkingCaret(),
                ],
              ),
              const SizedBox(height: 18),
              const Text(
                '在左侧 Project 的项目 / worktree 上起会话',
                style: TextStyle(color: CcColors.muted),
              ),
              const SizedBox(height: 8),
              Text(
                '# claude · codex',
                style: CcType.code(size: 12.5, color: CcColors.subtle),
              ),
            ],
          ),
        ),
      );
    }
    return terminalBody();
  }

  Widget _sidebar() {
    final wss = _cfg.workspaces;
    return Column(
      children: [
        _panelHeader(
          padding: const EdgeInsets.only(left: 10, right: 4),
          gradient: true,
          children: [
            const Icon(
              Icons.account_tree_outlined,
              size: 16,
              color: CcColors.muted,
            ),
            const SizedBox(width: 8),
            Text(
              'Project',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
              ).copyWith(color: CcColors.text),
            ),
            const SizedBox(width: 8),
            Text(
              '${wss.length}',
              style: CcType.code(size: 11.5, color: CcColors.subtle),
            ),
            const Spacer(),
            IconButton(
              onPressed: _busy ? null : _newWorkspace,
              tooltip: '新建工作区',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_rounded, size: 17),
            ),
            IconButton(
              onPressed: _busy ? null : _refresh,
              tooltip: '刷新',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh_rounded, size: 17),
            ),
            IconButton(
              onPressed: () => _setProjectCollapsed(true),
              tooltip: '收起',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_left_rounded, size: 17),
            ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: wss.isEmpty
              ? centerMsg(
                  'config.toml 里没有 workspace —— 点右上 + 新建,或 `cc-handoff workspace create`',
                )
              : ListView(
                  children: wss
                      .map(
                        (ws) => ExpansionTile(
                          title: Text(
                            ws.name.isEmpty ? '(默认)' : ws.name,
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          leading: const Icon(
                            Icons.workspaces_rounded,
                            size: 20,
                          ),
                          trailing: _workspaceMenu(ws),
                          initiallyExpanded: true,
                          shape: const Border(),
                          children: ws.projects
                              .map((p) => _projectTile(ws, p))
                              .toList(),
                        ),
                      )
                      .toList(),
                ),
        ),
      ],
    );
  }

  Widget _projectTile(WorkspaceCfg ws, ProjectCfg p) {
    return ExpansionTile(
      title: _HoverZone(
        builder: (h) => Row(
          children: [
            Expanded(
              child: Text(
                p.name,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _rowActions(
              h,
              onClaude: () => _openAgent(p, p.path, 'claude', ws.preLaunch),
              onCodex: () => _openAgent(p, p.path, 'codex', ws.preLaunch),
              menu: _projectMenu(ws, p),
            ),
          ],
        ),
      ),
      leading: const Icon(Icons.folder_rounded, size: 19),
      controller: _ctlFor(p.path),
      tilePadding: const EdgeInsets.only(left: 16, right: 8),
      childrenPadding: const EdgeInsets.only(left: 14),
      shape: const Border(),
      onExpansionChanged: (open) {
        if (open) {
          _ensureWorktrees(p.path);
          _selectGitProject(p);
        }
      },
      children: [
        ..._sessionNodes(p),
        _projectGitNode(p),
        _projectFilesNode(p),
        ..._worktreeNodes(ws, p),
        ..._taskNodes(p),
        if (_projectEmpty(p))
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '无 worktree / 任务',
              style: TextStyle(color: CcColors.muted, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _projectGitNode(ProjectCfg p) {
    final selected = _gitProject?.path == p.path;
    final status = selected ? _gitStatus : null;
    final summary = status == null
        ? 'Git'
        : status.clean
        ? '${status.branch} · clean'
        : '${status.branch} · ${status.staged + status.modified + status.untracked + status.conflicted} changes';
    return ListTile(
      dense: true,
      visualDensity: _tileDensity,
      contentPadding: const EdgeInsets.only(left: 12, right: 8),
      horizontalTitleGap: 8,
      leading: Icon(
        Icons.alt_route_rounded,
        size: 17,
        color: selected ? CcColors.accentBright : CcColors.muted,
      ),
      title: Text(
        summary,
        style: const TextStyle(fontFamily: CcType.mono, fontSize: 12.5),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: status == null || status.clean
          ? null
          : statusDot(
              status.conflicted > 0 ? CcColors.danger : CcColors.warning,
              size: 7,
            ),
      onTap: () => _selectGitProject(p, openTool: true),
    );
  }

  Widget _projectFilesNode(ProjectCfg p) {
    final header = _sectionHeader(p.path, 'files', 'FILES');
    if (_secCollapsed(p.path, 'files')) return header;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: DirTile(
            dir: p.path,
            label: p.name,
            depth: 0,
            initiallyExpanded: false,
            onOpenFile: _openCodeFile,
          ),
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
        final display = (e.s.name?.isNotEmpty ?? false)
            ? e.s.name!
            : '$agent · ${e.s.title}';
        return Container(
          decoration: BoxDecoration(
            color: active ? CcColors.accent.withValues(alpha: 0.08) : null,
            border: Border(
              left: BorderSide(
                color: active ? CcColors.accent : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
          child: ListTile(
            visualDensity: _tileDensity,
            contentPadding: const EdgeInsets.only(left: 12, right: 2),
            horizontalTitleGap: 8,
            selected: active,
            leading: Text(
              '❯',
              style: TextStyle(
                fontFamily: CcType.mono,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: active ? CcColors.accentBright : CcColors.muted,
              ),
            ),
            title: Text(
              display,
              style: TextStyle(
                fontFamily: CcType.mono,
                fontSize: 13.5,
                color: active ? CcColors.text : CcColors.muted,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => setState(() => activeTerm = e.idx),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (active)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: statusDot(CcColors.ok, size: 7, glow: true),
                  ),
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert_rounded,
                    size: 18,
                    color: CcColors.muted,
                  ),
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
              ],
            ),
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
          decoration: InputDecoration(
            labelText: '名称(留空 = 默认)',
            hintText: s.title,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
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
          title: Text(
            'worktrees 加载中…',
            style: TextStyle(color: CcColors.muted, fontSize: 12),
          ),
        ),
      ];
    }
    if (wts.isEmpty) return const [];
    final header = _sectionHeader(
      p.path,
      'worktrees',
      'WORKTREES (${wts.length})',
    );
    if (_secCollapsed(p.path, 'worktrees')) return [header];
    return [
      header,
      ...wts.map(
        (w) => _HoverZone(
          builder: (h) => ListTile(
            visualDensity: _tileDensity,
            contentPadding: const EdgeInsets.only(left: 10, right: 2),
            leading: Icon(
              Icons.account_tree_rounded,
              size: 18,
              color: w.isHandoff ? CcColors.accent : CcColors.muted,
            ),
            title: Text(
              w.branch.isEmpty ? w.name : w.branch,
              style: const TextStyle(fontFamily: CcType.mono, fontSize: 13.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: w.isHandoff
                ? const Text(
                    'handoff',
                    style: TextStyle(color: CcColors.accent, fontSize: 11),
                  )
                : null,
            trailing: _rowActions(
              h,
              onClaude: () => _openAgent(p, w.path, 'claude', ws.preLaunch),
              onCodex: () => _openAgent(p, w.path, 'codex', ws.preLaunch),
              menu: _worktreeMenu(ws, p, w),
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _taskNodes(ProjectCfg p) {
    final ts = _tasksByRepo[p.name] ?? const [];
    if (ts.isEmpty) return const [];
    final header = _sectionHeader(p.path, 'tasks', '任务 (${ts.length})');
    if (_secCollapsed(p.path, 'tasks')) return [header];
    return [
      header,
      ...ts.map(
        (it) => ListTile(
          visualDensity: _tileDensity,
          contentPadding: const EdgeInsets.only(left: 12, right: 8),
          leading: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: statusDot(
              it.urgency == 'urgent' ? CcColors.danger : CcColors.muted,
              size: 9,
              glow: it.urgency == 'urgent',
            ),
          ),
          title: Text(
            it.headline.isNotEmpty ? it.headline : it.sender,
            style: const TextStyle(fontSize: 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${it.sender} · ${it.state}',
            style: const TextStyle(color: CcColors.muted, fontSize: 11.5),
          ),
          onTap: () => _openTask(it),
        ),
      ),
    ];
  }

  // ------------------------------------------------------------- menus ----

  List<PopupMenuEntry<String>> _agentItems(String def) => [
    PopupMenuItem(
      value: 'claude',
      child: Text('起 claude${def == 'claude' ? '  (默认)' : ''}'),
    ),
    PopupMenuItem(
      value: 'codex',
      child: Text('起 codex${def == 'codex' ? '  (默认)' : ''}'),
    ),
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
    var agent = (ws.agent == 'codex' || ws.agent == 'manual')
        ? ws.agent
        : 'claude';
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
                  hintText: 'nvm use 18',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: editor,
                decoration: const InputDecoration(
                  labelText: 'editor(编辑器命令)',
                  hintText: 'code .',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
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
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _runCli(
      () => Cli.workspaceSet(
        ws.name,
        preLaunch: pre.text.trim(),
        editor: editor.text.trim(),
        agent: agent,
      ),
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
        case 'diff':
          _openDiff(p.path, p.name);
        case 'files':
          _openFileBrowser(p.path, p.name);
        case 'pr':
          _openPrs(p);
        case 'config':
          _openRepoConfig(p);
        case 'remove':
          _removeProject(ws, p);
      }
    },
    itemBuilder: (_) => [
      ..._agentItems(ws.agent),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'diff', child: Text('看变动')),
      const PopupMenuItem(value: 'files', child: Text('文件')),
      if (p.github.isNotEmpty)
        const PopupMenuItem(value: 'pr', child: Text('GitHub PR')),
      const PopupMenuItem(value: 'worktree', child: Text('新建 worktree')),
      const PopupMenuItem(value: 'config', child: Text('项目配置')),
      const PopupMenuItem(value: 'remove', child: Text('移除项目')),
    ],
  );

  void _openRepoConfig(ProjectCfg p) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            RepoConfigPage(projectPath: p.path, projectName: p.name),
      ),
    );
  }

  void _openDiff(String path, String name) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DiffPage(path: path, name: name),
      ),
    );
  }

  void _openFileBrowser(String path, String name) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FileBrowserPage(root: path, name: name),
      ),
    );
  }

  void _openPrs(ProjectCfg p) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GitHubPrPage(githubUrl: p.github, name: p.name),
      ),
    );
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
            case 'diff':
              _openDiff(w.path, w.branch.isEmpty ? w.name : w.branch);
            case 'files':
              _openFileBrowser(w.path, w.branch.isEmpty ? w.name : w.branch);
            case 'delete':
              _deleteWorktree(ws, p, w);
          }
        },
        itemBuilder: (_) => [
          ..._agentItems(ws.agent),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'diff', child: Text('看变动')),
          const PopupMenuItem(value: 'files', child: Text('文件')),
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
        child: Row(
          children: [
            Icon(
              collapsed
                  ? Icons.chevron_right_rounded
                  : Icons.expand_more_rounded,
              size: 16,
              color: CcColors.muted,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                fontFamily: CcType.mono,
                color: CcColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
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
            border: Border.all(color: CcColors.accent.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: CcType.mono,
              fontSize: 11.5,
              color: CcColors.accentBright,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ),
  );

  // _rowActions surfaces the common 起 claude/codex buttons on hover, keeping the
  // ⋮ menu for everything else.
  Widget _rowActions(
    bool hovered, {
    required VoidCallback onClaude,
    required VoidCallback onCodex,
    required Widget menu,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (hovered) ...[
        _quickBtn('claude', onClaude),
        _quickBtn('codex', onCodex),
      ],
      menu,
    ],
  );
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

class _BranchDialog extends StatefulWidget {
  final ProjectCfg project;
  final Future<void> Function(GitBranch branch) onCheckout;
  final Future<void> Function(String branch, String? start) onCreate;
  final Future<void> Function(String oldName, String newName) onRename;
  final Future<void> Function(String branch, bool force) onDelete;
  final Future<void> Function(GitBranch branch) onCompare;
  const _BranchDialog({
    required this.project,
    required this.onCheckout,
    required this.onCreate,
    required this.onRename,
    required this.onDelete,
    required this.onCompare,
  });

  @override
  State<_BranchDialog> createState() => _BranchDialogState();
}

class _BranchDialogState extends State<_BranchDialog> {
  List<GitBranch> _branches = const [];
  String _query = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final branches = await gitBranches(widget.project.path);
      if (!mounted) return;
      setState(() {
        _branches = branches;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  Future<void> _checkout(GitBranch b) async {
    try {
      await widget.onCheckout(b);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  Future<void> _createBranch() async {
    final ctl = TextEditingController(text: _query.trim());
    String? start;
    for (final b in _branches) {
      if (b.current) {
        start = b.name;
        break;
      }
    }
    final startCtl = TextEditingController(text: start ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建分支'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctl,
              autofocus: true,
              decoration: const InputDecoration(labelText: '分支名'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: startCtl,
              decoration: const InputDecoration(labelText: '起点 ref(可选)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('创建并切换'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final branch = ctl.text.trim();
    if (branch.isEmpty) {
      if (mounted) snack(context, '分支名不能为空');
      return;
    }
    try {
      await widget.onCreate(
        branch,
        startCtl.text.trim().isEmpty ? null : startCtl.text.trim(),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  Future<void> _renameBranch(GitBranch b) async {
    if (b.remote) return;
    final ctl = TextEditingController(text: b.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分支'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '新分支名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重命名'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final next = ctl.text.trim();
    if (next.isEmpty || next == b.name) return;
    try {
      await widget.onRename(b.name, next);
      await _load();
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  Future<void> _deleteBranch(GitBranch b, {bool force = false}) async {
    if (b.remote || b.current) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(force ? '强制删除分支?' : '删除分支?'),
        content: Text(
          '${b.name}\n\n${force ? 'git branch -D' : 'git branch -d'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.onDelete(b.name, force);
      await _load();
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  Future<void> _compareBranch(GitBranch b) async {
    try {
      await widget.onCompare(b);
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final branches = q.isEmpty
        ? _branches
        : _branches.where((b) => b.name.toLowerCase().contains(q)).toList();
    return Dialog(
      child: SizedBox(
        width: 560,
        height: 620,
        child: Column(
          children: [
            Container(
              height: 42,
              padding: const EdgeInsets.only(left: 14, right: 6),
              decoration: const BoxDecoration(
                color: CcColors.panel,
                border: Border(bottom: BorderSide(color: CcColors.border)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.account_tree_rounded,
                    size: 17,
                    color: CcColors.muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Branches · ${widget.project.name}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_rounded, size: 18),
                    tooltip: '新建分支',
                    onPressed: _createBranch,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索或输入新分支名',
                  isDense: true,
                  prefixIcon: Icon(Icons.search_rounded, size: 18),
                ),
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) {
                  GitBranch? exact;
                  for (final b in branches) {
                    if (b.name == _query) {
                      exact = b;
                      break;
                    }
                  }
                  if (exact != null) {
                    _checkout(exact);
                  } else {
                    _createBranch();
                  }
                },
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? centerMsg(_error!, onRetry: _load)
                  : ListView.builder(
                      itemCount: branches.length,
                      itemBuilder: (_, i) {
                        final b = branches[i];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            b.remote
                                ? Icons.cloud_queue_rounded
                                : Icons.account_tree_rounded,
                            size: 17,
                            color: b.current
                                ? CcColors.accentBright
                                : CcColors.muted,
                          ),
                          title: Text(
                            b.name,
                            style: const TextStyle(
                              fontFamily: CcType.mono,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: Text(
                            b.current
                                ? 'current'
                                : b.remote
                                ? 'remote · checkout creates ${b.localName ?? b.name}'
                                : 'local',
                          ),
                          trailing: b.current
                              ? statusDot(CcColors.ok, size: 7, glow: true)
                              : PopupMenuButton<String>(
                                  icon: const Icon(
                                    Icons.more_vert_rounded,
                                    size: 18,
                                  ),
                                  tooltip: '分支操作',
                                  onSelected: (v) {
                                    if (v == 'checkout') _checkout(b);
                                    if (v == 'compare') _compareBranch(b);
                                    if (v == 'rename') _renameBranch(b);
                                    if (v == 'delete') _deleteBranch(b);
                                    if (v == 'forceDelete') {
                                      _deleteBranch(b, force: true);
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    const PopupMenuItem(
                                      value: 'checkout',
                                      child: Text('Checkout'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'compare',
                                      child: Text('Compare with Current'),
                                    ),
                                    if (!b.remote) ...[
                                      const PopupMenuItem(
                                        value: 'rename',
                                        child: Text('Rename'),
                                      ),
                                      const PopupMenuItem(
                                        value: 'delete',
                                        child: Text('Delete'),
                                      ),
                                      const PopupMenuItem(
                                        value: 'forceDelete',
                                        child: Text('Force Delete'),
                                      ),
                                    ],
                                  ],
                                ),
                          onTap: b.current ? null : () => _checkout(b),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickOpenDialog extends StatefulWidget {
  final List<WorkspaceCfg> workspaces;
  const _QuickOpenDialog({required this.workspaces});

  @override
  State<_QuickOpenDialog> createState() => _QuickOpenDialogState();
}

class _QuickOpenDialogState extends State<_QuickOpenDialog> {
  final _ctl = TextEditingController();
  List<({String label, String path})> _files = const [];
  bool _loading = true;
  String _query = '';

  static const _skip = {
    '.git',
    'node_modules',
    'build',
    '.dart_tool',
    '.idea',
    'dist',
    'vendor',
    'target',
    '.gradle',
    'Pods',
    '.next',
    '__pycache__',
    '.venv',
  };

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final out = <({String label, String path})>[];
    for (final ws in widget.workspaces) {
      for (final p in ws.projects) {
        await _scanDir(Directory(p.path), p.path, p.name, out);
        if (out.length >= 1600) break;
      }
      if (out.length >= 1600) break;
    }
    out.sort((a, b) => a.label.compareTo(b.label));
    if (mounted) {
      setState(() {
        _files = out;
        _loading = false;
      });
    }
  }

  Future<void> _scanDir(
    Directory dir,
    String root,
    String project,
    List<({String label, String path})> out,
  ) async {
    if (out.length >= 1600) return;
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      if (out.length >= 1600) return;
      final name = e.path.split('/').last;
      if (_skip.contains(name)) continue;
      if (e is Directory) {
        await _scanDir(e, root, project, out);
      } else if (e is File) {
        final rel = e.path.startsWith('$root/')
            ? e.path.substring(root.length + 1)
            : e.path;
        out.add((label: '$project/$rel', path: e.path));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? _files.take(80).toList()
        : _files
              .where((f) => f.label.toLowerCase().contains(q))
              .take(120)
              .toList();
    return Dialog(
      child: SizedBox(
        width: 680,
        height: 620,
        child: Column(
          children: [
            Container(
              height: 44,
              padding: const EdgeInsets.only(left: 14, right: 6),
              decoration: const BoxDecoration(
                color: CcColors.panel,
                border: Border(bottom: BorderSide(color: CcColors.border)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: CcColors.muted,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '快速打开文件',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: TextField(
                controller: _ctl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '输入文件名或路径',
                  isDense: true,
                  prefixIcon: Icon(Icons.search_rounded, size: 18),
                ),
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) {
                  if (filtered.isNotEmpty) {
                    Navigator.pop(context, filtered.first.path);
                  }
                },
              ),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: filtered.isEmpty && !_loading
                  ? centerMsg('没有匹配文件')
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final f = filtered[i];
                        return ListTile(
                          dense: true,
                          leading: const Icon(
                            Icons.insert_drive_file_outlined,
                            size: 16,
                            color: CcColors.muted,
                          ),
                          title: Text(
                            f.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CcType.code(size: 12.5),
                          ),
                          onTap: () => Navigator.pop(context, f.path),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
