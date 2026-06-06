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

enum _GitView { changes, log, branches, stash }

const _searchSkipDirs = {
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

class _OpenFile {
  final String path;
  int? line;
  bool dirty = false;
  final GlobalKey<CodeEditorPaneState> key = GlobalKey<CodeEditorPaneState>();

  _OpenFile(this.path, {this.line});

  String get name => path.split('/').last;
}

class _CodeSymbol {
  final String name;
  final String kind;
  final int line;
  final int indent;
  final IconData icon;

  const _CodeSymbol({
    required this.name,
    required this.kind,
    required this.line,
    required this.indent,
    required this.icon,
  });
}

class _CodeLocation {
  final String path;
  final int? line;

  const _CodeLocation(this.path, {this.line});

  bool sameAs(_CodeLocation other) => path == other.path && line == other.line;
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
  final List<_CodeLocation> _codeBackStack = [];
  final List<_CodeLocation> _codeForwardStack = [];
  int _activeFile = -1;
  _BottomTool _bottomTool =
      Prefs.getString('ws.bottomTool', def: 'terminal') == 'git'
      ? _BottomTool.git
      : _BottomTool.terminal;
  ProjectCfg? _gitProject;
  GitStatusSummary? _gitStatus;
  GitOperationState? _gitOperation;
  List<FileDiff> _gitFiles = const [];
  List<GitChange> _gitChanges = const [];
  List<GitCommit> _gitLog = const [];
  List<GitBranch> _gitBranches = const [];
  List<GitStash> _gitStashes = const [];
  List<FileDiff> _commitFiles = const [];
  List<FileDiff> _stashFiles = const [];
  String? _selectedCommit;
  String? _selectedStash;
  String? _stashPreviewRef;
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
      final operation = await gitOperationState(p.path);
      final changes = await gitChanges(p.path);
      final diff = await gitDiffWorking(p.path);
      final log = await gitLog(p.path);
      final branches = await gitBranches(p.path);
      final stashes = await gitStashes(p.path);
      if (!mounted) return;
      setState(() {
        _gitStatus = status;
        _gitOperation = operation;
        _gitChanges = changes;
        _selectedChangePaths.removeWhere(
          (path) => !changes.any((c) => c.path == path),
        );
        _gitFiles = parseUnifiedDiff(diff);
        _gitLog = log;
        _gitBranches = branches;
        _gitStashes = stashes;
        if (_selectedStash == null ||
            !stashes.any((s) => s.ref == _selectedStash)) {
          _selectedStash = stashes.isEmpty ? null : stashes.first.ref;
          _stashFiles = const [];
          _stashPreviewRef = null;
        }
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

  _CodeLocation? get _activeLocation {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) return null;
    final file = _codeFiles[_activeFile];
    return _CodeLocation(file.path, line: file.line);
  }

  void _pushNavigationHistory() {
    final current = _activeLocation;
    if (current == null) return;
    if (_codeBackStack.isNotEmpty && _codeBackStack.last.sameAs(current)) {
      return;
    }
    _codeBackStack.add(current);
    if (_codeBackStack.length > 80) _codeBackStack.removeAt(0);
    _codeForwardStack.clear();
  }

  void _openCodeFile(String path, {int? line, bool recordHistory = true}) {
    final target = _CodeLocation(path, line: line);
    final current = _activeLocation;
    if (recordHistory && current != null && !current.sameAs(target)) {
      _pushNavigationHistory();
    }
    final existing = _codeFiles.indexWhere((f) => f.path == path);
    setState(() {
      if (existing >= 0) {
        _codeFiles[existing].line = line;
        _activeFile = existing;
      } else {
        _codeFiles.add(_OpenFile(path, line: line));
        _activeFile = _codeFiles.length - 1;
      }
      _recentFiles.remove(path);
      _recentFiles.insert(0, path);
      if (_recentFiles.length > 12) {
        _recentFiles.removeRange(12, _recentFiles.length);
      }
    });
  }

  void _navigateBack() {
    if (_codeBackStack.isEmpty) return;
    final current = _activeLocation;
    final target = _codeBackStack.removeLast();
    if (current != null && !current.sameAs(target)) {
      _codeForwardStack.add(current);
    }
    _openCodeFile(target.path, line: target.line, recordHistory: false);
  }

  void _navigateForward() {
    if (_codeForwardStack.isEmpty) return;
    final current = _activeLocation;
    final target = _codeForwardStack.removeLast();
    if (current != null && !current.sameAs(target)) {
      _codeBackStack.add(current);
    }
    _openCodeFile(target.path, line: target.line, recordHistory: false);
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

  Future<void> _closeOtherCodeFiles(int keep) async {
    if (keep < 0 || keep >= _codeFiles.length) return;
    final dirty = _codeFiles
        .asMap()
        .entries
        .where((e) => e.key != keep && e.value.dirty)
        .map((e) => e.value.path)
        .toList();
    if (dirty.isNotEmpty) {
      final ok = await _confirm(
        '关闭其他未保存文件?',
        dirty.take(5).join('\n') +
            (dirty.length > 5 ? '\n...and ${dirty.length - 5} more' : ''),
      );
      if (!ok) return;
    }
    final kept = _codeFiles[keep];
    setState(() {
      _codeFiles
        ..clear()
        ..add(kept);
      _activeFile = 0;
    });
  }

  Future<void> _closeAllCodeFiles() async {
    final dirty = _codeFiles.where((f) => f.dirty).map((f) => f.path).toList();
    if (dirty.isNotEmpty) {
      final ok = await _confirm(
        '关闭所有未保存文件?',
        dirty.take(5).join('\n') +
            (dirty.length > 5 ? '\n...and ${dirty.length - 5} more' : ''),
      );
      if (!ok) return;
    }
    setState(() {
      _codeFiles.clear();
      _activeFile = -1;
    });
  }

  void _copyFilePath(String path) {
    Clipboard.setData(ClipboardData(text: path));
    _snack('已复制路径');
  }

  void _revealFileInProject(String path) {
    final hit = _projectForFile(path);
    if (hit == null) {
      _snack('找不到文件所属项目');
      return;
    }
    _ctlFor(hit.project.path).expand();
    Prefs.setBool('ws.sec.${hit.project.path}.files', false);
    _selectGitProject(hit.project);
    _setProjectCollapsed(false);
    _snack('已展开 Project · ${hit.rel}');
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

  Future<void> _showFindInFiles() async {
    final d = _defaultProject();
    if (d == null) {
      _snack('没有可搜索的项目');
      return;
    }
    final hit = await showDialog<_SearchHit>(
      context: context,
      builder: (_) => _FindInFilesDialog(workspaces: _cfg.workspaces),
    );
    if (hit != null) _openCodeFile(hit.path, line: hit.line);
  }

  Future<void> _showFindInCurrentFile() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) {
      _snack('没有打开的文件');
      return;
    }
    final file = _codeFiles[_activeFile];
    final text = file.key.currentState?.text;
    if (text == null) {
      _snack('文件仍在加载');
      return;
    }
    final line = await showDialog<int>(
      context: context,
      builder: (_) => _FindInCurrentFileDialog(path: file.path, text: text),
    );
    if (line != null) _openCodeFile(file.path, line: line);
  }

  Future<void> _showGoToLine() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) {
      _snack('没有打开的文件');
      return;
    }
    final file = _codeFiles[_activeFile];
    final lineCount = file.key.currentState?.lineCount ?? 0;
    if (lineCount <= 0) {
      _snack('文件仍在加载');
      return;
    }
    final line = await showDialog<int>(
      context: context,
      builder: (_) => _GoToLineDialog(
        fileName: file.name,
        lineCount: lineCount,
        initialLine: file.line,
      ),
    );
    if (line != null) _openCodeFile(file.path, line: line);
  }

  Future<void> _showFileStructure() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) {
      _snack('没有打开的文件');
      return;
    }
    final file = _codeFiles[_activeFile];
    final text = file.key.currentState?.text;
    if (text == null) {
      _snack('文件仍在加载');
      return;
    }
    final symbols = _extractCodeSymbols(file.path, text);
    if (symbols.isEmpty) {
      _snack('没有可跳转的结构符号');
      return;
    }
    final symbol = await showDialog<_CodeSymbol>(
      context: context,
      builder: (_) => _FileStructureDialog(path: file.path, symbols: symbols),
    );
    if (symbol != null) _openCodeFile(file.path, line: symbol.line);
  }

  Future<void> _showShortcuts() async {
    final isMac = Platform.isMacOS;
    final mod = isMac ? 'Cmd' : 'Ctrl';
    final rows = [
      ('$mod+O', '快速打开文件'),
      ('$mod+F', '当前文件查找'),
      ('$mod+G', '跳转行号'),
      ('$mod+F12', '文件结构'),
      ('$mod+Alt+←/→', '代码导航后退/前进'),
      ('$mod+Shift+F', '全文搜索'),
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
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _showFindInCurrentFile,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _showFindInCurrentFile,
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true):
            _showGoToLine,
        const SingleActivator(LogicalKeyboardKey.keyG, control: true):
            _showGoToLine,
        const SingleActivator(LogicalKeyboardKey.f12, meta: true):
            _showFileStructure,
        const SingleActivator(LogicalKeyboardKey.f12, control: true):
            _showFileStructure,
        const SingleActivator(
          LogicalKeyboardKey.arrowLeft,
          meta: true,
          alt: true,
        ): _navigateBack,
        const SingleActivator(
          LogicalKeyboardKey.arrowLeft,
          control: true,
          alt: true,
        ): _navigateBack,
        const SingleActivator(
          LogicalKeyboardKey.arrowRight,
          meta: true,
          alt: true,
        ): _navigateForward,
        const SingleActivator(
          LogicalKeyboardKey.arrowRight,
          control: true,
          alt: true,
        ): _navigateForward,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true, shift: true):
            _showFindInFiles,
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
          shift: true,
        ): _showFindInFiles,
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

  ({ProjectCfg project, String rel})? _projectForFile(String path) {
    ProjectCfg? best;
    for (final ws in _cfg.workspaces) {
      for (final p in ws.projects) {
        if (path == p.path || path.startsWith('${p.path}/')) {
          if (best == null || p.path.length > best.path.length) best = p;
        }
      }
    }
    if (best == null) return null;
    final rel = path == best.path ? '' : path.substring(best.path.length + 1);
    return (project: best, rel: rel);
  }

  Future<void> _showBlameForActiveFile() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) return;
    final file = _codeFiles[_activeFile].path;
    final hit = _projectForFile(file);
    if (hit == null || hit.rel.isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (_) => _BlameDialog(project: hit.project, relPath: hit.rel),
    );
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
            icon: Icons.arrow_back_rounded,
            tooltip: '代码导航后退',
            selected: false,
            onPressed: _codeBackStack.isEmpty ? null : _navigateBack,
          ),
          _toolButton(
            icon: Icons.arrow_forward_rounded,
            tooltip: '代码导航前进',
            selected: false,
            onPressed: _codeForwardStack.isEmpty ? null : _navigateForward,
          ),
          _toolButton(
            icon: Icons.file_open_outlined,
            tooltip: '快速打开文件',
            selected: false,
            onPressed: _showQuickOpen,
          ),
          _toolButton(
            icon: Icons.manage_search_rounded,
            tooltip: '全文搜索',
            selected: false,
            onPressed: _showFindInFiles,
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

  Widget _leftToolWindowBar() {
    final projectCount = _cfg.workspaces.fold<int>(
      0,
      (sum, ws) => sum + ws.projects.length,
    );
    final changeCount = _gitChanges.length;
    final sessionCount = terms.length;
    final hasActiveFile = _activeFile >= 0 && _activeFile < _codeFiles.length;
    return Container(
      width: 50,
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
            badge: projectCount == 0 ? null : '$projectCount',
            onTap: () => _setProjectCollapsed(!_projectCollapsed),
          ),
          _leftToolButton(
            icon: Icons.alt_route_rounded,
            label: 'Commit',
            selected: !_terminalCollapsed && _bottomTool == _BottomTool.git,
            badge: changeCount == 0 ? null : '$changeCount',
            badgeColor: CcColors.warning,
            onTap: () => _setBottomTool(_BottomTool.git),
          ),
          _leftToolButton(
            icon: Icons.terminal_rounded,
            label: 'Terminal',
            selected:
                !_terminalCollapsed && _bottomTool == _BottomTool.terminal,
            badge: sessionCount == 0 ? null : '$sessionCount',
            badgeColor: CcColors.ok,
            onTap: () => _setBottomTool(_BottomTool.terminal),
          ),
          _leftToolButton(
            icon: Icons.description_outlined,
            label: 'Handoff',
            selected: _detailItem != null && !_detailCollapsed,
            enabled: _detailItem != null,
            badge: _detailItem == null ? null : '1',
            badgeColor: CcColors.accentBright,
            onTap: () => _setDetailCollapsed(!_detailCollapsed),
          ),
          const Divider(height: 13, indent: 8, endIndent: 8),
          _leftActionButton(
            icon: Icons.manage_search_rounded,
            label: 'Search',
            onTap: _showFindInFiles,
          ),
          _leftActionButton(
            icon: Icons.account_tree_rounded,
            label: 'Structure',
            enabled: hasActiveFile,
            onTap: _showFileStructure,
          ),
          _leftActionButton(
            icon: Icons.history_rounded,
            label: 'Recent Files',
            onTap: _showRecentFiles,
          ),
          const Spacer(),
          _leftActionButton(
            icon: Icons.keyboard_command_key_rounded,
            label: 'Shortcuts',
            onTap: _showShortcuts,
          ),
          _leftActionButton(
            icon: Icons.refresh_rounded,
            label: 'Refresh',
            onTap: _refresh,
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _leftToolButton({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    bool enabled = true,
    String? badge,
    Color badgeColor = CcColors.accentBright,
  }) => Tooltip(
    message: label,
    preferBelow: false,
    child: InkWell(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 50,
        height: 96,
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
        child: Stack(
          children: [
            Center(
              child: RotatedBox(
                quarterTurns: 3,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      icon,
                      size: 16,
                      color: !enabled
                          ? CcColors.subtle.withValues(alpha: 0.55)
                          : selected
                          ? CcColors.accentBright
                          : CcColors.muted,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: !enabled
                            ? CcColors.subtle.withValues(alpha: 0.55)
                            : selected
                            ? CcColors.text
                            : CcColors.muted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (badge != null)
              Positioned(
                top: 5,
                right: 4,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 17),
                  height: 17,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: selected ? 0.22 : 0.14),
                    border: Border.all(
                      color: badgeColor.withValues(alpha: 0.55),
                    ),
                    borderRadius: BorderRadius.circular(CcRadius.pill),
                  ),
                  child: Text(
                    badge,
                    style: CcType.code(
                      size: 9.5,
                      color: selected ? CcColors.text : badgeColor,
                      weight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _leftActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool enabled = true,
  }) => Tooltip(
    message: label,
    preferBelow: false,
    child: InkWell(
      onTap: enabled ? onTap : null,
      child: SizedBox(
        width: 50,
        height: 38,
        child: Icon(
          icon,
          size: 18,
          color: enabled
              ? CcColors.muted
              : CcColors.subtle.withValues(alpha: 0.45),
        ),
      ),
    ),
  );

  Widget _editorArea() => Column(
    children: [
      _editorTabs(),
      _editorHeader(),
      Expanded(child: _editorCanvas()),
    ],
  );

  Widget _editorHeader() {
    final hasActiveFile = _activeFile >= 0 && _activeFile < _codeFiles.length;
    if (!hasActiveFile) return const SizedBox.shrink();
    final file = _codeFiles[_activeFile];
    final state = file.key.currentState;
    final hit = _projectForFile(file.path);
    final rel = hit?.rel.isNotEmpty == true ? hit!.rel : file.path;
    final parts = rel.split('/').where((p) => p.isNotEmpty).toList();
    final bytes = state?.fileBytes;
    final byteText = bytes == null ? '' : _formatBytes(bytes);
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: 10, right: 8),
      decoration: const BoxDecoration(
        color: CcColors.editor,
        border: Border(bottom: BorderSide(color: CcColors.border)),
      ),
      child: Row(
        children: [
          Icon(_iconForFile(file.path), size: 15, color: CcColors.muted),
          const SizedBox(width: 8),
          if (hit != null) ...[
            Text(
              hit.project.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CcType.code(
                size: 11.5,
                color: CcColors.accentBright,
                weight: FontWeight.w700,
              ),
            ),
            if (parts.isNotEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 14,
                  color: CcColors.subtle,
                ),
              ),
          ],
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < parts.length; i++) ...[
                    Text(
                      parts[i],
                      style: CcType.code(
                        size: 11.5,
                        color: i == parts.length - 1
                            ? CcColors.text
                            : CcColors.muted,
                        weight: i == parts.length - 1
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                    if (i != parts.length - 1)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 5),
                        child: Icon(
                          Icons.chevron_right_rounded,
                          size: 13,
                          color: CcColors.subtle,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (file.dirty) tag('modified', CcColors.warning),
          if (file.line != null)
            tag('line ${file.line}', CcColors.accentBright),
          TextButton.icon(
            onPressed: _showGoToLine,
            icon: const Icon(Icons.format_list_numbered_rounded, size: 14),
            label: const Text('Go To'),
          ),
          TextButton.icon(
            onPressed: () => _revealFileInProject(file.path),
            icon: const Icon(Icons.my_location_rounded, size: 14),
            label: const Text('Reveal'),
          ),
          if (state?.saving == true) ...[
            const SizedBox(width: 8),
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
          const SizedBox(width: 10),
          _editorMetaChip(
            Icons.notes_rounded,
            '${state?.lineCount ?? 0} lines',
          ),
          _editorMetaChip(Icons.code_rounded, state?.languageLabel ?? 'Text'),
          _editorMetaChip(Icons.keyboard_return_rounded, state?.eol ?? 'LF'),
          if (byteText.isNotEmpty)
            _editorMetaChip(Icons.data_object_rounded, byteText),
        ],
      ),
    );
  }

  Widget _editorMetaChip(IconData icon, String label) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: CcColors.subtle),
        const SizedBox(width: 4),
        Text(label, style: CcType.code(size: 10.5, color: CcColors.subtle)),
      ],
    ),
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
              tabMenu: _editorFileTabMenu(i),
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
          if (hasActiveFile) ...[
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 17),
              tooltip: 'Back',
              visualDensity: VisualDensity.compact,
              onPressed: _codeBackStack.isEmpty ? null : _navigateBack,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_rounded, size: 17),
              tooltip: 'Forward',
              visualDensity: VisualDensity.compact,
              onPressed: _codeForwardStack.isEmpty ? null : _navigateForward,
            ),
            IconButton(
              icon: const Icon(Icons.account_tree_rounded, size: 17),
              tooltip: 'File Structure',
              visualDensity: VisualDensity.compact,
              onPressed: _showFileStructure,
            ),
            IconButton(
              icon: const Icon(Icons.search_rounded, size: 17),
              tooltip: 'Find in File',
              visualDensity: VisualDensity.compact,
              onPressed: _showFindInCurrentFile,
            ),
            IconButton(
              icon: const Icon(Icons.person_search_rounded, size: 17),
              tooltip: 'Annotate / Blame',
              visualDensity: VisualDensity.compact,
              onPressed: _showBlameForActiveFile,
            ),
            IconButton(
              icon: const Icon(Icons.save_rounded, size: 17),
              tooltip: '保存',
              visualDensity: VisualDensity.compact,
              onPressed: _codeFiles[_activeFile].dirty
                  ? _codeFiles[_activeFile].key.currentState?.save
                  : null,
            ),
          ],
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
    PopupMenuButton<String>? tabMenu,
  }) => InkWell(
    onTap: onTap,
    onSecondaryTap: () {
      if (tabMenu != null) onTap();
    },
    child: Container(
      constraints: const BoxConstraints(maxWidth: 260),
      height: 36,
      padding: const EdgeInsets.only(left: 12, right: 4),
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
          if (tabMenu != null) ...[const SizedBox(width: 3), tabMenu],
          if (onClose != null) ...[
            const SizedBox(width: 2),
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

  PopupMenuButton<String> _editorFileTabMenu(int index) {
    final file = _codeFiles[index];
    return PopupMenuButton<String>(
      tooltip: 'Tab actions',
      icon: const Icon(Icons.more_vert_rounded, size: 15),
      padding: EdgeInsets.zero,
      onOpened: () => setState(() => _activeFile = index),
      onSelected: (v) {
        if (v == 'copyPath') _copyFilePath(file.path);
        if (v == 'reveal') _revealFileInProject(file.path);
        if (v == 'close') _closeCodeFile(index);
        if (v == 'closeOthers') _closeOtherCodeFiles(index);
        if (v == 'closeAll') _closeAllCodeFiles();
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'copyPath', child: Text('Copy Path')),
        const PopupMenuItem(value: 'reveal', child: Text('Reveal in Project')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'close', child: Text('Close')),
        const PopupMenuItem(value: 'closeOthers', child: Text('Close Others')),
        const PopupMenuItem(value: 'closeAll', child: Text('Close All')),
      ],
    );
  }

  Widget _editorCanvas() {
    if (_activeFile >= 0 && _activeFile < _codeFiles.length) {
      final f = _codeFiles[_activeFile];
      return CodeEditorPane(
        key: f.key,
        path: f.path,
        initialLine: f.line,
        onDirtyChanged: (v) {
          if (!mounted) return;
          setState(() => f.dirty = v);
        },
        onLoaded: () {
          if (!mounted) return;
          setState(() {});
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

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
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

  void _copyCommitHash(GitCommit c) {
    Clipboard.setData(ClipboardData(text: c.hash));
    _snack('已复制 ${c.shortHash}');
  }

  Future<void> _createBranchFromCommit(ProjectCfg p, GitCommit c) async {
    final safeSubject = c.subject
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final ctl = TextEditingController(
      text: safeSubject.isEmpty
          ? 'branch-${c.shortHash}'
          : '${safeSubject.length > 32 ? safeSubject.substring(0, 32) : safeSubject}-${c.shortHash}',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Branch from Commit'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${c.shortHash} · ${c.subject}',
              style: CcType.code(size: 12, color: CcColors.muted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Branch name'),
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
            child: const Text('Create and Checkout'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final branch = ctl.text.trim();
    if (branch.isEmpty) {
      _snack('分支名不能为空');
      return;
    }
    setState(() => _gitLoading = true);
    try {
      await gitCreateBranch(p.path, branch, start: c.hash);
      await _refreshGit();
      _snack('已从 ${c.shortHash} 创建分支');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _cherryPickCommit(ProjectCfg p, GitCommit c) async {
    final ok = await _confirm(
      'Cherry-pick commit?',
      '${c.shortHash} · ${c.subject}\n\n这会把该提交应用到当前分支。',
    );
    if (!ok) return;
    setState(() => _gitLoading = true);
    try {
      await gitCherryPick(p.path, c.hash);
      await _refreshGit();
      _snack('Cherry-pick 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _revertCommit(ProjectCfg p, GitCommit c) async {
    final ok = await _confirm(
      'Revert commit?',
      '${c.shortHash} · ${c.subject}\n\n这会创建一个反向提交。',
    );
    if (!ok) return;
    setState(() => _gitLoading = true);
    try {
      await gitRevertCommit(p.path, c.hash);
      await _refreshGit();
      _snack('Revert 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _selectStash(ProjectCfg p, GitStash s) async {
    setState(() {
      _selectedStash = s.ref;
      _gitLoading = true;
    });
    try {
      final diff = await gitStashShow(p.path, s.ref);
      if (!mounted) return;
      setState(() {
        _stashFiles = parseUnifiedDiff(diff);
        _stashPreviewRef = s.ref;
        _gitLoading = false;
      });
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
            _bottomTab(
              icon: Icons.account_tree_rounded,
              label: 'Branches',
              selected: _gitView == _GitView.branches,
              onTap: () => setState(() => _gitView = _GitView.branches),
            ),
            _bottomTab(
              icon: Icons.inventory_2_outlined,
              label: 'Stash',
              selected: _gitView == _GitView.stash,
              onTap: () => setState(() => _gitView = _GitView.stash),
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
                if (_gitOperation != null) _gitOperationBar(p, _gitOperation!),
                if (_gitView == _GitView.changes) _commitBox(p, status),
                Expanded(child: _gitToolBody(p)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _gitToolBody(ProjectCfg p) {
    if (_gitView == _GitView.stash) return _stashView(p);
    if (_gitView == _GitView.branches) return _branchesView(p);
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

  Widget _branchesView(ProjectCfg p) => _BranchListPane(
    project: p,
    branches: _gitBranches,
    loading: _gitLoading,
    error: _gitError,
    embedded: true,
    onRefresh: _refreshGit,
    onCheckout: (branch) async {
      await gitCheckoutBranch(p.path, branch);
      await _refreshGit();
      _snack('切换到 ${branch.localName ?? branch.name}');
    },
    onCreate: (branch, start) async {
      await gitCreateBranch(p.path, branch, start: start);
      await _refreshGit();
      _snack('创建并切换到 $branch');
    },
    onRename: (oldName, newName) async {
      await gitRenameBranch(p.path, oldName, newName);
      await _refreshGit();
      _snack('分支已重命名');
    },
    onDelete: (branch, force) async {
      await gitDeleteBranch(p.path, branch, force: force);
      await _refreshGit();
      _snack(force ? '分支已强制删除' : '分支已删除');
    },
    onCompare: (branch) async => _compareBranch(p, branch),
    onMerge: (branch) async => _mergeBranchIntoCurrent(p, branch),
    onRebase: (branch) async => _rebaseCurrentOntoBranch(p, branch),
  );

  Widget _localChangesView(ProjectCfg p) {
    final selected = _selectedGitPath == null
        ? const <FileDiff>[]
        : _gitFiles.where((f) => f.path == _selectedGitPath).toList();
    final selectedChange = _selectedGitPath == null
        ? null
        : _gitChanges.where((c) => c.path == _selectedGitPath).firstOrNull;
    return Row(
      children: [
        SizedBox(width: 320, child: _localChangesList(p)),
        const VerticalDivider(width: 1),
        Expanded(
          child: selected.isEmpty
              ? centerMsg('选择一个变更文件')
              : _selectedChangeDiffPanel(p, selected, selectedChange),
        ),
      ],
    );
  }

  Widget _selectedChangeDiffPanel(
    ProjectCfg p,
    List<FileDiff> selected,
    GitChange? change,
  ) {
    final file = change?.path ?? selected.first.path;
    final canStage = change?.unstaged == true;
    final canUnstage = change?.staged == true;
    final canRollback = change != null && !change.conflicted;
    return Column(
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
              Icon(_iconForFile(file), size: 16, color: CcColors.muted),
              const SizedBox(width: 8),
              if (change != null) ...[
                Text(
                  change.status,
                  style: CcType.code(
                    size: 11.5,
                    color: _changeColor(change),
                    weight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  file,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 12, color: CcColors.muted),
                ),
              ),
              TextButton.icon(
                onPressed: _gitLoading
                    ? null
                    : () => _openCodeFile('${p.path}/$file'),
                icon: const Icon(Icons.open_in_new_rounded, size: 14),
                label: const Text('Open'),
              ),
              TextButton.icon(
                onPressed: !_gitLoading && canStage
                    ? () => _gitStageFileCurrent(p, file)
                    : null,
                icon: const Icon(Icons.add_task_rounded, size: 14),
                label: const Text('Stage'),
              ),
              TextButton.icon(
                onPressed: !_gitLoading && canUnstage
                    ? () => _gitUnstageFileCurrent(p, file)
                    : null,
                icon: const Icon(Icons.remove_done_rounded, size: 14),
                label: const Text('Unstage'),
              ),
              TextButton.icon(
                onPressed: !_gitLoading && canRollback
                    ? () => _gitDiscardFileCurrent(p, file)
                    : null,
                icon: const Icon(Icons.undo_rounded, size: 14),
                label: const Text('Rollback'),
                style: TextButton.styleFrom(foregroundColor: CcColors.danger),
              ),
            ],
          ),
        ),
        Expanded(
          child: DiffView(
            files: selected,
            editRoot: p.path,
            onChanged: _refreshGit,
          ),
        ),
      ],
    );
  }

  Widget _localChangesList(ProjectCfg p) {
    final stageableSelected = _gitChanges
        .where((c) => _selectedChangePaths.contains(c.path) && c.unstaged)
        .length;
    final unstageableSelected = _gitChanges
        .where((c) => _selectedChangePaths.contains(c.path) && c.staged)
        .length;
    final rollbackableSelected = _gitChanges
        .where((c) => _selectedChangePaths.contains(c.path) && !c.conflicted)
        .length;
    return DecoratedBox(
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
                if (_selectedChangePaths.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  tag(
                    '${_selectedChangePaths.length} selected',
                    CcColors.accentBright,
                  ),
                ],
                const Spacer(),
                TextButton(
                  onPressed: _gitLoading || stageableSelected == 0
                      ? null
                      : () => _gitStageSelectedCurrent(p),
                  child: const Text('Stage'),
                ),
                TextButton(
                  onPressed: _gitLoading || unstageableSelected == 0
                      ? null
                      : () => _gitUnstageSelectedCurrent(p),
                  child: const Text('Unstage'),
                ),
                TextButton(
                  onPressed: _gitLoading || rollbackableSelected == 0
                      ? null
                      : () => _gitDiscardSelectedCurrent(p),
                  style: TextButton.styleFrom(foregroundColor: CcColors.danger),
                  child: const Text('Rollback'),
                ),
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
  }

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
              const PopupMenuItem(value: 'discard', child: Text('Rollback')),
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
    final selectedCommit = _compareTitle == null && _selectedCommit != null
        ? _gitLog.where((c) => c.hash == _selectedCommit).firstOrNull
        : null;
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
                                trailing: _commitActionsMenu(
                                  p,
                                  c,
                                  compact: true,
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
                    if (selectedCommit != null) ...[
                      TextButton.icon(
                        onPressed: _gitLoading
                            ? null
                            : () => _copyCommitHash(selectedCommit),
                        icon: const Icon(Icons.content_copy_rounded, size: 14),
                        label: const Text('Copy'),
                      ),
                      TextButton.icon(
                        onPressed: _gitLoading
                            ? null
                            : () => _createBranchFromCommit(p, selectedCommit),
                        icon: const Icon(Icons.call_split_rounded, size: 14),
                        label: const Text('Branch'),
                      ),
                      _commitActionsMenu(p, selectedCommit),
                    ],
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

  Widget _commitActionsMenu(
    ProjectCfg p,
    GitCommit c, {
    bool compact = false,
  }) => PopupMenuButton<String>(
    icon: Icon(
      compact ? Icons.more_vert_rounded : Icons.more_horiz_rounded,
      size: compact ? 18 : 17,
    ),
    tooltip: 'Commit actions',
    enabled: !_gitLoading,
    onSelected: (v) {
      if (v == 'copy') _copyCommitHash(c);
      if (v == 'branch') _createBranchFromCommit(p, c);
      if (v == 'cherryPick') _cherryPickCommit(p, c);
      if (v == 'revert') _revertCommit(p, c);
      if (v == 'compare') _selectCommit(p, c);
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'copy', child: Text('Copy Hash')),
      const PopupMenuItem(value: 'branch', child: Text('New Branch from Here')),
      const PopupMenuItem(value: 'compare', child: Text('Show Commit Diff')),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'cherryPick', child: Text('Cherry-pick')),
      const PopupMenuItem(value: 'revert', child: Text('Revert')),
    ],
  );

  Widget _stashView(ProjectCfg p) {
    final selected = _gitStashes
        .where((s) => s.ref == _selectedStash)
        .cast<GitStash?>()
        .firstOrNull;
    if (selected != null && _stashPreviewRef != selected.ref && !_gitLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _selectStash(p, selected);
      });
    }

    return Column(
      children: [
        Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            color: CcColors.panel,
            border: Border(bottom: BorderSide(color: CcColors.border)),
          ),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: _gitLoading ? null : () => _stashPushCurrent(p),
                icon: const Icon(Icons.archive_outlined, size: 16),
                label: const Text('Stash Changes'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _refreshGit,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Refresh'),
              ),
              const Spacer(),
              Text(
                '${_gitStashes.length} shelves',
                style: CcType.code(size: 11.5, color: CcColors.subtle),
              ),
            ],
          ),
        ),
        Expanded(
          child: _gitStashes.isEmpty
              ? centerMsg('没有 stash')
              : Row(
                  children: [
                    SizedBox(
                      width: 370,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          color: CcColors.panel,
                          border: Border(
                            right: BorderSide(color: CcColors.border),
                          ),
                        ),
                        child: ListView.separated(
                          itemCount: _gitStashes.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1, color: CcColors.border),
                          itemBuilder: (_, i) {
                            final s = _gitStashes[i];
                            final isSelected = s.ref == _selectedStash;
                            return Material(
                              color: isSelected
                                  ? CcColors.panelHigh
                                  : Colors.transparent,
                              child: InkWell(
                                onTap: () => _selectStash(p, s),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    8,
                                    8,
                                    8,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.inventory_2_outlined,
                                            size: 18,
                                            color: isSelected
                                                ? CcColors.accentBright
                                                : CcColors.muted,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              s.subject.isEmpty
                                                  ? s.ref
                                                  : s.subject,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: isSelected
                                                    ? CcColors.text
                                                    : CcColors.muted,
                                                fontWeight: isSelected
                                                    ? FontWeight.w600
                                                    : FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        s.branch.isEmpty
                                            ? s.ref
                                            : '${s.ref} · ${s.branch}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: CcType.code(
                                          size: 11.5,
                                          color: CcColors.subtle,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Wrap(
                                        spacing: 4,
                                        runSpacing: 2,
                                        children: [
                                          TextButton(
                                            onPressed: _gitLoading
                                                ? null
                                                : () =>
                                                      _stashApplyCurrent(p, s),
                                            child: const Text('Apply'),
                                          ),
                                          TextButton(
                                            onPressed: _gitLoading
                                                ? null
                                                : () => _stashPopCurrent(p, s),
                                            child: const Text('Pop'),
                                          ),
                                          TextButton(
                                            onPressed: _gitLoading
                                                ? null
                                                : () => _stashDropCurrent(p, s),
                                            child: const Text('Drop'),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Container(
                            height: 34,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: const BoxDecoration(
                              color: CcColors.editorTabBar,
                              border: Border(
                                bottom: BorderSide(color: CcColors.border),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.difference_outlined,
                                  size: 16,
                                  color: CcColors.muted,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    selected == null
                                        ? 'Stash diff'
                                        : '${selected.ref} patch',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: CcType.code(
                                      size: 12,
                                      color: CcColors.muted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: selected == null
                                ? centerMsg('选择 stash 查看 diff')
                                : _gitLoading &&
                                      _stashPreviewRef != selected.ref
                                ? centerMsg('正在加载 stash diff...')
                                : _stashFiles.isEmpty
                                ? centerMsg('这个 stash 没有文本 diff')
                                : DiffView(files: _stashFiles),
                          ),
                        ],
                      ),
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

  Widget _gitOperationBar(ProjectCfg p, GitOperationState op) => Container(
    height: 40,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: CcColors.warning.withValues(alpha: 0.10),
      border: Border(
        bottom: const BorderSide(color: CcColors.border),
        left: BorderSide(
          color: CcColors.warning.withValues(alpha: 0.65),
          width: 3,
        ),
      ),
    ),
    child: Row(
      children: [
        const Icon(
          Icons.warning_amber_rounded,
          size: 17,
          color: CcColors.warning,
        ),
        const SizedBox(width: 8),
        Text(
          op.label,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Resolve conflicts, stage files, then continue or abort.',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CcType.code(size: 11, color: CcColors.subtle),
          ),
        ),
        TextButton.icon(
          onPressed: !_gitLoading && op.canContinue
              ? () => _gitContinueCurrentOperation(p, op)
              : null,
          icon: const Icon(Icons.play_arrow_rounded, size: 15),
          label: const Text('Continue'),
        ),
        TextButton.icon(
          onPressed: !_gitLoading && op.canAbort
              ? () => _gitAbortCurrentOperation(p, op)
              : null,
          icon: const Icon(Icons.stop_circle_outlined, size: 15),
          label: const Text('Abort'),
          style: TextButton.styleFrom(foregroundColor: CcColors.danger),
        ),
        IconButton(
          icon: const Icon(Icons.refresh_rounded, size: 17),
          tooltip: '刷新 Git',
          visualDensity: VisualDensity.compact,
          onPressed: _refreshGit,
        ),
      ],
    ),
  );

  Widget _commitBox(ProjectCfg p, GitStatusSummary? status) {
    final canCommit = (status?.staged ?? 0) > 0 && !_gitLoading;
    final selected = _selectedChangePaths.length;
    final canCommitSelected = selected > 0 && !_gitLoading;
    final hasCommitText = _commitCtl.text.trim().isNotEmpty;
    final canAmend =
        !_gitLoading && ((status?.staged ?? 0) > 0 || hasCommitText);
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
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: canCommit ? () => _gitCommitCurrent(p) : null,
            icon: const Icon(Icons.check_rounded, size: 16),
            label: const Text('Commit'),
          ),
          const SizedBox(width: 6),
          FilledButton.tonalIcon(
            onPressed: canCommit ? () => _gitCommitAndPushCurrent(p) : null,
            icon: const Icon(Icons.upload_rounded, size: 16),
            label: const Text('Commit & Push'),
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            onPressed: canCommitSelected ? () => _gitCommitSelected(p) : null,
            icon: const Icon(Icons.checklist_rounded, size: 16),
            label: Text(selected == 0 ? 'Commit Selected' : 'Commit $selected'),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            onPressed: canAmend ? () => _gitCommitAmendCurrent(p) : null,
            icon: const Icon(Icons.edit_note_rounded, size: 16),
            label: const Text('Amend'),
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

  Future<void> _gitStageSelectedCurrent(ProjectCfg p) async {
    final files =
        _gitChanges
            .where((c) => _selectedChangePaths.contains(c.path) && c.unstaged)
            .map((c) => c.path)
            .toList()
          ..sort();
    if (files.isEmpty) return;
    setState(() => _gitLoading = true);
    try {
      await gitStageFiles(p.path, files);
      await _refreshGit();
      _snack('Stage ${files.length} files 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitUnstageSelectedCurrent(ProjectCfg p) async {
    final files =
        _gitChanges
            .where((c) => _selectedChangePaths.contains(c.path) && c.staged)
            .map((c) => c.path)
            .toList()
          ..sort();
    if (files.isEmpty) return;
    setState(() => _gitLoading = true);
    try {
      await gitUnstageFiles(p.path, files);
      await _refreshGit();
      _snack('Unstage ${files.length} files 完成');
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
      final changes = _gitChanges.where((c) => c.path == file).toList();
      if (changes.isEmpty) {
        await gitRestore(p.path, file);
      } else {
        await gitRestoreChanges(p.path, changes);
      }
      await _refreshGit();
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitDiscardSelectedCurrent(ProjectCfg p) async {
    final changes =
        _gitChanges
            .where(
              (c) => _selectedChangePaths.contains(c.path) && !c.conflicted,
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    if (changes.isEmpty) return;
    final files = changes.map((c) => c.path).toList();
    final preview =
        files.take(8).join('\n') +
        (files.length > 8 ? '\n...and ${files.length - 8} more' : '');
    if (!await _confirm(
      'Rollback selected changes?',
      '$preview\n\n这会恢复 ${files.length} 个文件的工作区改动。',
    )) {
      return;
    }
    setState(() => _gitLoading = true);
    try {
      await gitRestoreChanges(p.path, changes);
      _selectedChangePaths.removeAll(files);
      await _refreshGit();
      _snack('Rollback ${files.length} files 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitContinueCurrentOperation(
    ProjectCfg p,
    GitOperationState op,
  ) async {
    setState(() => _gitLoading = true);
    try {
      await gitContinueOperation(p.path, op.kind);
      await _refreshGit();
      _snack('${op.kind} continue 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitAbortCurrentOperation(
    ProjectCfg p,
    GitOperationState op,
  ) async {
    if (!await _confirm('Abort ${op.kind}?', '这会中止当前 ${op.kind} 操作。')) {
      return;
    }
    setState(() => _gitLoading = true);
    try {
      await gitAbortOperation(p.path, op.kind);
      await _refreshGit();
      _snack('${op.kind} abort 完成');
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

  Future<void> _gitCommitAndPushCurrent(ProjectCfg p) async {
    setState(() => _gitLoading = true);
    try {
      await gitCommit(p.path, _commitCtl.text);
      _commitCtl.clear();
      final pushed = await _gitPushWithUpstreamFallback(p);
      if (!pushed) {
        await _refreshGit();
        _snack('Commit 完成，Push 已取消');
        return;
      }
      await _refreshGit();
      _snack('Commit & Push 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitCommitAmendCurrent(ProjectCfg p) async {
    final message = _commitCtl.text.trim();
    final detail = message.isEmpty
        ? '将 staged changes 合入上一条 commit，并沿用上一条 commit message。'
        : '将 staged changes 合入上一条 commit，并用当前输入框内容替换上一条 commit message。';
    if (!await _confirm('Amend 上一条 commit?', detail)) return;
    setState(() => _gitLoading = true);
    try {
      await gitCommitAmend(p.path, _commitCtl.text);
      _commitCtl.clear();
      await _refreshGit();
      _snack('Amend 完成');
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

  Future<void> _stashPushCurrent(ProjectCfg p) async {
    final ctl = TextEditingController(
      text: 'WIP ${DateTime.now().toIso8601String()}',
    );
    var includeUntracked = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Stash Changes'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctl,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Message'),
              ),
              CheckboxListTile(
                value: includeUntracked,
                onChanged: (v) => setLocal(() => includeUntracked = v ?? true),
                title: const Text('Include untracked files'),
                controlAffinity: ListTileControlAffinity.leading,
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
              child: const Text('Stash'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    setState(() => _gitLoading = true);
    try {
      await gitStashPush(p.path, ctl.text, includeUntracked: includeUntracked);
      await _refreshGit();
      _snack('Stash 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _stashApplyCurrent(ProjectCfg p, GitStash s) async {
    setState(() => _gitLoading = true);
    try {
      await gitStashApply(p.path, s.ref);
      await _refreshGit();
      _snack('Stash apply 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _stashPopCurrent(ProjectCfg p, GitStash s) async {
    setState(() => _gitLoading = true);
    try {
      await gitStashPop(p.path, s.ref);
      await _refreshGit();
      _snack('Stash pop 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _stashDropCurrent(ProjectCfg p, GitStash s) async {
    if (!await _confirm('Drop stash?', s.ref)) return;
    setState(() => _gitLoading = true);
    try {
      await gitStashDrop(p.path, s.ref);
      await _refreshGit();
      _snack('Stash drop 完成');
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
      final pushed = await _gitPushWithUpstreamFallback(p);
      if (!pushed) return;
      await _refreshGit();
      _snack('Push 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<bool> _gitPushWithUpstreamFallback(ProjectCfg p) async {
    try {
      await gitPush(p.path);
      return true;
    } catch (e) {
      if (!mounted) return false;
      final msg = errorText(e);
      if (!msg.contains('upstream') && !msg.contains('no upstream')) {
        rethrow;
      }
      setState(() => _gitLoading = false);
      final ok = await _confirm('设置 upstream 并 push?', msg);
      if (!ok) return false;
      setState(() => _gitLoading = true);
      await gitPush(p.path, setUpstream: true);
      return true;
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
        onMerge: (branch) async => _mergeBranchIntoCurrent(p, branch),
        onRebase: (branch) async => _rebaseCurrentOntoBranch(p, branch),
      ),
    );
  }

  Future<void> _mergeBranchIntoCurrent(ProjectCfg p, GitBranch branch) async {
    final current = _gitStatus?.branch ?? 'current';
    final ok = await _confirm(
      'Merge into current branch?',
      '${branch.name}\n\n会执行 `git merge --no-ff ${branch.name}`，把它合并到 $current。',
    );
    if (!ok) return;
    setState(() => _gitLoading = true);
    try {
      await gitMergeBranch(p.path, branch.name);
      await _refreshGit();
      _snack('Merge 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
      }
      rethrow;
    }
  }

  Future<void> _rebaseCurrentOntoBranch(ProjectCfg p, GitBranch branch) async {
    final current = _gitStatus?.branch ?? 'current';
    final ok = await _confirm(
      'Rebase current branch?',
      '$current -> ${branch.name}\n\n会执行 `git rebase ${branch.name}`，把当前分支变基到选中分支。',
    );
    if (!ok) return;
    setState(() => _gitLoading = true);
    try {
      await gitRebaseOnto(p.path, branch.name);
      await _refreshGit();
      _snack('Rebase 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
      }
      rethrow;
    }
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
  final Future<void> Function(GitBranch branch) onMerge;
  final Future<void> Function(GitBranch branch) onRebase;
  const _BranchDialog({
    required this.project,
    required this.onCheckout,
    required this.onCreate,
    required this.onRename,
    required this.onDelete,
    required this.onCompare,
    required this.onMerge,
    required this.onRebase,
  });

  @override
  State<_BranchDialog> createState() => _BranchDialogState();
}

class _BranchDialogState extends State<_BranchDialog> {
  List<GitBranch> _branches = const [];
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

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 760,
        height: 660,
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
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    tooltip: '刷新分支',
                    onPressed: _load,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _BranchListPane(
                project: widget.project,
                branches: _branches,
                loading: _loading,
                error: _error,
                onRefresh: _load,
                onCheckout: (branch) async {
                  await widget.onCheckout(branch);
                  if (context.mounted) Navigator.pop(context);
                },
                onCreate: widget.onCreate,
                onRename: widget.onRename,
                onDelete: widget.onDelete,
                onCompare: widget.onCompare,
                onMerge: (branch) async {
                  await widget.onMerge(branch);
                  if (context.mounted) Navigator.pop(context);
                },
                onRebase: (branch) async {
                  await widget.onRebase(branch);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BranchListPane extends StatefulWidget {
  final ProjectCfg project;
  final List<GitBranch> branches;
  final bool loading;
  final String? error;
  final bool embedded;
  final Future<void> Function() onRefresh;
  final Future<void> Function(GitBranch branch) onCheckout;
  final Future<void> Function(String branch, String? start) onCreate;
  final Future<void> Function(String oldName, String newName) onRename;
  final Future<void> Function(String branch, bool force) onDelete;
  final Future<void> Function(GitBranch branch) onCompare;
  final Future<void> Function(GitBranch branch) onMerge;
  final Future<void> Function(GitBranch branch) onRebase;

  const _BranchListPane({
    required this.project,
    required this.branches,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onCheckout,
    required this.onCreate,
    required this.onRename,
    required this.onDelete,
    required this.onCompare,
    required this.onMerge,
    required this.onRebase,
    this.embedded = false,
  });

  @override
  State<_BranchListPane> createState() => _BranchListPaneState();
}

class _BranchListPaneState extends State<_BranchListPane> {
  final _queryCtl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _queryCtl.dispose();
    super.dispose();
  }

  List<GitBranch> get _filteredBranches {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.branches;
    return widget.branches.where((b) {
      final fields = [
        b.name,
        b.remoteName ?? '',
        b.localName ?? '',
        b.remote ? 'remote' : 'local',
      ];
      return fields.any((f) => f.toLowerCase().contains(q));
    }).toList();
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) await widget.onRefresh();
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  Future<void> _checkout(GitBranch b) async {
    if (b.current) return;
    await _run(() => widget.onCheckout(b));
  }

  Future<void> _createBranch() async {
    final ctl = TextEditingController(text: _query.trim());
    final current = widget.branches
        .where((b) => b.current)
        .map((b) => b.name)
        .firstOrNull;
    final startCtl = TextEditingController(text: current ?? '');
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
    await _run(
      () => widget.onCreate(
        branch,
        startCtl.text.trim().isEmpty ? null : startCtl.text.trim(),
      ),
    );
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
    await _run(() => widget.onRename(b.name, next));
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
    await _run(() => widget.onDelete(b.name, force));
  }

  Future<void> _mergeBranch(GitBranch b) async {
    if (b.current) return;
    await _run(() => widget.onMerge(b));
  }

  Future<void> _rebaseBranch(GitBranch b) async {
    if (b.current) return;
    await _run(() => widget.onRebase(b));
  }

  Widget _branchSection(String label, List<GitBranch> branches, IconData icon) {
    if (branches.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(
            color: CcColors.editorTabBar,
            border: Border(
              top: BorderSide(color: CcColors.border),
              bottom: BorderSide(color: CcColors.border),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 15, color: CcColors.muted),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                '${branches.length}',
                style: CcType.code(size: 11, color: CcColors.subtle),
              ),
            ],
          ),
        ),
        for (final b in branches) _branchRow(b),
      ],
    );
  }

  Widget _branchRow(GitBranch b) {
    final subtitle = b.current
        ? 'current branch'
        : b.remote
        ? 'remote · checkout creates ${b.localName ?? b.name}'
        : 'local branch';
    final compact = widget.embedded;
    return Material(
      color: b.current
          ? CcColors.accent.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: b.current ? null : () => _checkout(b),
        onDoubleTap: b.current ? null : () => _checkout(b),
        child: Container(
          constraints: BoxConstraints(minHeight: compact ? 44 : 50),
          padding: const EdgeInsets.only(left: 12, right: 6),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: b.current ? CcColors.accent : Colors.transparent,
                width: 2,
              ),
              bottom: const BorderSide(color: CcColors.border, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Icon(
                b.remote
                    ? Icons.cloud_queue_rounded
                    : Icons.account_tree_rounded,
                size: 17,
                color: b.current ? CcColors.accentBright : CcColors.muted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            b.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CcType.code(
                              size: compact ? 12.5 : 13,
                              color: b.current ? CcColors.text : CcColors.muted,
                              weight: b.current
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (b.current) ...[
                          const SizedBox(width: 8),
                          tag('current', CcColors.ok),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: CcColors.subtle),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (!b.current)
                TextButton(
                  onPressed: () => _checkout(b),
                  child: const Text('Checkout'),
                ),
              if (!b.current && !compact)
                TextButton(
                  onPressed: () => _mergeBranch(b),
                  child: const Text('Merge'),
                ),
              TextButton(
                onPressed: () => _run(() => widget.onCompare(b)),
                child: const Text('Compare'),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, size: 18),
                tooltip: '分支操作',
                onSelected: (v) {
                  if (v == 'checkout') _checkout(b);
                  if (v == 'compare') _run(() => widget.onCompare(b));
                  if (v == 'merge') _mergeBranch(b);
                  if (v == 'rebase') _rebaseBranch(b);
                  if (v == 'rename') _renameBranch(b);
                  if (v == 'delete') _deleteBranch(b);
                  if (v == 'forceDelete') _deleteBranch(b, force: true);
                },
                itemBuilder: (_) => [
                  if (!b.current)
                    const PopupMenuItem(
                      value: 'checkout',
                      child: Text('Checkout'),
                    ),
                  const PopupMenuItem(
                    value: 'compare',
                    child: Text('Compare with Current'),
                  ),
                  if (!b.current) ...[
                    const PopupMenuItem(
                      value: 'merge',
                      child: Text('Merge into Current'),
                    ),
                    const PopupMenuItem(
                      value: 'rebase',
                      child: Text('Rebase Current onto Selected'),
                    ),
                  ],
                  if (!b.remote) ...[
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    if (!b.current)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete'),
                      ),
                    if (!b.current)
                      const PopupMenuItem(
                        value: 'forceDelete',
                        child: Text('Force Delete'),
                      ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final branches = _filteredBranches;
    final locals = branches.where((b) => !b.remote).toList();
    final remotes = branches.where((b) => b.remote).toList();
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: const BoxDecoration(
            color: CcColors.panel,
            border: Border(bottom: BorderSide(color: CcColors.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryCtl,
                  autofocus: !widget.embedded,
                  decoration: const InputDecoration(
                    hintText: '搜索或输入新分支名',
                    isDense: true,
                    prefixIcon: Icon(Icons.search_rounded, size: 18),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                  onSubmitted: (_) {
                    final q = _query.trim();
                    final exact = branches
                        .where((b) => b.name == q || b.localName == q)
                        .firstOrNull;
                    if (exact != null) {
                      _checkout(exact);
                    } else {
                      _createBranch();
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _createBranch,
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('New Branch'),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 18),
                tooltip: '刷新分支',
                onPressed: widget.onRefresh,
              ),
            ],
          ),
        ),
        Expanded(
          child: widget.loading
              ? const Center(child: CircularProgressIndicator())
              : widget.error != null
              ? centerMsg(widget.error!, onRetry: widget.onRefresh)
              : branches.isEmpty
              ? centerMsg('没有匹配分支')
              : ListView(
                  children: [
                    _branchSection(
                      'Local Branches',
                      locals,
                      Icons.account_tree_rounded,
                    ),
                    _branchSection(
                      'Remote Branches',
                      remotes,
                      Icons.cloud_queue_rounded,
                    ),
                  ],
                ),
        ),
      ],
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
      if (_searchSkipDirs.contains(name)) continue;
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

class _SearchHit {
  final String project;
  final String path;
  final String rel;
  final int line;
  final String text;

  const _SearchHit({
    required this.project,
    required this.path,
    required this.rel,
    required this.line,
    required this.text,
  });
}

List<_CodeSymbol> _extractCodeSymbols(String path, String text) {
  final ext = path.split('.').last.toLowerCase();
  final symbols = <_CodeSymbol>[];
  final lines = text.split('\n');
  final markdown = ext == 'md' || ext == 'markdown';

  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final trimmed = raw.trimLeft();
    if (trimmed.isEmpty) continue;
    if (!markdown &&
        (trimmed.startsWith('//') ||
            trimmed.startsWith('#') ||
            trimmed.startsWith('*'))) {
      continue;
    }
    final indent = raw.length - trimmed.length;
    _CodeSymbol? symbol;
    switch (ext) {
      case 'go':
        symbol = _goSymbol(trimmed, i + 1, indent);
      case 'dart':
        symbol = _dartLikeSymbol(trimmed, i + 1, indent);
      case 'js':
      case 'jsx':
      case 'ts':
      case 'tsx':
        symbol = _jsLikeSymbol(trimmed, i + 1, indent);
      case 'py':
        symbol = _pythonSymbol(trimmed, i + 1, indent);
      case 'java':
      case 'kt':
      case 'kts':
        symbol = _jvmSymbol(trimmed, i + 1, indent);
      case 'rs':
        symbol = _rustSymbol(trimmed, i + 1, indent);
      case 'md':
      case 'markdown':
        symbol = _markdownSymbol(trimmed, i + 1, indent);
      default:
        symbol = _genericSymbol(trimmed, i + 1, indent);
    }
    if (symbol != null) symbols.add(symbol);
    if (symbols.length >= 500) break;
  }
  return symbols;
}

_CodeSymbol? _goSymbol(String line, int lineNo, int indent) {
  var m = RegExp(
    r'^(?:func\s+\([^)]*\)\s*)?func\s+([A-Za-z_][\w]*)\s*\(',
  ).firstMatch(line);
  if (m != null) {
    return _symbol(m.group(1)!, 'func', lineNo, indent, Icons.functions);
  }
  m = RegExp(
    r'^type\s+([A-Za-z_][\w]*)\s+(struct|interface)\b',
  ).firstMatch(line);
  if (m != null) {
    final kind = m.group(2)!;
    return _symbol(
      m.group(1)!,
      kind,
      lineNo,
      indent,
      kind == 'interface' ? Icons.hub_outlined : Icons.data_object_rounded,
    );
  }
  return null;
}

_CodeSymbol? _dartLikeSymbol(String line, int lineNo, int indent) {
  var m = RegExp(
    r'^(?:abstract\s+|base\s+|final\s+|sealed\s+|mixin\s+)*'
    r'(class|mixin|enum|extension)\s+([A-Za-z_][\w]*)',
  ).firstMatch(line);
  if (m != null) {
    return _symbol(m.group(2)!, m.group(1)!, lineNo, indent, Icons.category);
  }
  m = RegExp(
    r'^(?:static\s+)?(?:Future<[^>]+>|[\w<>?,\s]+)\s+'
    r'([A-Za-z_][\w]*)\s*\([^;]*\)\s*(?:async\s*)?[{=>]?',
  ).firstMatch(line);
  if (m != null && !_controlWords.contains(m.group(1))) {
    return _symbol(m.group(1)!, 'method', lineNo, indent, Icons.functions);
  }
  return null;
}

_CodeSymbol? _jsLikeSymbol(String line, int lineNo, int indent) {
  var m = RegExp(
    r'^(?:export\s+default\s+|export\s+)?class\s+([\w$]+)',
  ).firstMatch(line);
  if (m != null) {
    return _symbol(m.group(1)!, 'class', lineNo, indent, Icons.category);
  }
  m = RegExp(
    r'^(?:export\s+)?(?:async\s+)?function\s+([\w$]+)\s*\(',
  ).firstMatch(line);
  if (m != null) {
    return _symbol(m.group(1)!, 'function', lineNo, indent, Icons.functions);
  }
  m = RegExp(
    r'^(?:export\s+)?(?:const|let|var)\s+([\w$]+)\s*=\s*(?:async\s*)?'
    r'(?:\([^)]*\)|[\w$]+)?\s*=>',
  ).firstMatch(line);
  if (m != null) {
    return _symbol(m.group(1)!, 'function', lineNo, indent, Icons.functions);
  }
  m = RegExp(r'^([\w$]+)\s*\([^)]*\)\s*\{').firstMatch(line);
  if (m != null && !_controlWords.contains(m.group(1))) {
    return _symbol(m.group(1)!, 'method', lineNo, indent, Icons.functions);
  }
  return null;
}

_CodeSymbol? _pythonSymbol(String line, int lineNo, int indent) {
  final m = RegExp(
    r'^(class|def|async\s+def)\s+([A-Za-z_][\w]*)',
  ).firstMatch(line);
  if (m == null) return null;
  final kind = m.group(1)!.replaceAll('async ', '');
  return _symbol(
    m.group(2)!,
    kind,
    lineNo,
    indent,
    kind == 'class' ? Icons.category : Icons.functions,
  );
}

_CodeSymbol? _jvmSymbol(String line, int lineNo, int indent) {
  var m = RegExp(
    r'^(?:[\w\s]+)?(class|interface|enum|object)\s+([\w$]+)',
  ).firstMatch(line);
  if (m != null) {
    return _symbol(m.group(2)!, m.group(1)!, lineNo, indent, Icons.category);
  }
  m = RegExp(
    r'^(?:public|private|protected|internal|static|final|open|override|'
    r'suspend|fun|\s)+[\w<>\[\]?,\s.]*\s+([\w$]+)\s*\(',
  ).firstMatch(line);
  if (m != null && !_controlWords.contains(m.group(1))) {
    return _symbol(m.group(1)!, 'method', lineNo, indent, Icons.functions);
  }
  return null;
}

_CodeSymbol? _rustSymbol(String line, int lineNo, int indent) {
  final m = RegExp(
    r'^(?:pub\s+)?(struct|enum|trait|impl|fn)\s+([A-Za-z_][\w]*)?',
  ).firstMatch(line);
  if (m == null) return null;
  final kind = m.group(1)!;
  final name = m.group(2) ?? 'impl';
  return _symbol(
    name,
    kind,
    lineNo,
    indent,
    kind == 'fn' ? Icons.functions : Icons.category,
  );
}

_CodeSymbol? _markdownSymbol(String line, int lineNo, int indent) {
  final m = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(line);
  if (m == null) return null;
  return _symbol(
    m.group(2)!.trim(),
    'h${m.group(1)!.length}',
    lineNo,
    indent + (m.group(1)!.length - 1) * 2,
    Icons.notes_rounded,
  );
}

_CodeSymbol? _genericSymbol(String line, int lineNo, int indent) {
  final m = RegExp(
    r'^(?:class|interface|enum|func|function|def)\s+([A-Za-z_][\w]*)',
  ).firstMatch(line);
  if (m == null) return null;
  return _symbol(m.group(1)!, 'symbol', lineNo, indent, Icons.account_tree);
}

_CodeSymbol _symbol(
  String name,
  String kind,
  int line,
  int indent,
  IconData icon,
) =>
    _CodeSymbol(name: name, kind: kind, line: line, indent: indent, icon: icon);

const _controlWords = {
  'if',
  'for',
  'while',
  'switch',
  'catch',
  'return',
  'else',
};

class _FindInFilesDialog extends StatefulWidget {
  final List<WorkspaceCfg> workspaces;
  const _FindInFilesDialog({required this.workspaces});

  @override
  State<_FindInFilesDialog> createState() => _FindInFilesDialogState();
}

class _FindInFilesDialogState extends State<_FindInFilesDialog> {
  final _ctl = TextEditingController();
  List<_SearchHit> _hits = const [];
  bool _loading = false;
  String _query = '';
  String? _error;
  int _searchId = 0;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _search(String value) async {
    final query = value.trim();
    final id = ++_searchId;
    setState(() {
      _query = query;
      _error = null;
      _hits = const [];
      _loading = query.length >= 2;
    });
    if (query.length < 2) return;
    try {
      final out = <_SearchHit>[];
      for (final ws in widget.workspaces) {
        for (final p in ws.projects) {
          await _searchDir(Directory(p.path), p.path, p.name, query, out);
          if (out.length >= 300 || id != _searchId) break;
        }
        if (out.length >= 300 || id != _searchId) break;
      }
      if (!mounted || id != _searchId) return;
      setState(() {
        _hits = out;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _searchId) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  Future<void> _searchDir(
    Directory dir,
    String root,
    String project,
    String query,
    List<_SearchHit> out,
  ) async {
    if (out.length >= 300) return;
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      if (out.length >= 300) return;
      final name = e.path.split('/').last;
      if (_searchSkipDirs.contains(name)) continue;
      if (e is Directory) {
        await _searchDir(e, root, project, query, out);
      } else if (e is File) {
        await _searchFile(e, root, project, query, out);
      }
    }
  }

  Future<void> _searchFile(
    File file,
    String root,
    String project,
    String query,
    List<_SearchHit> out,
  ) async {
    if (out.length >= 300) return;
    final name = file.path.split('/').last;
    if (_looksBinaryOrHuge(file, name)) return;
    String content;
    try {
      content = await file.readAsString();
    } catch (_) {
      return;
    }
    final lower = query.toLowerCase();
    final rel = file.path.startsWith('$root/')
        ? file.path.substring(root.length + 1)
        : file.path;
    final lines = content.split('\n');
    for (var i = 0; i < lines.length && out.length < 300; i++) {
      final line = lines[i];
      if (!line.toLowerCase().contains(lower)) continue;
      out.add(
        _SearchHit(
          project: project,
          path: file.path,
          rel: rel,
          line: i + 1,
          text: line.trim(),
        ),
      );
    }
  }

  bool _looksBinaryOrHuge(File file, String name) {
    try {
      if (file.lengthSync() > 700 * 1024) return true;
    } catch (_) {
      return true;
    }
    final ext = name.split('.').last.toLowerCase();
    const binary = {
      'png',
      'jpg',
      'jpeg',
      'gif',
      'webp',
      'ico',
      'pdf',
      'zip',
      'gz',
      'tar',
      'jar',
      'class',
      'so',
      'dylib',
      'a',
      'o',
      'mp4',
      'mov',
      'mp3',
    };
    return binary.contains(ext);
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 860,
      height: 680,
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
                  Icons.search_rounded,
                  size: 17,
                  color: CcColors.muted,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Find in Files',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (_hits.isNotEmpty)
                  Text(
                    '${_hits.length} results',
                    style: CcType.code(size: 11.5, color: CcColors.subtle),
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
              controller: _ctl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search text in project files',
                isDense: true,
                prefixIcon: Icon(Icons.search_rounded, size: 18),
              ),
              onChanged: _search,
              onSubmitted: (_) {
                if (_hits.isNotEmpty) Navigator.pop(context, _hits.first);
              },
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _error != null
                ? centerMsg(_error!, onRetry: () => _search(_query))
                : _query.length < 2
                ? centerMsg('输入至少 2 个字符开始搜索')
                : !_loading && _hits.isEmpty
                ? centerMsg('没有匹配结果')
                : ListView.separated(
                    itemCount: _hits.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: CcColors.border),
                    itemBuilder: (_, i) {
                      final h = _hits[i];
                      return ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.manage_search_rounded,
                          size: 18,
                          color: CcColors.muted,
                        ),
                        title: Text(
                          h.text.isEmpty ? ' ' : h.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CcType.code(size: 12.5),
                        ),
                        subtitle: Text(
                          '${h.project}/${h.rel}:${h.line}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CcType.code(size: 11, color: CcColors.subtle),
                        ),
                        onTap: () => Navigator.pop(context, h),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}

class _FileLineHit {
  final int line;
  final String text;

  const _FileLineHit({required this.line, required this.text});
}

class _FileStructureDialog extends StatefulWidget {
  final String path;
  final List<_CodeSymbol> symbols;
  const _FileStructureDialog({required this.path, required this.symbols});

  @override
  State<_FileStructureDialog> createState() => _FileStructureDialogState();
}

class _FileStructureDialogState extends State<_FileStructureDialog> {
  final _ctl = TextEditingController();
  String _query = '';

  List<_CodeSymbol> get _filtered {
    final q = _query.toLowerCase();
    if (q.isEmpty) return widget.symbols;
    return widget.symbols
        .where(
          (s) =>
              s.name.toLowerCase().contains(q) ||
              s.kind.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.path.split('/').last;
    final symbols = _filtered;
    return Dialog(
      child: SizedBox(
        width: 680,
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
                      'File Structure · $name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    '${symbols.length}/${widget.symbols.length}',
                    style: CcType.code(size: 11.5, color: CcColors.subtle),
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
                controller: _ctl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search symbols',
                  isDense: true,
                  prefixIcon: Icon(Icons.filter_list_rounded, size: 18),
                ),
                onChanged: (v) => setState(() => _query = v.trim()),
                onSubmitted: (_) {
                  if (symbols.isNotEmpty) Navigator.pop(context, symbols.first);
                },
              ),
            ),
            Expanded(
              child: symbols.isEmpty
                  ? centerMsg('没有匹配符号')
                  : ListView.separated(
                      itemCount: symbols.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, color: CcColors.border),
                      itemBuilder: (_, i) {
                        final s = symbols[i];
                        final level = (s.indent ~/ 2).clamp(0, 8).toDouble();
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.only(
                            left: 14 + level * 14,
                            right: 12,
                          ),
                          leading: Icon(
                            s.icon,
                            size: 18,
                            color: CcColors.accentBright,
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  s.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: CcType.code(size: 12.5),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                s.kind,
                                style: CcType.code(
                                  size: 10.5,
                                  color: CcColors.subtle,
                                ),
                              ),
                            ],
                          ),
                          trailing: Text(
                            '${s.line}',
                            style: CcType.code(
                              size: 11,
                              color: CcColors.subtle,
                            ),
                          ),
                          onTap: () => Navigator.pop(context, s),
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

class _FindInCurrentFileDialog extends StatefulWidget {
  final String path;
  final String text;
  const _FindInCurrentFileDialog({required this.path, required this.text});

  @override
  State<_FindInCurrentFileDialog> createState() =>
      _FindInCurrentFileDialogState();
}

class _FindInCurrentFileDialogState extends State<_FindInCurrentFileDialog> {
  final _ctl = TextEditingController();
  List<_FileLineHit> _hits = const [];
  String _query = '';

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _search(String value) {
    final query = value.trim();
    final out = <_FileLineHit>[];
    if (query.isNotEmpty) {
      final lower = query.toLowerCase();
      final lines = widget.text.split('\n');
      for (var i = 0; i < lines.length && out.length < 300; i++) {
        final line = lines[i];
        if (!line.toLowerCase().contains(lower)) continue;
        out.add(_FileLineHit(line: i + 1, text: line.trim()));
      }
    }
    setState(() {
      _query = query;
      _hits = out;
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.path.split('/').last;
    return Dialog(
      child: SizedBox(
        width: 760,
        height: 560,
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
                    Icons.search_rounded,
                    size: 17,
                    color: CcColors.muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Find in File · $name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (_hits.isNotEmpty)
                    Text(
                      '${_hits.length} matches',
                      style: CcType.code(size: 11.5, color: CcColors.subtle),
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
                controller: _ctl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search in current file',
                  isDense: true,
                  prefixIcon: Icon(Icons.search_rounded, size: 18),
                ),
                onChanged: _search,
                onSubmitted: (_) {
                  if (_hits.isNotEmpty) {
                    Navigator.pop(context, _hits.first.line);
                  }
                },
              ),
            ),
            Expanded(
              child: _query.isEmpty
                  ? centerMsg('输入内容查找当前文件')
                  : _hits.isEmpty
                  ? centerMsg('没有匹配结果')
                  : ListView.separated(
                      itemCount: _hits.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, color: CcColors.border),
                      itemBuilder: (_, i) {
                        final h = _hits[i];
                        return ListTile(
                          dense: true,
                          leading: Text(
                            '${h.line}',
                            textAlign: TextAlign.right,
                            style: CcType.code(
                              size: 11,
                              color: CcColors.subtle,
                            ),
                          ),
                          title: Text(
                            h.text.isEmpty ? ' ' : h.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CcType.code(size: 12.5),
                          ),
                          onTap: () => Navigator.pop(context, h.line),
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

class _GoToLineDialog extends StatefulWidget {
  final String fileName;
  final int lineCount;
  final int? initialLine;
  const _GoToLineDialog({
    required this.fileName,
    required this.lineCount,
    this.initialLine,
  });

  @override
  State<_GoToLineDialog> createState() => _GoToLineDialogState();
}

class _GoToLineDialogState extends State<_GoToLineDialog> {
  late final TextEditingController _ctl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: '${widget.initialLine ?? ''}');
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() {
    final line = int.tryParse(_ctl.text.trim());
    if (line == null || line < 1 || line > widget.lineCount) {
      setState(() => _error = '请输入 1-${widget.lineCount} 之间的行号');
      return;
    }
    Navigator.pop(context, line);
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
                  Icons.format_list_numbered_rounded,
                  size: 17,
                  color: CcColors.muted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Go to Line · ${widget.fileName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
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
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _ctl,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Line number',
                    hintText: '1-${widget.lineCount}',
                    errorText: _error,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      '${widget.lineCount} lines',
                      style: CcType.code(size: 11.5, color: CcColors.subtle),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _submit, child: const Text('Go')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _BlameDialog extends StatefulWidget {
  final ProjectCfg project;
  final String relPath;
  const _BlameDialog({required this.project, required this.relPath});

  @override
  State<_BlameDialog> createState() => _BlameDialogState();
}

class _BlameDialogState extends State<_BlameDialog> {
  List<GitBlameLine> _lines = const [];
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
      final lines = await gitBlame(widget.project.path, widget.relPath);
      if (!mounted) return;
      setState(() {
        _lines = lines;
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

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 980,
      height: 720,
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
                  Icons.person_search_rounded,
                  size: 17,
                  color: CcColors.muted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Annotate · ${widget.relPath}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  tooltip: '刷新',
                  onPressed: _load,
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _error != null
                ? centerMsg(_error!, onRetry: _load)
                : _lines.isEmpty && !_loading
                ? centerMsg('没有 blame 信息')
                : ListView.builder(
                    itemCount: _lines.length,
                    itemBuilder: (_, i) {
                      final l = _lines[i];
                      final date = l.date.millisecondsSinceEpoch == 0
                          ? ''
                          : relativeTime(l.date);
                      return Container(
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: CcColors.border,
                              width: 0.5,
                            ),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 58,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 5),
                                child: Text(
                                  '${l.line}',
                                  textAlign: TextAlign.right,
                                  style: CcType.code(
                                    size: 11,
                                    color: CcColors.subtle,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 220,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${l.hash.substring(0, 8)} · ${l.author}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: CcType.code(
                                        size: 11.5,
                                        color: CcColors.muted,
                                      ),
                                    ),
                                    Text(
                                      date.isEmpty
                                          ? l.summary
                                          : '$date · ${l.summary}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: CcColors.subtle,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  10,
                                  5,
                                  10,
                                  5,
                                ),
                                child: Text(
                                  l.content.isEmpty ? ' ' : l.content,
                                  style: CcType.code(size: 12.5),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
