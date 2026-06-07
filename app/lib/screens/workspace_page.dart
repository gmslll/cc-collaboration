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

part 'workspace/branch_dialog.dart';
part 'workspace/navigation_dialogs.dart';
part 'workspace/search_dialogs.dart';
part 'workspace/git_history_dialogs.dart';
part 'workspace/git_mixin.dart';

enum _BottomTool { terminal, git }

enum _GitView { changes, log, branches, stash }

enum _LeftToolView { project, structure, changes, branches, log, stash }

enum _ChangeFilter { all, staged, unstaged, untracked, conflicts }

enum _BranchFilter { all, local, remote, current, unpublished, diverged }

const _workingTreeDiffSelection = '__working_tree_diff__';

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
  String get key => '$path:${line ?? 0}';
  String get name => path.split('/').last;
  String get label => line == null ? path : '$path:$line';
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

class _WorkspacePageState extends State<WorkspacePage>
    with TerminalHost, _GitMixin {
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
  _GitView _gitView = _GitView.changes;
  final _changesQueryCtl = TextEditingController();
  final _structureQueryCtl = TextEditingController();
  final _workspaceFocus = FocusNode(debugLabel: 'workspace-shell');
  final _commitFocus = FocusNode(debugLabel: 'commit-message');
  final List<String> _recentFiles = [];
  final List<_CodeLocation> _recentLocations = [];
  String _structureQuery = '';
  bool _projectCollapsed = Prefs.getBool('ws.projectCollapsed');
  bool _projectAutoscrollFromSource = Prefs.getBool(
    'ws.projectAutoscrollFromSource',
  );
  String? _revealedProjectFilePath;
  _LeftToolView _leftToolView = _leftToolViewFromPref(
    Prefs.getString('ws.leftTool', def: 'project'),
  );
  bool _detailCollapsed = Prefs.getBool('ws.detailCollapsed');
  bool _terminalCollapsed = Prefs.getBool('ws.terminalCollapsed');
  double _treeWidth = Prefs.getDouble('ws.treeWidth', def: 340);
  double _detailWidth = Prefs.getDouble('ws.detailWidth', def: 520);
  double _terminalHeight = Prefs.getDouble('ws.terminalHeight', def: 360);
  // shared comfortable-but-compact density for the tree's leaf rows.
  static const _tileDensity = VisualDensity(vertical: -1);

  @override
  String? get persistKey => 'workspace_sessions';

  static _LeftToolView _leftToolViewFromPref(String value) => switch (value) {
    'structure' => _LeftToolView.structure,
    'changes' => _LeftToolView.changes,
    'branches' => _LeftToolView.branches,
    'log' => _LeftToolView.log,
    'stash' => _LeftToolView.stash,
    _ => _LeftToolView.project,
  };

  static String _leftToolPref(_LeftToolView view) => switch (view) {
    _LeftToolView.project => 'project',
    _LeftToolView.structure => 'structure',
    _LeftToolView.changes => 'changes',
    _LeftToolView.branches => 'branches',
    _LeftToolView.log => 'log',
    _LeftToolView.stash => 'stash',
  };

  static _GitView? _gitViewForLeftTool(_LeftToolView view) => switch (view) {
    _LeftToolView.changes => _GitView.changes,
    _LeftToolView.branches => _GitView.branches,
    _LeftToolView.log => _GitView.log,
    _LeftToolView.stash => _GitView.stash,
    _ => null,
  };

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
    _changesQueryCtl.dispose();
    _structureQueryCtl.dispose();
    _workspaceFocus.dispose();
    _commitFocus.dispose();
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

  @override
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
      _recentLocations.removeWhere((l) => l.key == target.key);
      _recentLocations.insert(0, target);
      if (_recentLocations.length > 30) {
        _recentLocations.removeRange(30, _recentLocations.length);
      }
      if (_projectAutoscrollFromSource) {
        _revealedProjectFilePath = path;
      }
    });
    if (_projectAutoscrollFromSource) _expandProjectForFile(path);
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

  Future<void> _closeActiveCodeFile() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) return;
    await _closeCodeFile(_activeFile);
  }

  void _activateCodeTab(int index) {
    if (index < 0 || index >= _codeFiles.length) return;
    setState(() {
      _activeFile = index;
      if (_projectAutoscrollFromSource) {
        _revealedProjectFilePath = _codeFiles[index].path;
      }
    });
    if (_projectAutoscrollFromSource) {
      _expandProjectForFile(_codeFiles[index].path);
    }
  }

  void _selectNextCodeTab() {
    if (_codeFiles.isEmpty) return;
    setState(() {
      _activeFile = _activeFile < 0 ? 0 : (_activeFile + 1) % _codeFiles.length;
      if (_projectAutoscrollFromSource && _activeFile >= 0) {
        _revealedProjectFilePath = _codeFiles[_activeFile].path;
      }
    });
    if (_projectAutoscrollFromSource && _activeFile >= 0) {
      _expandProjectForFile(_codeFiles[_activeFile].path);
    }
  }

  void _selectPreviousCodeTab() {
    if (_codeFiles.isEmpty) return;
    setState(() {
      _activeFile = _activeFile <= 0 ? _codeFiles.length - 1 : _activeFile - 1;
      if (_projectAutoscrollFromSource && _activeFile >= 0) {
        _revealedProjectFilePath = _codeFiles[_activeFile].path;
      }
    });
    if (_projectAutoscrollFromSource && _activeFile >= 0) {
      _expandProjectForFile(_codeFiles[_activeFile].path);
    }
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

  Future<void> _closeCodeFilesToRight(int keep) async {
    if (keep < 0 || keep >= _codeFiles.length - 1) return;
    final dirty = _codeFiles
        .asMap()
        .entries
        .where((e) => e.key > keep && e.value.dirty)
        .map((e) => e.value.path)
        .toList();
    if (dirty.isNotEmpty) {
      final ok = await _confirm(
        '关闭右侧未保存文件?',
        dirty.take(5).join('\n') +
            (dirty.length > 5 ? '\n...and ${dirty.length - 5} more' : ''),
      );
      if (!ok) return;
    }
    setState(() {
      _codeFiles.removeRange(keep + 1, _codeFiles.length);
      if (_activeFile > keep) _activeFile = keep;
    });
  }

  Future<void> _closeUnmodifiedCodeFiles() async {
    if (_codeFiles.every((f) => f.dirty)) {
      _snack('没有可关闭的未修改文件');
      return;
    }
    setState(() {
      final activePath = _activeFile >= 0 && _activeFile < _codeFiles.length
          ? _codeFiles[_activeFile].path
          : null;
      _codeFiles.removeWhere((f) => !f.dirty);
      if (_codeFiles.isEmpty) {
        _activeFile = -1;
      } else {
        final next = activePath == null
            ? -1
            : _codeFiles.indexWhere((f) => f.path == activePath);
        _activeFile = next >= 0 ? next : 0;
      }
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

  void _expandProjectForFile(String path) {
    final hit = _projectForFile(path);
    if (hit == null) {
      return;
    }
    _ctlFor(hit.project.path).expand();
    Prefs.setBool('ws.sec.${hit.project.path}.files', false);
    _selectGitProject(hit.project);
  }

  void _revealFileInProject(String path) {
    final hit = _projectForFile(path);
    if (hit == null) {
      _snack('找不到文件所属项目');
      return;
    }
    setState(() => _revealedProjectFilePath = path);
    _expandProjectForFile(path);
    _openLeftTool(_LeftToolView.project);
    _snack('已展开 Project · ${hit.rel}');
  }

  void _selectOpenedFileInProject() {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) {
      _snack('没有打开的文件');
      return;
    }
    _revealFileInProject(_codeFiles[_activeFile].path);
  }

  void _revealBreadcrumbTarget(
    ({ProjectCfg project, String rel})? hit,
    String fallbackPath,
    int partIndex,
    List<String> parts,
  ) {
    if (hit == null) {
      _revealFileInProject(fallbackPath);
      return;
    }
    final target = partIndex < 0
        ? hit.project.path
        : '${hit.project.path}/${parts.take(partIndex + 1).join('/')}';
    _revealFileInProject(target);
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

  Future<void> _showRecentLocations() async {
    if (_recentLocations.isEmpty) {
      _snack('暂无最近位置');
      return;
    }
    final loc = await showDialog<_CodeLocation>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Recent Locations'),
        children: [
          for (final l in _recentLocations)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, l),
              child: Row(
                children: [
                  Icon(_iconForFile(l.path), size: 16, color: CcColors.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.line == null ? l.name : '${l.name}:${l.line}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CcType.code(size: 12.5),
                        ),
                        Text(
                          l.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CcType.code(
                            size: 10.5,
                            color: CcColors.subtle,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (loc != null) _openCodeFile(loc.path, line: loc.line);
  }

  Future<void> _showQuickOpen() async {
    final d = _defaultProject();
    if (d == null) {
      _snack('没有可搜索的项目');
      return;
    }
    final loc = await showDialog<_CodeLocation>(
      context: context,
      builder: (_) => _QuickOpenDialog(workspaces: _cfg.workspaces),
    );
    if (loc != null) _openCodeFile(loc.path, line: loc.line);
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

  Future<void> _setGitLogPathFilter() async {
    final p = _gitProject ?? _defaultProject()?.project;
    if (p == null) {
      _snack('没有可过滤的项目');
      return;
    }
    final ctl = TextEditingController(text: _logPathFilter);
    final active = _activeFile >= 0 && _activeFile < _codeFiles.length
        ? _projectForFile(_codeFiles[_activeFile].path)
        : null;
    final activeRel = active?.project.path == p.path ? active?.rel : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Filter Log by Path'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'File or directory path',
                hintText: 'app/lib/screens/workspace_page.dart',
              ),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
            if (activeRel != null && activeRel.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => ctl.text = activeRel,
                  icon: const Icon(Icons.my_location_rounded, size: 14),
                  label: Text('Use active file: $activeRel'),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (ok != true) {
      ctl.dispose();
      return;
    }
    final next = ctl.text.trim();
    ctl.dispose();
    setState(() => _logPathFilter = next);
    await _refreshGit();
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

  Future<void> _showGoToSymbol() async {
    final d = _defaultProject();
    if (d == null) {
      _snack('没有可搜索的项目');
      return;
    }
    final hit = await showDialog<_SymbolHit>(
      context: context,
      builder: (_) => _GoToSymbolDialog(workspaces: _cfg.workspaces),
    );
    if (hit != null) _openCodeFile(hit.path, line: hit.line);
  }

  Future<void> _showFindUsagesForActiveFile() async {
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
      _snack('当前文件没有可搜索的结构符号');
      return;
    }
    final hit = await showDialog<_SearchHit>(
      context: context,
      builder: (_) => _FindUsagesDialog(
        workspaces: _cfg.workspaces,
        sourcePath: file.path,
        symbols: symbols,
      ),
    );
    if (hit != null) _openCodeFile(hit.path, line: hit.line);
  }

  Future<void> _showShortcuts() async {
    final isMac = Platform.isMacOS;
    final mod = isMac ? 'Cmd' : 'Ctrl';
    final rows = [
      ('$mod+O', '快速打开文件'),
      ('$mod+F', '当前文件查找'),
      ('$mod+G', '跳转行号'),
      ('$mod+F12', '文件结构'),
      ('$mod+Alt+O', '跳转符号'),
      ('$mod+Alt+F7', '查找当前文件符号引用'),
      ('$mod+Alt+H', '打开当前文件 Git Log'),
      ('$mod+Alt+D', '打开当前文件工作区 Diff'),
      ('$mod+Alt+←/→', '代码导航后退/前进'),
      ('$mod+Shift+[/]', '切换编辑器 tab'),
      ('$mod+W', '关闭当前编辑器 tab'),
      ('$mod+Shift+1', '在 Project 中定位当前文件'),
      ('$mod+Shift+F', '全文搜索'),
      ('$mod+Shift+D', '当前文件对比 HEAD'),
      ('$mod+E', '最近文件'),
      ('$mod+Shift+E', '最近位置'),
      ('$mod+1', '切换 Project'),
      ('$mod+7', '打开 Structure'),
      ('$mod+K', '打开 Commit'),
      ('$mod+Shift+K', 'Push'),
      ('$mod+9', '打开 Commit'),
      ('$mod+Shift+9', '打开 Branches'),
      ('$mod+Alt+9', '打开 Git Log'),
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

  @override
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
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true, alt: true):
            _showGoToSymbol,
        const SingleActivator(
          LogicalKeyboardKey.keyO,
          control: true,
          alt: true,
        ): _showGoToSymbol,
        const SingleActivator(LogicalKeyboardKey.f7, meta: true, alt: true):
            _showFindUsagesForActiveFile,
        const SingleActivator(LogicalKeyboardKey.f7, control: true, alt: true):
            _showFindUsagesForActiveFile,
        const SingleActivator(LogicalKeyboardKey.keyH, meta: true, alt: true):
            _openActiveFileGitLog,
        const SingleActivator(
          LogicalKeyboardKey.keyH,
          control: true,
          alt: true,
        ): _openActiveFileGitLog,
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true, alt: true):
            _openActiveFileWorkingTreeDiff,
        const SingleActivator(
          LogicalKeyboardKey.keyD,
          control: true,
          alt: true,
        ): _openActiveFileWorkingTreeDiff,
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
        const SingleActivator(
          LogicalKeyboardKey.bracketLeft,
          meta: true,
          shift: true,
        ): _selectPreviousCodeTab,
        const SingleActivator(
          LogicalKeyboardKey.bracketLeft,
          control: true,
          shift: true,
        ): _selectPreviousCodeTab,
        const SingleActivator(
          LogicalKeyboardKey.bracketRight,
          meta: true,
          shift: true,
        ): _selectNextCodeTab,
        const SingleActivator(
          LogicalKeyboardKey.bracketRight,
          control: true,
          shift: true,
        ): _selectNextCodeTab,
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
            _closeActiveCodeFile,
        const SingleActivator(LogicalKeyboardKey.keyW, control: true):
            _closeActiveCodeFile,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true, shift: true):
            _showFindInFiles,
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
          shift: true,
        ): _showFindInFiles,
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true, shift: true):
            _compareActiveFileWithHead,
        const SingleActivator(
          LogicalKeyboardKey.keyD,
          control: true,
          shift: true,
        ): _compareActiveFileWithHead,
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true):
            _showRecentFiles,
        const SingleActivator(LogicalKeyboardKey.keyE, control: true):
            _showRecentFiles,
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true, shift: true):
            _showRecentLocations,
        const SingleActivator(
          LogicalKeyboardKey.keyE,
          control: true,
          shift: true,
        ): _showRecentLocations,
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true):
            _toggleProjectShortcut,
        const SingleActivator(LogicalKeyboardKey.digit1, control: true):
            _toggleProjectShortcut,
        const SingleActivator(
          LogicalKeyboardKey.digit1,
          meta: true,
          shift: true,
        ): _selectOpenedFileInProject,
        const SingleActivator(
          LogicalKeyboardKey.digit1,
          control: true,
          shift: true,
        ): _selectOpenedFileInProject,
        const SingleActivator(LogicalKeyboardKey.digit7, meta: true):
            _openStructureShortcut,
        const SingleActivator(LogicalKeyboardKey.digit7, control: true):
            _openStructureShortcut,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _openGitShortcut,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _openGitShortcut,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true, shift: true):
            _pushShortcut,
        const SingleActivator(
          LogicalKeyboardKey.keyK,
          control: true,
          shift: true,
        ): _pushShortcut,
        const SingleActivator(LogicalKeyboardKey.digit9, meta: true):
            _openGitShortcut,
        const SingleActivator(LogicalKeyboardKey.digit9, control: true):
            _openGitShortcut,
        const SingleActivator(
          LogicalKeyboardKey.digit9,
          meta: true,
          shift: true,
        ): _openBranchesShortcut,
        const SingleActivator(
          LogicalKeyboardKey.digit9,
          control: true,
          shift: true,
        ): _openBranchesShortcut,
        const SingleActivator(LogicalKeyboardKey.digit9, meta: true, alt: true):
            _openLogShortcut,
        const SingleActivator(
          LogicalKeyboardKey.digit9,
          control: true,
          alt: true,
        ): _openLogShortcut,
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

  void _toggleProjectShortcut() {
    if (!_projectCollapsed && _leftToolView == _LeftToolView.project) {
      _setProjectCollapsed(true);
    } else {
      _openLeftTool(_LeftToolView.project);
    }
  }

  void _openStructureShortcut() => _openLeftTool(_LeftToolView.structure);

  void _openGitShortcut() => _openLeftTool(_LeftToolView.changes);

  void _openBranchesShortcut() => _openLeftTool(_LeftToolView.branches);

  void _openLogShortcut() => _openLeftTool(_LeftToolView.log);

  void _pushShortcut() {
    final p = _gitProject ?? _defaultProject()?.project;
    if (p == null) {
      _snack('没有可 push 的项目');
      return;
    }
    _gitPushCurrent(p);
  }

  void _openTerminalShortcut() => _setBottomTool(_BottomTool.terminal);

  String _shortcutModLabel() => Platform.isMacOS ? 'Cmd' : 'Ctrl';

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
    _showBlameForProjectFile(hit.project, hit.rel);
  }

  void _showBlameForProjectFile(ProjectCfg project, String relPath) {
    if (relPath.trim().isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (_) => _BlameDialog(project: project, relPath: relPath),
    );
  }

  Future<void> _showFileHistoryForActiveFile() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) {
      _snack('没有打开的文件');
      return;
    }
    final file = _codeFiles[_activeFile].path;
    final hit = _projectForFile(file);
    if (hit == null || hit.rel.isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    _showFileHistoryForProjectFile(hit.project, hit.rel);
  }

  void _showFileHistoryForProjectFile(ProjectCfg project, String relPath) {
    if (relPath.trim().isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (_) => _FileHistoryDialog(project: project, relPath: relPath),
    );
  }

  Future<void> _openActiveFileGitLog() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) {
      _snack('没有打开的文件');
      return;
    }
    await _openFileGitLog(_codeFiles[_activeFile].path);
  }

  Future<void> _openFileGitLog(String path) async {
    final hit = _projectForFile(path);
    if (hit == null || hit.rel.isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    setState(() {
      _gitProject = hit.project;
      _gitView = _GitView.log;
      _bottomTool = _BottomTool.git;
      _terminalCollapsed = false;
      _logPathFilter = hit.rel;
      _compareTitle = null;
      _compareFiles = const [];
      _commitFiles = const [];
      _selectedCommit = null;
    });
    Prefs.setString('ws.bottomTool', 'git');
    Prefs.setBool('ws.terminalCollapsed', false);
    await _refreshGit();
  }

  Future<void> _openActiveFileWorkingTreeDiff() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) {
      _snack('没有打开的文件');
      return;
    }
    await _openFileWorkingTreeDiff(_codeFiles[_activeFile].path);
  }

  Future<void> _openFileWorkingTreeDiff(String path) async {
    final hit = _projectForFile(path);
    if (hit == null || hit.rel.isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    setState(() {
      _gitProject = hit.project;
      _gitView = _GitView.changes;
      _bottomTool = _BottomTool.git;
      _terminalCollapsed = false;
      _selectedGitPath = hit.rel;
      _selectedChangePaths
        ..clear()
        ..add(hit.rel);
    });
    Prefs.setString('ws.bottomTool', 'git');
    Prefs.setBool('ws.terminalCollapsed', false);
    await _refreshGit();
    if (!mounted) return;
    final hasDiff = _gitFiles.any((f) => f.path == hit.rel);
    final hasChange = _gitChanges.any(
      (c) => c.path == hit.rel || c.oldPath == hit.rel,
    );
    if (!hasDiff && !hasChange) {
      _snack('当前文件没有工作区改动');
    } else {
      setState(() => _selectedGitPath = hit.rel);
    }
  }

  Future<void> _compareActiveFileWithHead() async {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) {
      _snack('没有打开的文件');
      return;
    }
    final file = _codeFiles[_activeFile].path;
    final hit = _projectForFile(file);
    if (hit == null || hit.rel.isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    await _compareProjectFileWithHead(hit.project, hit.rel);
  }

  Future<void> _compareProjectFileWithHead(
    ProjectCfg project,
    String relPath,
  ) async {
    if (relPath.trim().isEmpty) {
      _snack('找不到文件所属项目');
      return;
    }
    try {
      final diff = await gitDiffFileWorking(project.path, relPath);
      final files = parseUnifiedDiff(diff);
      if (files.isEmpty) {
        _snack('当前文件没有相对 HEAD 的改动');
        return;
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          child: SizedBox(
            width: 1040,
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
                        Icons.compare_arrows_rounded,
                        size: 17,
                        color: CcColors.muted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Compare with HEAD · $relPath',
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
                Expanded(
                  child: DiffView(
                    files: files,
                    editRoot: project.path,
                    onChanged: _refreshGit,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      _snack(errorText(e));
    }
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
            onPressed: () => _openGitView(_GitView.changes),
          ),
          _vcsOperationsMenu(),
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
            icon: Icons.location_history_rounded,
            tooltip: '最近位置',
            selected: false,
            onPressed: _showRecentLocations,
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

  void _openLeftTool(_LeftToolView view) {
    setState(() {
      _leftToolView = view;
      final gitView = _gitViewForLeftTool(view);
      if (gitView != null) _gitView = gitView;
      _projectCollapsed = false;
    });
    Prefs.setString('ws.leftTool', _leftToolPref(view));
    Prefs.setBool('ws.projectCollapsed', false);
    if (_gitViewForLeftTool(view) != null) _refreshGit();
  }

  void _setDetailCollapsed(bool v) {
    setState(() => _detailCollapsed = v);
    Prefs.setBool('ws.detailCollapsed', v);
  }

  void _setTerminalCollapsed(bool v) {
    setState(() => _terminalCollapsed = v);
    Prefs.setBool('ws.terminalCollapsed', v);
  }

  @override
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

  PopupMenuButton<String> _vcsOperationsMenu() {
    final p = _gitProject ?? _defaultProject()?.project;
    final status = p == null ? null : _gitStatus;
    final dirtyTotal = status == null
        ? 0
        : status.staged +
              status.modified +
              status.untracked +
              status.conflicted;
    final canStageAll =
        status == null || status.modified > 0 || status.untracked > 0;
    final canUnstageAll = status == null || status.staged > 0;
    final canRollbackAll = status == null || dirtyTotal > 0;
    final mod = _shortcutModLabel();
    return PopupMenuButton<String>(
      tooltip: p == null ? 'VCS Operations · 没有项目' : 'VCS Operations',
      enabled: p != null,
      padding: EdgeInsets.zero,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.hub_rounded, size: 18),
          if (dirtyTotal > 0)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                constraints: const BoxConstraints(minWidth: 15),
                height: 15,
                padding: const EdgeInsets.symmetric(horizontal: 3),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: status?.conflicted == 0
                      ? CcColors.warning
                      : CcColors.danger,
                  borderRadius: BorderRadius.circular(CcRadius.pill),
                ),
                child: Text(
                  '$dirtyTotal',
                  style: CcType.code(
                    size: 8.5,
                    color: CcColors.bg,
                    weight: FontWeight.w800,
                  ),
                ),
              ),
            ),
        ],
      ),
      onOpened: () {
        if (p != null) _selectGitProject(p);
      },
      onSelected: (v) {
        if (p == null) return;
        _handleGitMenuAction(p, v);
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Row(
            children: [
              const Icon(
                Icons.account_tree_rounded,
                size: 16,
                color: CcColors.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status == null
                      ? p?.name ?? 'No Git project'
                      : '${status.branch} · ${status.clean ? 'clean' : '$dirtyTotal changes'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 12, color: CcColors.text),
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        _vcsMenuItem(
          value: 'changes',
          icon: Icons.list_alt_rounded,
          label: 'Open Changes',
          shortcut: '$mod+9',
        ),
        _vcsMenuItem(
          value: 'workingDiff',
          icon: Icons.difference_rounded,
          label: 'Show Working Tree Diff',
        ),
        _vcsMenuItem(
          value: 'commit',
          icon: Icons.check_circle_outline_rounded,
          label: 'Commit...',
          shortcut: '$mod+K',
        ),
        _vcsMenuItem(
          value: 'log',
          icon: Icons.history_rounded,
          label: 'Open Git Log',
          shortcut: '$mod+Alt+9',
        ),
        _vcsMenuItem(
          value: 'branches',
          icon: Icons.account_tree_rounded,
          label: 'Open Branches',
          shortcut: '$mod+Shift+9',
        ),
        _vcsMenuItem(
          value: 'stash',
          icon: Icons.inventory_2_outlined,
          label: 'Open Stash',
        ),
        const PopupMenuDivider(),
        _vcsMenuItem(
          value: 'branchPopup',
          icon: Icons.call_split_rounded,
          label: 'Branches Popup...',
        ),
        _vcsMenuItem(
          value: 'newBranch',
          icon: Icons.add_rounded,
          label: 'New Branch...',
        ),
        const PopupMenuDivider(),
        _vcsMenuItem(value: 'fetch', icon: Icons.sync_rounded, label: 'Fetch'),
        _vcsMenuItem(
          value: 'fetchPrune',
          icon: Icons.cleaning_services_outlined,
          label: 'Fetch --prune',
        ),
        _vcsMenuItem(
          value: 'pull',
          icon: Icons.call_received_rounded,
          label: 'Pull --ff-only',
        ),
        _vcsMenuItem(
          value: 'pullRebase',
          icon: Icons.vertical_align_top_rounded,
          label: 'Pull --rebase',
        ),
        _vcsMenuItem(
          value: 'push',
          icon: Icons.upload_rounded,
          label: 'Push',
          shortcut: '$mod+Shift+K',
        ),
        const PopupMenuDivider(),
        _vcsMenuItem(
          value: canStageAll ? 'stageAll' : null,
          icon: Icons.add_task_rounded,
          label: 'Stage All',
        ),
        _vcsMenuItem(
          value: canUnstageAll ? 'unstageAll' : null,
          icon: Icons.remove_done_rounded,
          label: 'Unstage All',
        ),
        _vcsMenuItem(
          value: 'stashPush',
          icon: Icons.archive_outlined,
          label: 'Stash Changes...',
        ),
        _vcsMenuItem(
          value: canRollbackAll ? 'rollbackAll' : null,
          icon: Icons.restore_rounded,
          label: 'Rollback All...',
          danger: true,
        ),
      ],
    );
  }

  PopupMenuItem<String> _vcsMenuItem({
    required String? value,
    required IconData icon,
    required String label,
    String? shortcut,
    bool danger = false,
  }) {
    final enabled = value != null;
    final color = !enabled
        ? CcColors.subtle
        : danger
        ? CcColors.danger
        : CcColors.muted;
    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: danger && enabled
                  ? const TextStyle(color: CcColors.danger)
                  : null,
            ),
          ),
          if (shortcut != null) ...[
            const SizedBox(width: 18),
            Text(
              shortcut,
              style: CcType.code(size: 11, color: CcColors.subtle),
            ),
          ],
        ],
      ),
    );
  }

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
                SizedBox(width: _treeWidth, child: _leftToolPanel()),
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
    final mod = _shortcutModLabel();
    final projectCount = _cfg.workspaces.fold<int>(
      0,
      (sum, ws) => sum + ws.projects.length,
    );
    final changeCount = _gitChanges.length;
    final branchCount = _gitBranches.length;
    final commitCount = _gitLog.length;
    final sessionCount = terms.length;
    final hasActiveFile = _activeFile >= 0 && _activeFile < _codeFiles.length;
    final gitPulse = _gitStatus == null
        ? null
        : _gitStatus!.clean
        ? 'clean'
        : '${_gitStatus!.staged + _gitStatus!.modified + _gitStatus!.untracked + _gitStatus!.conflicted}';
    return Container(
      width: 46,
      decoration: const BoxDecoration(
        color: CcColors.toolbar,
        border: Border(right: BorderSide(color: CcColors.border)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 6),
          Expanded(
            child: SingleChildScrollView(
              primary: false,
              child: Column(
                children: [
                  _leftToolButton(
                    icon: Icons.account_tree_outlined,
                    label: 'Project',
                    tooltip: 'Project · $mod+1',
                    selected:
                        !_projectCollapsed &&
                        _leftToolView == _LeftToolView.project,
                    badge: projectCount == 0 ? null : '$projectCount',
                    onTap: () {
                      if (!_projectCollapsed &&
                          _leftToolView == _LeftToolView.project) {
                        _setProjectCollapsed(true);
                      } else {
                        _openLeftTool(_LeftToolView.project);
                      }
                    },
                  ),
                  _leftToolButton(
                    icon: Icons.schema_rounded,
                    label: 'Structure',
                    tooltip: hasActiveFile
                        ? 'Structure · $mod+7'
                        : 'Structure · 打开文件后可用',
                    selected:
                        !_projectCollapsed &&
                        _leftToolView == _LeftToolView.structure,
                    enabled: hasActiveFile,
                    onTap: () {
                      if (!_projectCollapsed &&
                          _leftToolView == _LeftToolView.structure) {
                        _setProjectCollapsed(true);
                      } else {
                        _openLeftTool(_LeftToolView.structure);
                      }
                    },
                  ),
                  _leftToolSeparator('Git'),
                  _leftToolButton(
                    icon: Icons.alt_route_rounded,
                    label: 'Commit',
                    tooltip: 'Commit · $mod+K / $mod+9',
                    selected:
                        !_projectCollapsed &&
                        _leftToolView == _LeftToolView.changes,
                    badge: changeCount == 0 ? null : '$changeCount',
                    badgeColor: CcColors.warning,
                    onTap: () {
                      if (!_projectCollapsed &&
                          _leftToolView == _LeftToolView.changes) {
                        _setProjectCollapsed(true);
                      } else {
                        _openLeftTool(_LeftToolView.changes);
                      }
                    },
                  ),
                  _leftToolButton(
                    icon: Icons.account_tree_rounded,
                    label: 'Branches',
                    tooltip: 'Branches · $mod+Shift+9',
                    selected:
                        !_projectCollapsed &&
                        _leftToolView == _LeftToolView.branches,
                    badge: branchCount == 0 ? null : '$branchCount',
                    badgeColor: CcColors.accentBright,
                    onTap: () {
                      if (!_projectCollapsed &&
                          _leftToolView == _LeftToolView.branches) {
                        _setProjectCollapsed(true);
                      } else {
                        _openLeftTool(_LeftToolView.branches);
                      }
                    },
                  ),
                  _leftToolButton(
                    icon: Icons.history_rounded,
                    label: 'Log',
                    tooltip: 'Git Log · $mod+Alt+9',
                    selected:
                        !_projectCollapsed &&
                        _leftToolView == _LeftToolView.log,
                    badge: commitCount == 0 ? null : '$commitCount',
                    badgeColor: CcColors.ok,
                    onTap: () {
                      if (!_projectCollapsed &&
                          _leftToolView == _LeftToolView.log) {
                        _setProjectCollapsed(true);
                      } else {
                        _openLeftTool(_LeftToolView.log);
                      }
                    },
                  ),
                  _leftToolButton(
                    icon: Icons.inventory_2_outlined,
                    label: 'Stash',
                    tooltip: 'Stash',
                    selected:
                        !_projectCollapsed &&
                        _leftToolView == _LeftToolView.stash,
                    badge: _gitStashes.isEmpty ? null : '${_gitStashes.length}',
                    badgeColor: CcColors.accentBright,
                    onTap: () {
                      if (!_projectCollapsed &&
                          _leftToolView == _LeftToolView.stash) {
                        _setProjectCollapsed(true);
                      } else {
                        _openLeftTool(_LeftToolView.stash);
                      }
                    },
                  ),
                  _leftToolSeparator('Run'),
                  _leftToolButton(
                    icon: Icons.terminal_rounded,
                    label: 'Terminal',
                    tooltip:
                        'Terminal · ${Platform.isMacOS ? 'Option' : 'Alt'}+F12',
                    selected:
                        !_terminalCollapsed &&
                        _bottomTool == _BottomTool.terminal,
                    badge: sessionCount == 0 ? null : '$sessionCount',
                    badgeColor: CcColors.ok,
                    onTap: () => _setBottomTool(_BottomTool.terminal),
                  ),
                  _leftToolButton(
                    icon: Icons.description_outlined,
                    label: 'Handoff',
                    tooltip: _detailItem == null
                        ? 'Handoff · 选择任务后可用'
                        : 'Handoff',
                    selected: _detailItem != null && !_detailCollapsed,
                    enabled: _detailItem != null,
                    badge: _detailItem == null ? null : '1',
                    badgeColor: CcColors.accentBright,
                    onTap: () => _setDetailCollapsed(!_detailCollapsed),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 13, indent: 8, endIndent: 8),
          _leftActionButton(
            icon: Icons.file_open_outlined,
            label: 'Quick Open · $mod+O',
            onTap: _showQuickOpen,
          ),
          _leftActionButton(
            icon: Icons.manage_search_rounded,
            label: 'Search · $mod+Shift+F',
            onTap: _showFindInFiles,
          ),
          _leftActionButton(
            icon: Icons.data_object_rounded,
            label: 'Symbols · $mod+Alt+O',
            onTap: _showGoToSymbol,
          ),
          _leftActionButton(
            icon: Icons.history_rounded,
            label: 'Recent Files · $mod+E',
            onTap: _showRecentFiles,
          ),
          _leftActionButton(
            icon: Icons.location_history_rounded,
            label: 'Recent Locations · $mod+Shift+E',
            onTap: _showRecentLocations,
          ),
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
          if (gitPulse != null)
            Padding(
              padding: const EdgeInsets.only(top: 3, bottom: 2),
              child: Tooltip(
                message: _gitStatus!.clean
                    ? '${_gitStatus!.branch} · clean'
                    : '${_gitStatus!.branch} · working tree changes',
                child: Container(
                  constraints: const BoxConstraints(minWidth: 26),
                  height: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: (_gitStatus!.clean ? CcColors.ok : CcColors.warning)
                        .withValues(alpha: 0.12),
                    border: Border.all(
                      color:
                          (_gitStatus!.clean ? CcColors.ok : CcColors.warning)
                              .withValues(alpha: 0.45),
                    ),
                    borderRadius: BorderRadius.circular(CcRadius.pill),
                  ),
                  child: Text(
                    gitPulse,
                    style: CcType.code(
                      size: 9.5,
                      color: _gitStatus!.clean ? CcColors.ok : CcColors.warning,
                      weight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _leftToolSeparator(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(7, 8, 7, 5),
    child: Row(
      children: [
        const Expanded(child: Divider(height: 1, color: CcColors.borderSoft)),
        const SizedBox(width: 4),
        Text(
          label,
          style: CcType.code(
            size: 8.5,
            color: CcColors.subtle,
            weight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );

  Widget _leftToolButton({
    required IconData icon,
    required String label,
    required String tooltip,
    required bool selected,
    required VoidCallback onTap,
    bool enabled = true,
    String? badge,
    Color badgeColor = CcColors.accentBright,
  }) => Tooltip(
    message: tooltip,
    preferBelow: false,
    child: InkWell(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 46,
        height: 70,
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
                      size: 14,
                      color: !enabled
                          ? CcColors.subtle.withValues(alpha: 0.55)
                          : selected
                          ? CcColors.accentBright
                          : CcColors.muted,
                    ),
                    const SizedBox(width: 6),
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
                        fontSize: 10.4,
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
                right: 3,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 16),
                  height: 16,
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
        width: 46,
        height: 32,
        child: Icon(
          icon,
          size: 17,
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
    final change = _fileGitChange(file.path);
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
            _breadcrumbPart(
              label: hit.project.name,
              selected: parts.isEmpty,
              accent: true,
              onTap: () => _revealBreadcrumbTarget(hit, file.path, -1, parts),
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
                    _breadcrumbPart(
                      label: parts[i],
                      selected: i == parts.length - 1,
                      onTap: () =>
                          _revealBreadcrumbTarget(hit, file.path, i, parts),
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
          if (change != null) ...[
            tag(_gitChangeLongLabel(change), _changeColor(change), bold: true),
            const SizedBox(width: 6),
          ],
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

  Widget _breadcrumbPart({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    bool accent = false,
  }) {
    final color = accent
        ? CcColors.accentBright
        : selected
        ? CcColors.text
        : CcColors.muted;
    return Tooltip(
      message: 'Reveal $label in Project',
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CcType.code(
              size: 11.5,
              color: color,
              weight: selected || accent ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
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
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _codeFiles.length,
              itemBuilder: (_, i) {
                final file = _codeFiles[i];
                return _editorTab(
                  icon: _iconForFile(file.path),
                  label: '${file.dirty ? '● ' : ''}${file.name}',
                  active: i == _activeFile,
                  change: _fileGitChange(file.path),
                  onTap: () => _activateCodeTab(i),
                  onClose: () => _closeCodeFile(i),
                  tabMenu: _editorFileTabMenu(i),
                );
              },
            ),
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
            _activeFileActionsMenu(_codeFiles[_activeFile]),
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
    GitChange? change,
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
          if (change != null) ...[
            Tooltip(
              message: _gitChangeLongLabel(change),
              child: Container(
                constraints: const BoxConstraints(minWidth: 16),
                height: 16,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _changeColor(change).withValues(alpha: 0.14),
                  border: Border.all(
                    color: _changeColor(change).withValues(alpha: 0.45),
                  ),
                  borderRadius: BorderRadius.circular(CcRadius.pill),
                ),
                child: Text(
                  _gitChangeShortLabel(change),
                  style: CcType.code(
                    size: 9.5,
                    color: _changeColor(change),
                    weight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
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

  PopupMenuButton<String> _activeFileActionsMenu(_OpenFile file) {
    final mod = _shortcutModLabel();
    return PopupMenuButton<String>(
      tooltip: 'Code Actions',
      icon: const Icon(Icons.bolt_rounded, size: 17),
      padding: EdgeInsets.zero,
      onSelected: (v) {
        if (v == 'structure') _showFileStructure();
        if (v == 'find') _showFindInCurrentFile();
        if (v == 'usages') _showFindUsagesForActiveFile();
        if (v == 'reveal') _revealFileInProject(file.path);
        if (v == 'copyPath') _copyFilePath(file.path);
        if (v == 'workingDiff') _openActiveFileWorkingTreeDiff();
        if (v == 'compareHead') _compareActiveFileWithHead();
        if (v == 'fileLog') _openActiveFileGitLog();
        if (v == 'history') _showFileHistoryForActiveFile();
        if (v == 'annotate') _showBlameForActiveFile();
        if (v == 'save') _saveActiveFile();
        if (v == 'close') _closeActiveCodeFile();
        if (v == 'closeOthers') _closeOtherCodeFiles(_activeFile);
        if (v == 'closeUnmodified') _closeUnmodifiedCodeFiles();
      },
      itemBuilder: (_) => [
        _codeActionMenuItem(
          value: 'structure',
          icon: Icons.account_tree_rounded,
          label: 'File Structure',
          shortcut: '$mod+F12',
        ),
        _codeActionMenuItem(
          value: 'find',
          icon: Icons.search_rounded,
          label: 'Find in File',
          shortcut: '$mod+F',
        ),
        _codeActionMenuItem(
          value: 'usages',
          icon: Icons.travel_explore_rounded,
          label: 'Find Usages',
          shortcut: '$mod+Alt+F7',
        ),
        const PopupMenuDivider(),
        _codeActionMenuItem(
          value: 'workingDiff',
          icon: Icons.difference_rounded,
          label: 'Working Tree Diff',
          shortcut: '$mod+Alt+D',
        ),
        _codeActionMenuItem(
          value: 'compareHead',
          icon: Icons.compare_arrows_rounded,
          label: 'Compare with HEAD',
          shortcut: '$mod+Shift+D',
        ),
        _codeActionMenuItem(
          value: 'fileLog',
          icon: Icons.manage_history_rounded,
          label: 'Open File Git Log',
          shortcut: '$mod+Alt+H',
        ),
        _codeActionMenuItem(
          value: 'history',
          icon: Icons.history_rounded,
          label: 'File History',
        ),
        _codeActionMenuItem(
          value: 'annotate',
          icon: Icons.person_search_rounded,
          label: 'Annotate / Blame',
        ),
        const PopupMenuDivider(),
        _codeActionMenuItem(
          value: 'reveal',
          icon: Icons.my_location_rounded,
          label: 'Reveal in Project',
          shortcut: '$mod+Shift+1',
        ),
        _codeActionMenuItem(
          value: 'copyPath',
          icon: Icons.copy_rounded,
          label: 'Copy Path',
        ),
        _codeActionMenuItem(
          value: 'save',
          icon: Icons.save_rounded,
          label: 'Save',
          shortcut: '$mod+S',
          enabled: file.dirty,
        ),
        const PopupMenuDivider(),
        _codeActionMenuItem(
          value: 'close',
          icon: Icons.close_rounded,
          label: 'Close',
          shortcut: '$mod+W',
        ),
        _codeActionMenuItem(
          value: 'closeOthers',
          icon: Icons.filter_none_rounded,
          label: 'Close Others',
          enabled: _codeFiles.length > 1,
        ),
        _codeActionMenuItem(
          value: 'closeUnmodified',
          icon: Icons.rule_rounded,
          label: 'Close Unmodified',
        ),
      ],
    );
  }

  PopupMenuItem<String> _codeActionMenuItem({
    required String value,
    required IconData icon,
    required String label,
    String? shortcut,
    bool enabled = true,
  }) => PopupMenuItem<String>(
    value: value,
    enabled: enabled,
    child: Row(
      children: [
        Icon(icon, size: 16, color: enabled ? CcColors.muted : CcColors.subtle),
        const SizedBox(width: 10),
        Expanded(child: Text(label)),
        if (shortcut != null) ...[
          const SizedBox(width: 18),
          Text(shortcut, style: CcType.code(size: 11, color: CcColors.subtle)),
        ],
      ],
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
        if (v == 'workingDiff') _openFileWorkingTreeDiff(file.path);
        if (v == 'fileLog') _openFileGitLog(file.path);
        if (v == 'history') {
          final hit = _projectForFile(file.path);
          if (hit == null || hit.rel.isEmpty) {
            _snack('找不到文件所属项目');
          } else {
            _showFileHistoryForProjectFile(hit.project, hit.rel);
          }
        }
        if (v == 'annotate') {
          final hit = _projectForFile(file.path);
          if (hit == null || hit.rel.isEmpty) {
            _snack('找不到文件所属项目');
          } else {
            _showBlameForProjectFile(hit.project, hit.rel);
          }
        }
        if (v == 'close') _closeCodeFile(index);
        if (v == 'closeOthers') _closeOtherCodeFiles(index);
        if (v == 'closeRight') _closeCodeFilesToRight(index);
        if (v == 'closeUnmodified') _closeUnmodifiedCodeFiles();
        if (v == 'closeAll') _closeAllCodeFiles();
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'copyPath', child: Text('Copy Path')),
        const PopupMenuItem(value: 'reveal', child: Text('Reveal in Project')),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'workingDiff',
          child: Text('Open File Working Tree Diff'),
        ),
        const PopupMenuItem(value: 'fileLog', child: Text('Open File Git Log')),
        const PopupMenuItem(value: 'history', child: Text('File History')),
        const PopupMenuItem(value: 'annotate', child: Text('Annotate / Blame')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'close', child: Text('Close')),
        const PopupMenuItem(value: 'closeOthers', child: Text('Close Others')),
        if (index < _codeFiles.length - 1)
          const PopupMenuItem(
            value: 'closeRight',
            child: Text('Close Tabs to the Right'),
          ),
        const PopupMenuItem(
          value: 'closeUnmodified',
          child: Text('Close Unmodified'),
        ),
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
                      () => _openLeftTool(_LeftToolView.project),
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

  Widget _bottomStripe() {
    final p = _gitProject ?? _defaultProject()?.project;
    final status = _gitStatus;
    return Container(
      height: 28,
      decoration: const BoxDecoration(
        color: CcColors.panel,
        border: Border(top: BorderSide(color: CcColors.border)),
      ),
      child: Row(
        children: [
          _statusBarToolSegment(
            icon: _bottomTool == _BottomTool.git
                ? Icons.alt_route_rounded
                : Icons.terminal_rounded,
            label: _bottomTool == _BottomTool.git ? 'Git' : 'Terminal',
            detail: _bottomTool == _BottomTool.git
                ? (status?.branch ?? p?.name ?? '')
                : '${terms.length}',
            selected: true,
            onTap: () => _setBottomTool(_bottomTool),
          ),
          const VerticalDivider(width: 1),
          _statusBarToolSegment(
            icon: Icons.terminal_rounded,
            label: 'Terminal',
            detail: '${terms.length}',
            selected:
                !_terminalCollapsed && _bottomTool == _BottomTool.terminal,
            onTap: () => _setBottomTool(_BottomTool.terminal),
          ),
          _statusBarToolSegment(
            icon: Icons.alt_route_rounded,
            label: 'Commit',
            detail: status == null ? '' : _gitDirtyLabel(status),
            selected: !_terminalCollapsed && _bottomTool == _BottomTool.git,
            color: status == null || status.clean
                ? CcColors.muted
                : CcColors.warning,
            onTap: () => _openGitView(_GitView.changes),
          ),
          const Spacer(),
          if (p != null) ...[
            _statusGitBranchSegment(status, p),
            _statusSyncSegment(status, p),
            _statusIconAction(
              icon: Icons.sync_rounded,
              tooltip: 'Fetch',
              onTap: _gitLoading ? null : () => _gitFetchCurrent(p),
            ),
            _statusIconAction(
              icon: Icons.call_received_rounded,
              tooltip: 'Pull --ff-only',
              onTap: _gitLoading ? null : () => _gitPullCurrent(p),
            ),
            _statusIconAction(
              icon: Icons.upload_rounded,
              tooltip: 'Push',
              onTap: _gitLoading ? null : () => _gitPushCurrent(p),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusBarToolSegment({
    required IconData icon,
    required String label,
    required String detail,
    required bool selected,
    required VoidCallback onTap,
    Color? color,
  }) => InkWell(
    onTap: onTap,
    child: Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: selected ? CcColors.editorTabBar : Colors.transparent,
        border: const Border(right: BorderSide(color: CcColors.border)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color ?? CcColors.muted),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: selected ? CcColors.text : CcColors.muted,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(width: 7),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.code(size: 10.8, color: CcColors.subtle),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _statusGitBranchSegment(GitStatusSummary? status, ProjectCfg p) {
    final branch = status?.branch ?? p.name;
    return InkWell(
      onTap: _gitLoading ? null : () => _showBranchDialog(),
      onSecondaryTap: () => _openGitView(_GitView.branches),
      child: Tooltip(
        message: 'Branches Popup · secondary click opens Branches tool window',
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: CcColors.border)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.account_tree_rounded,
                size: 14,
                color: CcColors.accentBright,
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  branch,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(
                    size: 11.2,
                    color: CcColors.text,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 3),
              const Icon(Icons.arrow_drop_down_rounded, size: 15),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusSyncSegment(GitStatusSummary? status, ProjectCfg p) {
    if (status == null) return const SizedBox.shrink();
    final dirty = status.staged + status.modified + status.untracked;
    final hasSync = status.ahead > 0 || status.behind > 0;
    final hasConflicts = status.conflicted > 0;
    if (dirty == 0 && !hasSync && !hasConflicts) {
      return _statusTextAction(
        icon: Icons.check_circle_rounded,
        label: 'clean',
        color: CcColors.ok,
        tooltip: 'Working tree clean · Open Git Log',
        onTap: () => _openGitView(_GitView.log),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dirty > 0 || hasConflicts)
          _statusTextAction(
            icon: hasConflicts
                ? Icons.report_problem_rounded
                : Icons.edit_note_rounded,
            label: hasConflicts
                ? '${status.conflicted} conflicts'
                : '$dirty changes',
            color: hasConflicts ? CcColors.danger : CcColors.warning,
            tooltip: 'Open Commit changes',
            onTap: () => _openGitView(_GitView.changes),
          ),
        if (status.ahead > 0)
          _statusTextAction(
            icon: Icons.north_rounded,
            label: '${status.ahead}',
            color: CcColors.warning,
            tooltip: 'Push ${status.ahead} outgoing commit(s)',
            onTap: _gitLoading ? null : () => _gitPushCurrent(p),
          ),
        if (status.behind > 0)
          _statusTextAction(
            icon: Icons.south_rounded,
            label: '${status.behind}',
            color: CcColors.accentBright,
            tooltip: 'Pull ${status.behind} incoming commit(s)',
            onTap: _gitLoading ? null : () => _gitPullCurrent(p),
          ),
      ],
    );
  }

  Widget _statusTextAction({
    required IconData icon,
    required String label,
    required Color color,
    required String tooltip,
    required VoidCallback? onTap,
  }) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: CcType.code(
                size: 10.8,
                color: color,
                weight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _statusIconAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
  }) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Icon(
          icon,
          size: 14,
          color: onTap == null ? CcColors.subtle : CcColors.muted,
        ),
      ),
    ),
  );

  String _gitDirtyLabel(GitStatusSummary status) {
    if (status.clean) return 'clean';
    final total =
        status.staged + status.modified + status.untracked + status.conflicted;
    return '$total changes';
  }

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

  void _setBottomTool(_BottomTool tool, {_GitView? gitView}) {
    setState(() {
      _bottomTool = tool;
      if (gitView != null) _gitView = gitView;
      _terminalCollapsed = false;
    });
    Prefs.setString(
      'ws.bottomTool',
      tool == _BottomTool.git ? 'git' : 'terminal',
    );
    Prefs.setBool('ws.terminalCollapsed', false);
    if (tool == _BottomTool.git) _refreshGit();
  }

  void _openGitView(_GitView view) =>
      _setBottomTool(_BottomTool.git, gitView: view);

  void _openCommitFlow(ProjectCfg project) {
    _selectGitProject(project);
    _openLeftTool(_LeftToolView.changes);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _commitFocus.requestFocus();
    });
  }

  Future<void> _showWorkingTreeDiff(ProjectCfg project) async {
    _selectGitProject(project);
    _openGitView(_GitView.changes);
    await _refreshGit();
    if (!mounted) return;
    if (_gitFiles.isEmpty && _gitChanges.isEmpty) {
      _snack('Working tree clean');
      return;
    }
    setState(() => _selectedGitPath = _workingTreeDiffSelection);
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

  @override
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

  Future<void> _compareCommitWithWorking(ProjectCfg p, GitCommit c) async {
    setState(() {
      _gitView = _GitView.log;
      _bottomTool = _BottomTool.git;
      _terminalCollapsed = false;
      _selectedCommit = c.hash;
      _compareTitle = '${c.shortHash}..Working Tree';
      _gitLoading = true;
    });
    try {
      final diff = await gitDiffRefToWorking(p.path, c.hash);
      if (!mounted) return;
      setState(() {
        _compareFiles = parseUnifiedDiff(diff);
        _commitFiles = const [];
        _gitLoading = false;
      });
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
              icon: const Icon(Icons.vertical_align_top_rounded, size: 17),
              tooltip: 'Pull --rebase',
              visualDensity: VisualDensity.compact,
              onPressed: p == null ? null : () => _gitPullRebaseCurrent(p),
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

  Widget _gitToolBody(ProjectCfg p, {bool compact = false}) {
    if (_gitView == _GitView.stash) {
      return compact ? _compactStashView(p) : _stashView(p);
    }
    if (_gitView == _GitView.branches) return _branchesView(p, compact);
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
      if (compact) return _compactGitLogView(p);
      return _gitLogView(p);
    }
    if (compact) {
      return _gitFiles.isEmpty && _gitChanges.isEmpty
          ? centerMsg('Working tree clean')
          : _localChangesList(p);
    }
    return _gitFiles.isEmpty && _gitChanges.isEmpty
        ? centerMsg('Working tree clean')
        : _localChangesView(p);
  }

  Widget _branchesView(ProjectCfg p, bool compact) => _BranchListPane(
    project: p,
    branches: _gitBranches,
    loading: _gitLoading,
    error: _gitError,
    embedded: compact,
    onRefresh: _refreshGit,
    onCheckout: (branch) => _checkoutBranchCurrent(p, branch),
    onCreate: (branch, start) => _createBranchCurrent(p, branch, start: start),
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
    onDeleteRemote: (branch) async => _deleteRemoteBranchCurrent(p, branch),
    onPushBranch: (branch, {publish = false}) =>
        _pushBranchCurrent(p, branch, publish: publish),
    onCompare: (branch) async => _compareBranch(p, branch),
    onMerge: (branch) async => _mergeBranchIntoCurrent(p, branch),
    onRebase: (branch) async => _rebaseCurrentOntoBranch(p, branch),
    onFetch: ({prune = false}) => _gitFetchCurrent(p, prune: prune),
    onPull: () => _gitPullCurrent(p),
    onPush: () => _gitPushCurrent(p),
  );

  Widget _localChangesView(ProjectCfg p) {
    final showingWorkingTree = _selectedGitPath == _workingTreeDiffSelection;
    final selected = _selectedGitPath == null || showingWorkingTree
        ? const <FileDiff>[]
        : _gitFiles.where((f) => f.path == _selectedGitPath).toList();
    final selectedChange = _selectedGitPath == null || showingWorkingTree
        ? null
        : _gitChanges.where((c) => c.path == _selectedGitPath).firstOrNull;
    return Row(
      children: [
        SizedBox(width: 320, child: _localChangesList(p)),
        const VerticalDivider(width: 1),
        Expanded(
          child: showingWorkingTree
              ? _workingTreeDiffPanel(p)
              : selected.isEmpty
              ? centerMsg('选择一个变更文件')
              : _selectedChangeDiffPanel(p, selected, selectedChange),
        ),
      ],
    );
  }

  Widget _workingTreeDiffPanel(ProjectCfg p) {
    if (_gitFiles.isEmpty) return centerMsg('Working tree clean');
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
              const Icon(
                Icons.difference_rounded,
                size: 16,
                color: CcColors.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Working Tree · ${_gitFiles.length} files',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 12, color: CcColors.muted),
                ),
              ),
              TextButton.icon(
                onPressed: _gitLoading ? null : () => _gitStageAllCurrent(p),
                icon: const Icon(Icons.add_task_rounded, size: 14),
                label: const Text('Stage All'),
              ),
              TextButton.icon(
                onPressed: _gitLoading ? null : () => _gitDiscardAllCurrent(p),
                icon: const Icon(Icons.undo_rounded, size: 14),
                label: const Text('Rollback All'),
                style: TextButton.styleFrom(foregroundColor: CcColors.danger),
              ),
            ],
          ),
        ),
        Expanded(
          child: DiffView(
            files: _gitFiles,
            editRoot: p.path,
            onChanged: _refreshGit,
          ),
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
    final tracked = change?.untracked != true;
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
              if (tracked) ...[
                IconButton(
                  icon: const Icon(Icons.history_rounded, size: 16),
                  tooltip: 'File History',
                  visualDensity: VisualDensity.compact,
                  onPressed: _gitLoading
                      ? null
                      : () => _showFileHistoryForProjectFile(p, file),
                ),
                IconButton(
                  icon: const Icon(Icons.person_search_rounded, size: 16),
                  tooltip: 'Annotate / Blame',
                  visualDensity: VisualDensity.compact,
                  onPressed: _gitLoading
                      ? null
                      : () => _showBlameForProjectFile(p, file),
                ),
              ],
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
    final visibleChanges = _filteredGitChanges;
    final stageableSelected = _gitChanges
        .where((c) => _selectedChangePaths.contains(c.path) && c.unstaged)
        .length;
    final unstageableSelected = _gitChanges
        .where((c) => _selectedChangePaths.contains(c.path) && c.staged)
        .length;
    final rollbackableSelected = _gitChanges
        .where((c) => _selectedChangePaths.contains(c.path) && !c.conflicted)
        .length;
    final stashableSelected = rollbackableSelected;
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
                  onPressed: _gitLoading || stashableSelected == 0
                      ? null
                      : () => _stashSelectedCurrent(p),
                  child: const Text('Stash'),
                ),
                TextButton(
                  onPressed: _gitLoading || rollbackableSelected == 0
                      ? null
                      : () => _gitDiscardSelectedCurrent(p),
                  style: TextButton.styleFrom(foregroundColor: CcColors.danger),
                  child: const Text('Rollback'),
                ),
                TextButton(
                  onPressed: visibleChanges.isEmpty
                      ? null
                      : () => setState(() {
                          _selectedChangePaths
                            ..clear()
                            ..addAll(visibleChanges.map((c) => c.path));
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
                  visibleChanges.length == _gitChanges.length
                      ? '${_gitChanges.length}'
                      : '${visibleChanges.length}/${_gitChanges.length}',
                  style: CcType.code(size: 11, color: CcColors.subtle),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
            child: TextField(
              controller: _changesQueryCtl,
              decoration: InputDecoration(
                hintText: 'Filter changes',
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 17),
                suffixIcon: _changesQuery.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 16),
                        tooltip: '清空过滤',
                        onPressed: () => setState(() {
                          _changesQueryCtl.clear();
                          _changesQuery = '';
                        }),
                      ),
              ),
              onChanged: (v) => setState(() => _changesQuery = v),
            ),
          ),
          SizedBox(
            height: 34,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  _changeFilterChip(
                    _ChangeFilter.all,
                    'All',
                    _gitChanges.length,
                  ),
                  _changeFilterChip(
                    _ChangeFilter.staged,
                    'Staged',
                    _gitChanges.where((c) => c.staged && !c.conflicted).length,
                  ),
                  _changeFilterChip(
                    _ChangeFilter.unstaged,
                    'Unstaged',
                    _gitChanges
                        .where(
                          (c) => c.unstaged && !c.untracked && !c.conflicted,
                        )
                        .length,
                  ),
                  _changeFilterChip(
                    _ChangeFilter.untracked,
                    'Untracked',
                    _gitChanges.where((c) => c.untracked).length,
                  ),
                  _changeFilterChip(
                    _ChangeFilter.conflicts,
                    'Conflicts',
                    _gitChanges.where((c) => c.conflicted).length,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: visibleChanges.isEmpty
                ? centerMsg(_gitChanges.isEmpty ? '没有变更' : '没有匹配变更')
                : ListView(children: _changeGroups(p, visibleChanges)),
          ),
        ],
      ),
    );
  }

  Widget _changeFilterChip(_ChangeFilter filter, String label, int count) {
    final selected = _changesFilter == filter;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        selected: selected,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        label: Text('$label $count'),
        onSelected: (_) => setState(() => _changesFilter = filter),
      ),
    );
  }

  List<GitChange> get _filteredGitChanges {
    final q = _changesQuery.trim().toLowerCase();
    return _gitChanges.where((c) {
      final matchesKind = switch (_changesFilter) {
        _ChangeFilter.all => true,
        _ChangeFilter.staged => c.staged && !c.conflicted,
        _ChangeFilter.unstaged => c.unstaged && !c.untracked && !c.conflicted,
        _ChangeFilter.untracked => c.untracked,
        _ChangeFilter.conflicts => c.conflicted,
      };
      if (!matchesKind) return false;
      if (q.isEmpty) return true;
      return c.path.toLowerCase().contains(q) ||
          (c.oldPath ?? '').toLowerCase().contains(q) ||
          c.status.toLowerCase().contains(q) ||
          (c.staged ? 'staged' : '').contains(q) ||
          (c.unstaged ? 'unstaged modified' : '').contains(q) ||
          (c.untracked ? 'untracked new' : '').contains(q) ||
          (c.conflicted ? 'conflict conflicted' : '').contains(q);
    }).toList();
  }

  List<Widget> _changeGroups(ProjectCfg p, List<GitChange> changes) {
    final conflicts = changes.where((c) => c.conflicted).toList();
    final staged = changes.where((c) => c.staged && !c.conflicted).toList();
    final untracked = changes.where((c) => c.untracked).toList();
    final unstaged = changes
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
              if (v == 'compare') _compareProjectFileWithHead(p, c.path);
              if (v == 'history') _showFileHistoryForProjectFile(p, c.path);
              if (v == 'annotate') _showBlameForProjectFile(p, c.path);
              if (v == 'discard') _gitDiscardFileCurrent(p, c.path);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'open', child: Text('Open')),
              if (!c.untracked) ...[
                const PopupMenuItem(
                  value: 'compare',
                  child: Text('Compare with HEAD'),
                ),
                const PopupMenuItem(
                  value: 'history',
                  child: Text('File History'),
                ),
                const PopupMenuItem(
                  value: 'annotate',
                  child: Text('Annotate / Blame'),
                ),
              ],
              const PopupMenuDivider(),
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

  GitChange? _fileGitChange(String path) {
    final hit = _projectForFile(path);
    if (hit == null || hit.rel.isEmpty) return null;
    return _gitChanges
        .where((c) => c.path == hit.rel || c.oldPath == hit.rel)
        .firstOrNull;
  }

  String _gitChangeShortLabel(GitChange c) {
    if (c.conflicted) return '!';
    if (c.untracked) return 'A';
    if (c.staged) return 'S';
    return 'M';
  }

  String _gitChangeLongLabel(GitChange c) {
    if (c.conflicted) return 'conflict ${c.status}';
    if (c.untracked) return 'untracked';
    if (c.staged && c.unstaged) return 'staged + modified';
    if (c.staged) return 'staged ${c.status}';
    return 'modified ${c.status}';
  }

  List<GitCommit> get _filteredGitLog {
    final q = _logQuery.trim().toLowerCase();
    final authors = _gitLog.map((c) => c.author).toSet();
    final effectiveAuthor = authors.contains(_logAuthorFilter)
        ? _logAuthorFilter
        : '';
    return _gitLog.where((c) {
      final matchesQuery =
          q.isEmpty ||
          c.subject.toLowerCase().contains(q) ||
          c.author.toLowerCase().contains(q) ||
          c.hash.toLowerCase().contains(q) ||
          c.shortHash.toLowerCase().contains(q) ||
          c.refs.toLowerCase().contains(q);
      final matchesAuthor =
          effectiveAuthor.isEmpty || c.author == effectiveAuthor;
      return matchesQuery && matchesAuthor;
    }).toList();
  }

  Widget _compactGitLogView(ProjectCfg p) {
    if (_gitLog.isEmpty) return centerMsg('没有 commit');
    final commits = _filteredGitLog;
    return DecoratedBox(
      decoration: const BoxDecoration(color: CcColors.panel),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 7, 8, 6),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Filter log',
                isDense: true,
                prefixIcon: Icon(Icons.search_rounded, size: 17),
              ),
              onChanged: (v) => setState(() => _logQuery = v),
            ),
          ),
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _logPathFilter.isEmpty
                        ? '${commits.length}/${_gitLog.length} commits'
                        : '$_logPathFilter · ${commits.length}/${_gitLog.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CcType.code(size: 10.8, color: CcColors.subtle),
                  ),
                ),
                Tooltip(
                  message: _gitLogAllBranches
                      ? 'Showing all branches'
                      : 'Showing current branch',
                  child: FilterChip(
                    selected: _gitLogAllBranches,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    label: const Text('All'),
                    onSelected: (v) {
                      setState(() {
                        _gitLogAllBranches = v;
                        if (v) _gitLogRefFilter = '';
                      });
                      Prefs.setBool('ws.gitLogAllBranches', v);
                      _refreshGit();
                    },
                  ),
                ),
              ],
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
                          c.hash == _selectedCommit && _compareTitle == null;
                      final age = c.date.millisecondsSinceEpoch == 0
                          ? ''
                          : relativeTime(c.date);
                      return Material(
                        color: sel
                            ? CcColors.accent.withValues(alpha: 0.10)
                            : Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            _selectCommit(p, c);
                            _openGitView(_GitView.log);
                          },
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.commit_rounded,
                                  size: 16,
                                  color: sel
                                      ? CcColors.accentBright
                                      : CcColors.muted,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        c.subject,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: sel
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${c.shortHash} · ${c.author}${age.isEmpty ? '' : ' · $age'}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: CcType.code(
                                          size: 10.8,
                                          color: CcColors.subtle,
                                        ),
                                      ),
                                      if (c.refs.isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        tag(c.refs, CcColors.accentBright),
                                      ],
                                    ],
                                  ),
                                ),
                                _commitActionsMenu(p, c, compact: true),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _gitLogView(ProjectCfg p) {
    if (_gitLog.isEmpty) return centerMsg('没有 commit');
    final authors = _gitLog.map((c) => c.author).toSet().toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final logRefs = _gitBranches.map((b) => b.name).toSet().toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final effectiveRef = logRefs.contains(_gitLogRefFilter)
        ? _gitLogRefFilter
        : '';
    final scopeLabel = effectiveRef.isNotEmpty
        ? effectiveRef
        : _gitLogAllBranches
        ? 'All branches'
        : _gitStatus?.branch ?? 'Current branch';
    final effectiveAuthor = authors.contains(_logAuthorFilter)
        ? _logAuthorFilter
        : '';
    final commits = _filteredGitLog;
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
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: const InputDecoration(
                            hintText: 'Filter log',
                            isDense: true,
                            prefixIcon: Icon(Icons.search_rounded, size: 17),
                          ),
                          onChanged: (v) => setState(() => _logQuery = v),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: _gitLogAllBranches
                            ? 'Showing all branches'
                            : 'Showing current branch',
                        child: FilterChip(
                          selected: _gitLogAllBranches,
                          showCheckmark: false,
                          label: const Text('All'),
                          avatar: Icon(
                            Icons.account_tree_rounded,
                            size: 15,
                            color: _gitLogAllBranches
                                ? CcColors.accentBright
                                : CcColors.muted,
                          ),
                          onSelected: (v) {
                            setState(() {
                              _gitLogAllBranches = v;
                              if (v) _gitLogRefFilter = '';
                            });
                            Prefs.setBool('ws.gitLogAllBranches', v);
                            _refreshGit();
                          },
                        ),
                      ),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            isDense: true,
                            value: effectiveRef,
                            iconSize: 16,
                            style: CcType.code(size: 11, color: CcColors.muted),
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('Current'),
                              ),
                              for (final r in logRefs)
                                DropdownMenuItem(value: r, child: Text(r)),
                            ],
                            onChanged: (v) {
                              setState(() {
                                _gitLogRefFilter = v ?? '';
                                if (_gitLogRefFilter.isNotEmpty) {
                                  _gitLogAllBranches = false;
                                  Prefs.setBool('ws.gitLogAllBranches', false);
                                }
                              });
                              _refreshGit();
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 130),
                        child: FilterChip(
                          selected: _logPathFilter.isNotEmpty,
                          showCheckmark: false,
                          label: Text(
                            _logPathFilter.isEmpty ? 'Path' : _logPathFilter,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          avatar: Icon(
                            Icons.folder_open_rounded,
                            size: 15,
                            color: _logPathFilter.isNotEmpty
                                ? CcColors.accentBright
                                : CcColors.muted,
                          ),
                          onSelected: (_) => _setGitLogPathFilter(),
                          onDeleted: _logPathFilter.isEmpty
                              ? null
                              : () {
                                  setState(() => _logPathFilter = '');
                                  _refreshGit();
                                },
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$scopeLabel${_logPathFilter.isEmpty ? '' : ' · $_logPathFilter'} · ${commits.length}/${_gitLog.length} commits',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CcType.code(
                            size: 10.8,
                            color: CcColors.subtle,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 170),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            isDense: true,
                            value: effectiveAuthor,
                            iconSize: 16,
                            style: CcType.code(size: 11, color: CcColors.muted),
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('All authors'),
                              ),
                              for (final a in authors)
                                DropdownMenuItem(value: a, child: Text(a)),
                            ],
                            onChanged: (v) =>
                                setState(() => _logAuthorFilter = v ?? ''),
                          ),
                        ),
                      ),
                    ],
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
                      TextButton.icon(
                        onPressed: _gitLoading
                            ? null
                            : () =>
                                  _compareCommitWithWorking(p, selectedCommit),
                        icon: const Icon(
                          Icons.compare_arrows_rounded,
                          size: 14,
                        ),
                        label: const Text('Working Tree'),
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
      if (v == 'compareWorking') _compareCommitWithWorking(p, c);
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'copy', child: Text('Copy Hash')),
      const PopupMenuItem(value: 'branch', child: Text('New Branch from Here')),
      const PopupMenuItem(value: 'compare', child: Text('Show Commit Diff')),
      const PopupMenuItem(
        value: 'compareWorking',
        child: Text('Compare with Working Tree'),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'cherryPick', child: Text('Cherry-pick')),
      const PopupMenuItem(value: 'revert', child: Text('Revert')),
    ],
  );

  Widget _compactStashView(ProjectCfg p) {
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: const BoxDecoration(
            color: CcColors.panel,
            border: Border(bottom: BorderSide(color: CcColors.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_gitStashes.length} stashes',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 11.5, color: CcColors.subtle),
                ),
              ),
              IconButton(
                onPressed: _gitLoading ? null : () => _stashPushCurrent(p),
                icon: const Icon(Icons.archive_outlined, size: 16),
                tooltip: 'Stash Changes',
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                onPressed: _refreshGit,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        Expanded(
          child: _gitStashes.isEmpty
              ? centerMsg('没有 stash')
              : ListView.separated(
                  itemCount: _gitStashes.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: CcColors.border),
                  itemBuilder: (_, i) {
                    final s = _gitStashes[i];
                    final isSelected = s.ref == _selectedStash;
                    return Material(
                      color: isSelected
                          ? CcColors.accent.withValues(alpha: 0.10)
                          : Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          _selectStash(p, s);
                          _openGitView(_GitView.stash);
                        },
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.inventory_2_outlined,
                                    size: 17,
                                    color: isSelected
                                        ? CcColors.accentBright
                                        : CcColors.muted,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      s.subject.isEmpty ? s.ref : s.subject,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: isSelected
                                            ? CcColors.text
                                            : CcColors.muted,
                                        fontWeight: isSelected
                                            ? FontWeight.w700
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
                                  size: 10.8,
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
                                        : () => _stashApplyCurrent(p, s),
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
                                    style: TextButton.styleFrom(
                                      foregroundColor: CcColors.danger,
                                    ),
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
      ],
    );
  }

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

  Widget _branchButton(String branch) {
    final p = _gitProject;
    final locals = _gitBranches.where((b) => !b.remote && !b.current).toList();
    return PopupMenuButton<String>(
      tooltip: 'Git Branches',
      enabled: p != null,
      onSelected: (v) {
        if (p == null) return;
        if (v == 'branches') _openGitView(_GitView.branches);
        if (v == 'dialog') _showBranchDialog();
        if (v == 'new') _showCreateBranchQuick(p);
        if (v == 'fetch') _gitFetchCurrent(p);
        if (v == 'prune') _gitFetchCurrent(p, prune: true);
        if (v == 'pull') _gitPullCurrent(p);
        if (v == 'pullRebase') _gitPullRebaseCurrent(p);
        if (v == 'push') _gitPushCurrent(p);
        if (v.startsWith('checkout:')) {
          final name = v.substring('checkout:'.length);
          final target = _gitBranches
              .where((b) => !b.remote && b.name == name)
              .firstOrNull;
          if (target != null) _checkoutBranchCurrent(p, target);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Row(
            children: [
              const Icon(
                Icons.account_tree_rounded,
                size: 16,
                color: CcColors.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  branch,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 12.5, color: CcColors.text),
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'branches',
          child: Text('Open Branches Tab'),
        ),
        const PopupMenuItem(value: 'dialog', child: Text('Branches Popup...')),
        const PopupMenuItem(value: 'new', child: Text('New Branch...')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'fetch', child: Text('Fetch')),
        const PopupMenuItem(value: 'prune', child: Text('Fetch --prune')),
        const PopupMenuItem(value: 'pull', child: Text('Pull --ff-only')),
        const PopupMenuItem(value: 'pullRebase', child: Text('Pull --rebase')),
        const PopupMenuItem(value: 'push', child: Text('Push')),
        if (locals.isNotEmpty) const PopupMenuDivider(),
        for (final b in locals.take(8))
          PopupMenuItem(
            value: 'checkout:${b.name}',
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Checkout ${b.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (b.ahead > 0 || b.behind > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    '↑${b.ahead} ↓${b.behind}',
                    style: CcType.code(size: 11, color: CcColors.warning),
                  ),
                ],
              ],
            ),
          ),
      ],
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          border: Border.all(color: CcColors.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.account_tree_rounded, size: 15),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Text(
                branch,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.code(size: 12),
              ),
            ),
            const SizedBox(width: 3),
            const Icon(Icons.arrow_drop_down_rounded, size: 16),
          ],
        ),
      ),
    );
  }

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
              focusNode: _commitFocus,
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
          PopupMenuButton<String>(
            tooltip: 'Selected commit actions',
            enabled: canCommitSelected,
            icon: const Icon(Icons.arrow_drop_down_rounded, size: 18),
            onSelected: (v) {
              if (v == 'commitPushSelected') _gitCommitSelectedAndPush(p);
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'commitPushSelected',
                child: Text(
                  selected == 0
                      ? 'Commit Selected & Push'
                      : 'Commit $selected & Push',
                ),
              ),
            ],
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

  Widget _leftToolPanel() {
    if (_leftToolView == _LeftToolView.structure) return _structureSidebar();
    if (_gitViewForLeftTool(_leftToolView) != null) return _leftGitPanel();
    return _sidebar();
  }

  Widget _leftGitPanel() {
    final p = _gitProject ?? _defaultProject()?.project;
    final status = _gitStatus;
    final viewLabel = switch (_gitView) {
      _GitView.changes => 'Commit',
      _GitView.branches => 'Branches',
      _GitView.log => 'Git Log',
      _GitView.stash => 'Stash',
    };
    final viewIcon = switch (_gitView) {
      _GitView.changes => Icons.alt_route_rounded,
      _GitView.branches => Icons.account_tree_rounded,
      _GitView.log => Icons.history_rounded,
      _GitView.stash => Icons.inventory_2_outlined,
    };
    return Column(
      children: [
        _panelHeader(
          padding: const EdgeInsets.only(left: 10, right: 4),
          gradient: true,
          children: [
            Icon(viewIcon, size: 16, color: CcColors.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                p == null ? viewLabel : '$viewLabel · ${p.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: CcColors.text,
                ),
              ),
            ),
            if (p != null) ...[
              _branchButton(status?.branch ?? 'branch'),
              const SizedBox(width: 4),
            ],
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 17),
              tooltip: '刷新 Git',
              visualDensity: VisualDensity.compact,
              onPressed: _refreshGit,
            ),
            IconButton(
              onPressed: () => _setProjectCollapsed(true),
              tooltip: '收起',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_left_rounded, size: 17),
            ),
          ],
        ),
        if (p != null) _leftGitActionBar(p, status),
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
                Expanded(child: _gitToolBody(p, compact: true)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _leftGitActionBar(ProjectCfg p, GitStatusSummary? status) => Container(
    height: 34,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: const BoxDecoration(
      color: CcColors.editor,
      border: Border(bottom: BorderSide(color: CcColors.border)),
    ),
    child: Row(
      children: [
        IconButton(
          icon: const Icon(Icons.add_task_rounded, size: 16),
          tooltip: 'Stage All',
          visualDensity: VisualDensity.compact,
          onPressed: _gitLoading ? null : () => _gitStageAllCurrent(p),
        ),
        IconButton(
          icon: const Icon(Icons.remove_done_rounded, size: 16),
          tooltip: 'Unstage All',
          visualDensity: VisualDensity.compact,
          onPressed: _gitLoading || (status?.staged ?? 0) == 0
              ? null
              : () => _gitUnstageAllCurrent(p),
        ),
        IconButton(
          icon: const Icon(Icons.upload_rounded, size: 16),
          tooltip: 'Push',
          visualDensity: VisualDensity.compact,
          onPressed: _gitLoading ? null : () => _gitPushCurrent(p),
        ),
        IconButton(
          icon: const Icon(Icons.call_received_rounded, size: 16),
          tooltip: 'Pull --ff-only',
          visualDensity: VisualDensity.compact,
          onPressed: _gitLoading ? null : () => _gitPullCurrent(p),
        ),
        IconButton(
          icon: const Icon(Icons.sync_rounded, size: 16),
          tooltip: 'Fetch',
          visualDensity: VisualDensity.compact,
          onPressed: _gitLoading ? null : () => _gitFetchCurrent(p),
        ),
        const Spacer(),
        TextButton.icon(
          onPressed: _gitLoading ? null : () => _showBranchDialog(),
          icon: const Icon(Icons.account_tree_rounded, size: 14),
          label: const Text('Branches'),
        ),
      ],
    ),
  );

  Widget _structureSidebar() {
    final hasActiveFile = _activeFile >= 0 && _activeFile < _codeFiles.length;
    final file = hasActiveFile ? _codeFiles[_activeFile] : null;
    final text = file?.key.currentState?.text;
    final symbols = file == null || text == null
        ? const <_CodeSymbol>[]
        : _extractCodeSymbols(file.path, text);
    final query = _structureQuery.trim().toLowerCase();
    final filteredSymbols = query.isEmpty
        ? symbols
        : symbols
              .where(
                (s) =>
                    s.name.toLowerCase().contains(query) ||
                    s.kind.toLowerCase().contains(query),
              )
              .toList();
    return Column(
      children: [
        _panelHeader(
          padding: const EdgeInsets.only(left: 10, right: 4),
          gradient: true,
          children: [
            const Icon(Icons.schema_rounded, size: 16, color: CcColors.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                file?.name ?? 'Structure',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: CcColors.text,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              query.isEmpty
                  ? '${symbols.length}'
                  : '${filteredSymbols.length}/${symbols.length}',
              style: CcType.code(size: 11.5, color: CcColors.subtle),
            ),
            IconButton(
              onPressed: _showFileStructure,
              tooltip: '结构弹窗',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.open_in_full_rounded, size: 16),
            ),
            IconButton(
              onPressed: () => _setProjectCollapsed(true),
              tooltip: '收起',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_left_rounded, size: 17),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 7),
          child: TextField(
            controller: _structureQueryCtl,
            enabled: file != null && text != null && symbols.isNotEmpty,
            decoration: InputDecoration(
              hintText: 'Filter symbols',
              isDense: true,
              prefixIcon: const Icon(Icons.filter_list_rounded, size: 17),
              suffixIcon: _structureQuery.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16),
                      tooltip: '清空过滤',
                      onPressed: () => setState(() {
                        _structureQueryCtl.clear();
                        _structureQuery = '';
                      }),
                    ),
            ),
            onChanged: (v) => setState(() => _structureQuery = v),
            onSubmitted: (_) {
              if (file != null && filteredSymbols.isNotEmpty) {
                _openCodeFile(file.path, line: filteredSymbols.first.line);
              }
            },
          ),
        ),
        Expanded(
          child: file == null
              ? centerMsg('打开代码文件后显示结构')
              : text == null
              ? centerMsg('文件仍在加载')
              : symbols.isEmpty
              ? centerMsg('没有可跳转的结构符号')
              : filteredSymbols.isEmpty
              ? centerMsg('没有匹配符号')
              : ListView.separated(
                  itemCount: filteredSymbols.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: CcColors.border),
                  itemBuilder: (_, i) {
                    final s = filteredSymbols[i];
                    final level = (s.indent ~/ 2).clamp(0, 8).toDouble();
                    return ListTile(
                      dense: true,
                      visualDensity: const VisualDensity(vertical: -2),
                      contentPadding: EdgeInsets.only(
                        left: 10 + level * 12,
                        right: 8,
                      ),
                      leading: Icon(
                        s.icon,
                        size: 16,
                        color: CcColors.accentBright,
                      ),
                      title: Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CcType.code(size: 12),
                      ),
                      subtitle: Text(
                        '${s.kind} · line ${s.line}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CcType.code(size: 10.5, color: CcColors.subtle),
                      ),
                      onTap: () => _openCodeFile(file.path, line: s.line),
                    );
                  },
                ),
        ),
      ],
    );
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
              onPressed: _activeFile >= 0 && _activeFile < _codeFiles.length
                  ? _selectOpenedFileInProject
                  : null,
              tooltip: 'Select Opened File',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.my_location_rounded, size: 17),
            ),
            IconButton(
              onPressed: () {
                setState(
                  () => _projectAutoscrollFromSource =
                      !_projectAutoscrollFromSource,
                );
                Prefs.setBool(
                  'ws.projectAutoscrollFromSource',
                  _projectAutoscrollFromSource,
                );
                if (_projectAutoscrollFromSource) _selectOpenedFileInProject();
              },
              tooltip: _projectAutoscrollFromSource
                  ? 'Autoscroll from Source: On'
                  : 'Autoscroll from Source: Off',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                _projectAutoscrollFromSource
                    ? Icons.sync_alt_rounded
                    : Icons.sync_disabled_rounded,
                size: 17,
                color: _projectAutoscrollFromSource
                    ? CcColors.accentBright
                    : null,
              ),
            ),
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status != null && !status.clean) ...[
            statusDot(
              status.conflicted > 0 ? CcColors.danger : CcColors.warning,
              size: 7,
            ),
            const SizedBox(width: 4),
          ],
          _projectGitMenu(p),
        ],
      ),
      onTap: () => _selectGitProject(p, openTool: true),
    );
  }

  PopupMenuButton<String> _projectGitMenu(ProjectCfg project) {
    final selected = _gitProject?.path == project.path;
    final status = selected ? _gitStatus : null;
    final canStageAll =
        status == null || status.modified > 0 || status.untracked > 0;
    final canUnstageAll = status == null || status.staged > 0;
    final canRollbackAll =
        status == null ||
        status.modified > 0 ||
        status.untracked > 0 ||
        status.staged > 0;
    return PopupMenuButton<String>(
      tooltip: 'Git actions',
      icon: const Icon(Icons.more_vert_rounded, size: 16),
      padding: EdgeInsets.zero,
      onOpened: () => _selectGitProject(project),
      onSelected: (v) => _handleGitMenuAction(project, v),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'changes', child: Text('Open Changes')),
        const PopupMenuItem(
          value: 'workingDiff',
          child: Text('Show Working Tree Diff'),
        ),
        const PopupMenuItem(value: 'commit', child: Text('Commit...')),
        const PopupMenuItem(value: 'log', child: Text('Open Log')),
        const PopupMenuItem(value: 'branches', child: Text('Open Branches')),
        const PopupMenuItem(value: 'stash', child: Text('Open Stash')),
        const PopupMenuItem(
          value: 'branchPopup',
          child: Text('Branches Popup...'),
        ),
        const PopupMenuItem(value: 'newBranch', child: Text('New Branch...')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'fetch', child: Text('Fetch')),
        const PopupMenuItem(value: 'fetchPrune', child: Text('Fetch --prune')),
        const PopupMenuItem(value: 'pull', child: Text('Pull')),
        const PopupMenuItem(value: 'pullRebase', child: Text('Pull --rebase')),
        const PopupMenuItem(value: 'push', child: Text('Push')),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: canStageAll ? 'stageAll' : null,
          child: const Text('Stage All'),
        ),
        PopupMenuItem(
          value: canUnstageAll ? 'unstageAll' : null,
          child: const Text('Unstage All'),
        ),
        const PopupMenuItem(
          value: 'stashPush',
          child: Text('Stash Changes...'),
        ),
        PopupMenuItem(
          value: canRollbackAll ? 'rollbackAll' : null,
          child: const Text('Rollback All...'),
        ),
      ],
    );
  }

  // 统一处理 VCS 下拉菜单的动作分发(被多处 PopupMenuButton 复用)。
  // 并发保护已下沉到各 _gitXCurrent 方法,这里不再重复 _gitLoading 判断。
  void _handleGitMenuAction(ProjectCfg p, String v) {
    _selectGitProject(p);
    switch (v) {
      case 'changes':
        _openLeftTool(_LeftToolView.changes);
      case 'workingDiff':
        _showWorkingTreeDiff(p);
      case 'commit':
        _openCommitFlow(p);
      case 'log':
        _openLeftTool(_LeftToolView.log);
      case 'branches':
        _openLeftTool(_LeftToolView.branches);
      case 'stash':
        _openLeftTool(_LeftToolView.stash);
      case 'branchPopup':
        _showBranchDialog();
      case 'newBranch':
        _showCreateBranchQuick(p);
      case 'fetch':
        _gitFetchCurrent(p);
      case 'fetchPrune':
        _gitFetchCurrent(p, prune: true);
      case 'pull':
        _gitPullCurrent(p);
      case 'pullRebase':
        _gitPullRebaseCurrent(p);
      case 'push':
        _gitPushCurrent(p);
      case 'stageAll':
        _gitStageAllCurrent(p);
      case 'unstageAll':
        _gitUnstageAllCurrent(p);
      case 'stashPush':
        _stashPushCurrent(p);
      case 'rollbackAll':
        _gitDiscardAllCurrent(p);
    }
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
            selectedPath: _revealedProjectFilePath,
            fileMenuBuilder: (path) => _projectFileMenu(p, path),
            pathStatusBuilder: (path) => _projectPathStatus(p, path),
          ),
        ),
      ],
    );
  }

  Widget _projectPathStatus(ProjectCfg project, String path) {
    final rel = path == project.path
        ? ''
        : path.substring(project.path.length + 1);
    final isDir = FileSystemEntity.isDirectorySync(path);
    final changes = isDir
        ? _gitChanges
              .where(
                (c) =>
                    rel.isEmpty ||
                    c.path.startsWith('$rel/') ||
                    (c.oldPath?.startsWith('$rel/') ?? false),
              )
              .toList()
        : _gitChanges.where((c) => c.path == rel || c.oldPath == rel).toList();
    if (changes.isEmpty) return const SizedBox.shrink();
    final severity = changes.firstWhere(
      (c) => c.conflicted,
      orElse: () => changes.firstWhere(
        (c) => c.untracked,
        orElse: () =>
            changes.firstWhere((c) => c.staged, orElse: () => changes.first),
      ),
    );
    final label = isDir ? '${changes.length}' : _gitChangeShortLabel(severity);
    final target = rel.isEmpty ? project.name : rel;
    return Tooltip(
      message: isDir
          ? '$target · ${changes.length} changed files'
          : '${severity.status} · $target',
      child: tag(label, _changeColor(severity), bold: true),
    );
  }

  PopupMenuButton<String> _projectFileMenu(ProjectCfg project, String path) {
    final rel = path == project.path
        ? ''
        : path.substring(project.path.length + 1);
    return PopupMenuButton<String>(
      tooltip: 'File actions',
      icon: const Icon(Icons.more_vert_rounded, size: 16),
      padding: EdgeInsets.zero,
      onOpened: () => setState(() => _revealedProjectFilePath = path),
      onSelected: (v) {
        if (v == 'open') _openCodeFile(path);
        if (v == 'copyPath') _copyFilePath(path);
        if (v == 'reveal') _revealFileInProject(path);
        if (v == 'compare') _compareProjectFileWithHead(project, rel);
        if (v == 'history') _showFileHistoryForProjectFile(project, rel);
        if (v == 'annotate') _showBlameForProjectFile(project, rel);
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'open', child: Text('Open')),
        PopupMenuItem(value: 'copyPath', child: Text('Copy Path')),
        PopupMenuItem(value: 'reveal', child: Text('Reveal in Project')),
        PopupMenuDivider(),
        PopupMenuItem(value: 'compare', child: Text('Compare with HEAD')),
        PopupMenuItem(value: 'history', child: Text('File History')),
        PopupMenuItem(value: 'annotate', child: Text('Annotate / Blame')),
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
