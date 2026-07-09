part of '../workspace_page.dart';

/// Git 域(从 `_WorkspacePageState` 抽出):git 状态字段 + `_refreshGit` +
/// 所有 git 操作/数据方法。git 的 **视图构建**(返回 Widget 的方法)仍留在
/// 主类,它们把这里的字段当作 mixin 成员正常读写。
///
/// 方向为 mixin → 主类的少数调用在下方声明为 abstract,由 `_WorkspacePageState`
/// 实现(参照 `terminal_deck.dart` 的 `TerminalHost` 钩子模式)。
mixin _GitMixin on State<WorkspacePage> {
  // ---- 由宿主类 (_WorkspacePageState) 提供:mixin → 主类 的桥接 ----
  void _snack(String s);
  Future<bool> _confirm(String title, String message);
  ({WorkspaceCfg ws, ProjectCfg project})? _defaultProject();
  Future<void> _compareBranch(ProjectCfg p, GitBranch b);

  // ---- git 状态字段 ----
  ProjectCfg? _gitProject;
  GitStatusSummary? _gitStatus;
  GitOperationState? _gitOperation;
  List<FileDiff> _gitFiles = const [];
  List<GitChange> _gitChanges = const [];

  /// 每个附加 worktree 的 git 改动,按 worktree 路径缓存(展开时懒加载)。
  /// 项目根用 _gitChanges;worktree 各自一份,供其文件树角标使用。
  final Map<String, List<GitChange>> _worktreeChanges = {};
  List<GitCommit> _gitLog = const [];
  List<GitBranch> _gitBranches = const [];
  List<GitTag> _gitTags = const [];
  List<GitStash> _gitStashes = const [];
  List<FileDiff> _commitFiles = const [];
  String? _selectedCommit;
  String? _selectedStash;
  String? _compareTitle;
  List<FileDiff> _compareFiles = const [];
  // Re-fetches the currently shown commit/compare diff at a given git context
  // (for the diff viewer's 全部/相关 toggle); set whenever a commit/compare is
  // selected so the source (hash/refs) is captured. Null = no toggle.
  Future<List<FileDiff>> Function(int context)? _logDiffReload;
  String? _selectedGitPath;
  final Set<String> _selectedChangePaths = {};
  final String _changesQuery = '';
  _ChangeFilter _changesFilter = _ChangeFilter.all;
  String _logQuery = '';
  String _logAuthorFilter = '';
  String _logPathFilter = '';
  String _gitLogRefFilter = '';
  bool _gitLogAllBranches = Prefs.getBool('ws.gitLogAllBranches');
  bool _gitLoading = false;
  String? _gitError;
  final _commitCtl = TextEditingController();
  // Inline stash-name field (the commit-box-style Stash composer). Empty → gitStashPush
  // falls back to "WIP".
  final _stashCtl = TextEditingController();
  // Whether "Stash All" also stashes untracked files (git stash -u). On by default —
  // "all" should sweep new files too — toggled from the stash composer.
  bool _stashIncludeUntracked = true;

  // ---- commit 图形轨道:在「显示中的列表」上算一次 lane 布局并缓存 ----
  List<GraphRow> _graphRows = const [];
  int _graphLaneCount = 1;
  String _graphKey = '';

  /// 仅在显示列表变化时重算图形布局(纯写缓存、不 setState)。供 `_gitLogView`
  /// 每次 build 调用,幂等。分支/路径/all 切换会经 `_refreshGit` 替换 `_gitLog`
  /// => key 变 => 重算;滚动时复用同一批 [GraphRow] 实例,painter 不重绘。
  void _ensureGraph(List<GitCommit> commits) {
    // The graph depends only on the displayed list's content/order. length +
    // first + last hash distinguishes filtered lists that happen to share a
    // count and newest commit (avoids _graphRows drifting out of sync).
    final key = commits.isEmpty
        ? '0'
        : '${commits.length}|${commits.first.hash}|${commits.last.hash}';
    if (key == _graphKey) return;
    final layout = computeGraphRows(commits);
    _graphRows = layout.rows;
    _graphLaneCount = layout.laneCount;
    _graphKey = key;
  }

  /// 当前 git 项目:已选中的,否则回退到第一个可用项目。
  ProjectCfg? get _currentGitProject =>
      _gitProject ?? _defaultProject()?.project;

  Future<void> _refreshGit() async {
    final p = _currentGitProject;
    if (p == null) return;
    if (_gitProject == null && mounted) setState(() => _gitProject = p);
    if (!mounted) return;
    setState(() {
      _gitLoading = true;
      _gitError = null;
    });
    try {
      final status = await gitStatusSummary(p.path);
      final operation = await gitOperationState(p.path);
      final changes = await gitChanges(p.path);
      final diff = await gitDiffWorking(p.path);
      final (branches, tags) = await (
        gitBranches(p.path),
        gitTags(p.path),
      ).wait;
      final validRefs = {
        for (final b in branches) b.name,
        for (final t in tags) t.ref,
      };
      final logRef =
          _gitLogRefFilter.isNotEmpty && validRefs.contains(_gitLogRefFilter)
          ? _gitLogRefFilter
          : '';
      final log = await gitLog(
        p.path,
        allBranches: _gitLogAllBranches,
        ref: logRef,
        pathFilter: _logPathFilter,
      );
      final stashes = await gitStashes(p.path);
      if (!mounted) return;
      setState(() {
        _gitStatus = status;
        _gitOperation = operation;
        _gitChanges = changes;
        // git state changed → drop per-worktree change caches; they refetch
        // lazily on next expand (mirrors how _gitChanges refreshes here).
        _worktreeChanges.clear();
        _selectedChangePaths.removeWhere(
          (path) => !changes.any((c) => c.path == path),
        );
        _gitFiles = parseUnifiedDiff(diff);
        _gitLog = log;
        if (_logAuthorFilter.isNotEmpty &&
            !log.any((c) => c.author == _logAuthorFilter)) {
          _logAuthorFilter = '';
        }
        if (_gitLogRefFilter != logRef) {
          _gitLogRefFilter = '';
        }
        _gitBranches = branches;
        _gitTags = tags;
        _gitStashes = stashes;
        if (_selectedStash == null ||
            !stashes.any((s) => s.ref == _selectedStash)) {
          _selectedStash = stashes.isEmpty ? null : stashes.first.ref;
        }
        // Reset the selected commit if it isn't in the freshly-loaded log
        // (e.g. after switching repos): otherwise the detail pane would run
        // `git show <old-repo-hash>` against the new repo and fail with
        // "fatal: ambiguous argument". Mirrors the _selectedStash handling above.
        if (_selectedCommit == null ||
            !log.any((c) => c.hash == _selectedCommit)) {
          _selectedCommit = log.isEmpty ? null : log.first.hash;
          _commitFiles = const [];
          _compareTitle = null;
          _compareFiles = const [];
        }
        if (_selectedGitPath != _workingTreeDiffSelection &&
            (_selectedGitPath == null ||
                !_gitFiles.any((f) => f.path == _selectedGitPath))) {
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

  /// 懒加载某个附加 worktree 的 git 改动(展开 worktree 节点时调用)。
  Future<void> _ensureWorktreeChanges(String wtPath) async {
    if (_worktreeChanges.containsKey(wtPath)) {
      return; // cached until _refreshGit
    }
    final changes = await gitChanges(wtPath);
    if (mounted) setState(() => _worktreeChanges[wtPath] = changes);
  }

  Future<void> _gitPullCurrent(ProjectCfg p) async {
    if (_gitLoading) return;
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

  Future<void> _gitPullRebaseCurrent(ProjectCfg p) async {
    if (_gitLoading) return;
    final branch = _gitStatus?.branch ?? 'current branch';
    final ok = await _confirm(
      'Pull with rebase?',
      '$branch\n\n会执行 `git pull --rebase`，把本地提交变基到 upstream 之后。',
    );
    if (!ok) return;
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitPullRebase(p.path);
      await _refreshGit();
      _snack('Pull --rebase 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitFetchCurrent(ProjectCfg p, {bool prune = false}) async {
    if (_gitLoading) return;
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

  Future<void> _deleteRemoteBranchCurrent(
    ProjectCfg p,
    GitBranch branch,
  ) async {
    setState(() => _gitLoading = true);
    try {
      await gitPushDeleteRemoteBranch(p.path, branch);
      await _refreshGit();
      _snack('远端分支已删除');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _checkoutBranchCurrent(ProjectCfg p, GitBranch branch) async {
    setState(() => _gitLoading = true);
    try {
      await gitCheckoutBranch(p.path, branch);
      await _refreshGit();
      _snack('切换到 ${branch.localName ?? branch.name}');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _createBranchCurrent(
    ProjectCfg p,
    String branch, {
    String? start,
  }) async {
    setState(() => _gitLoading = true);
    try {
      await gitCreateBranch(p.path, branch, start: start);
      await _refreshGit();
      _snack('创建并切换到 $branch');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitStageAllCurrent(ProjectCfg p) async {
    if (_gitLoading) return;
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
    if (_gitLoading) return;
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
    if (!mounted) return;
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
    final preview = _previewList(files, take: 8);
    if (!await _confirm(
      'Rollback selected changes?',
      '$preview\n\n这会恢复 ${files.length} 个文件的工作区改动。',
    )) {
      return;
    }
    if (!mounted) return;
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

  Future<void> _gitDiscardAllCurrent(ProjectCfg p) async {
    if (_gitLoading) return;
    final changes = _gitChanges.where((c) => !c.conflicted).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (changes.isEmpty) {
      _snack('没有可 rollback 的文件');
      return;
    }
    final files = changes.map((c) => c.path).toList();
    final preview = _previewList(files, take: 8);
    if (!await _confirm(
      'Rollback all changes?',
      '$preview\n\n这会恢复 ${files.length} 个文件的工作区改动；冲突文件不会在这里处理。',
    )) {
      return;
    }
    if (!mounted) return;
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
    if (!mounted) return;
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
    if (!mounted) return;
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
      await _commitSelectedFiles(p, files);
      await _refreshGit();
      _snack('Commit selected 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _gitCommitSelectedAndPush(ProjectCfg p) async {
    final files = _selectedChangePaths.toList()..sort();
    if (files.isEmpty) return;
    setState(() => _gitLoading = true);
    try {
      await _commitSelectedFiles(p, files);
      final pushed = await _gitPushWithUpstreamFallback(p);
      if (!pushed) {
        await _refreshGit();
        _snack('Commit selected 完成，Push 已取消');
        return;
      }
      await _refreshGit();
      _snack('Commit selected & Push 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _commitSelectedFiles(ProjectCfg p, List<String> files) async {
    await gitUnstageAll(p.path);
    await gitStageFiles(p.path, files);
    await gitCommit(p.path, _commitCtl.text);
    _commitCtl.clear();
    _selectedChangePaths.clear();
  }

  Future<({String message, bool includeUntracked})?> _askStashOptions({
    required String title,
    String? detail,
  }) async {
    final ctl = TextEditingController(
      text: 'WIP ${DateTime.now().toIso8601String()}',
    );
    var includeUntracked = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (detail != null) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    detail,
                    style: const TextStyle(color: CcColors.muted),
                  ),
                ),
                const SizedBox(height: 10),
              ],
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
    final result = ok == true
        ? (message: ctl.text, includeUntracked: includeUntracked)
        : null;
    ctl.dispose();
    return result;
  }

  Future<void> _stashPushCurrent(ProjectCfg p) async {
    if (_gitLoading) return;
    final opts = await _askStashOptions(title: 'Stash Changes');
    if (opts == null) return;
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitStashPush(
        p.path,
        opts.message,
        includeUntracked: opts.includeUntracked,
      );
      await _refreshGit();
      _snack('Stash 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  // _stashAllCurrent is the one-click "Stash All" behind the inline composer: no
  // dialog — it stashes every change using the typed name (_stashCtl, or "WIP" when
  // blank) and the untracked toggle, then clears the field. The dialog-based
  // _stashPushCurrent stays for the tree/menu entry points.
  Future<void> _stashAllCurrent(ProjectCfg p) async {
    if (_gitLoading) return;
    setState(() => _gitLoading = true);
    try {
      await gitStashPush(
        p.path,
        _stashCtl.text,
        includeUntracked: _stashIncludeUntracked,
      );
      _stashCtl.clear();
      await _refreshGit();
      _snack('Stash 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _stashSelectedCurrent(ProjectCfg p) async {
    final files =
        _gitChanges
            .where(
              (c) => _selectedChangePaths.contains(c.path) && !c.conflicted,
            )
            .map((c) => c.path)
            .toList()
          ..sort();
    if (files.isEmpty) return;
    final opts = await _askStashOptions(
      title: 'Stash Selected Changes',
      detail: '${files.length} selected files',
    );
    if (opts == null) return;
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitStashPush(
        p.path,
        opts.message,
        includeUntracked: opts.includeUntracked,
        files: files,
      );
      _selectedChangePaths.removeAll(files);
      await _refreshGit();
      _snack('Stash selected 完成');
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
    if (!mounted) return;
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
    if (_gitLoading) return;
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

  Future<void> _pushBranchCurrent(
    ProjectCfg p,
    GitBranch branch, {
    bool publish = false,
  }) async {
    setState(() => _gitLoading = true);
    try {
      await gitPushBranch(p.path, branch.name, setUpstream: publish);
      await _refreshGit();
      _snack(publish ? 'Publish ${branch.name} 完成' : 'Push ${branch.name} 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _showCreateBranchQuick(ProjectCfg p) async {
    final current = _gitStatus?.branch ?? '';
    final ctl = TextEditingController();
    final startCtl = TextEditingController(text: current);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Branch'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctl,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Branch name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: startCtl,
              decoration: const InputDecoration(labelText: 'Start point'),
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
    if (ok != true) {
      ctl.dispose();
      startCtl.dispose();
      return;
    }
    final branch = ctl.text.trim();
    final start = startCtl.text.trim();
    ctl.dispose();
    startCtl.dispose();
    if (branch.isEmpty) {
      _snack('分支名不能为空');
      return;
    }
    await _createBranchCurrent(p, branch, start: start.isEmpty ? null : start);
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
      if (!mounted) return false;
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
          await _checkoutBranchCurrent(p, branch);
        },
        onCreate: (branch, start) async {
          await _createBranchCurrent(p, branch, start: start);
        },
        onRename: (oldName, newName) async {
          await gitRenameBranch(p.path, oldName, newName);
          await _refreshGit();
        },
        onDelete: (branch, force) async {
          await gitDeleteBranch(p.path, branch, force: force);
          await _refreshGit();
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
    if (!mounted) return;
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
    if (!mounted) return;
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
}
