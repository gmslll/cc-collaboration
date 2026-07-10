part of '../workspace_page.dart';

/// Commit 工具窗里「改动文件」的右键 / ⋮ 菜单(参考图5 的 JetBrains/GoLand 风格)。
///
/// 建在 `showMenu` 而非 `PopupMenuButton` 上,这样能:①按光标定位;②级联出
/// 「Git ▸」子菜单(Flutter 的 showMenu 没有原生子菜单,沿用 `showGroupedSendMenu`
/// 的二段式做法)。菜单构建 + 落地 action 都收在这里,降与 ts88(底部 Log)/ts90
/// (go-to-def) 的合并冲突。
///
/// **边界**:IDE 专属、git 无对应的概念一律省略而非造假——Changelist
/// (Move/New/Edit,改动行的勾选本就是事实上的分组)、「Show Local Changes as
/// UML」、「Local History」。「Shelve Changes…」映射到单文件 `git stash push`。
///
/// 与 `_GitMixin`/`_SearchMixin` 同构:`on _GitMixin` 拿到 git 状态/操作,主类里的
/// 视图方法(`_openCodeFile` 等)按桥接模式声明为 abstract,由 `_WorkspacePageState`
/// 提供。
double workspaceCommitFileDialogWidth(Size size, {double preferred = 440}) {
  final available = size.width - 32;
  if (!available.isFinite || available <= 0) return preferred;
  return available < preferred ? available : preferred;
}

mixin _CommitChangesMenu on _GitMixin, _SearchMixin {
  // ---- 主类 (_WorkspacePageState) 提供的视图桥接 ----
  // (_openCodeFile 已由 _SearchMixin 声明,这里 on _SearchMixin 直接复用。)
  Future<void> _openWorkingTreeDiffTab(String path, {bool newTab});
  Future<void> _compareProjectFileWithHead(ProjectCfg p, String relPath);
  void _showFileHistoryForProjectFile(ProjectCfg p, String relPath);
  void _showBlameForProjectFile(ProjectCfg p, String relPath);

  /// 在 [pos] 弹出改动文件的顶层菜单。[c] 是改动行,[p] 是其所属项目。
  Future<void> _showCommitFileMenu(
    Offset pos,
    ProjectCfg p,
    GitChange c,
  ) async {
    final v = await showMenu<String>(
      context: context,
      position: menuPosAt(context, pos),
      items: _commitFileMenuItems(c),
    );
    if (v == null || !mounted) return;
    if (v == 'git-more') {
      await _showCommitFileGitMenu(pos, p, c);
      return;
    }
    await _runCommitFileAction(v, p, c);
  }

  /// 顶层菜单项(图5 的可落地子集),按分隔线分组以贴近参考密度。
  List<PopupMenuEntry<String>> _commitFileMenuItems(GitChange c) => [
    ccMenuItem(
      value: 'commit',
      icon: Icons.check_rounded,
      label: 'Commit File…',
    ),
    ccMenuItem(
      value: 'rollback',
      icon: Icons.undo_rounded,
      label: 'Rollback…',
      shortcut: '⌥⌘Z',
      danger: true,
    ),
    const PopupMenuDivider(),
    ccMenuItem(
      value: 'diff',
      icon: Icons.difference_rounded,
      label: 'Show Diff',
      shortcut: '⌘D',
    ),
    ccMenuItem(
      value: 'diff-tab',
      icon: Icons.open_in_new_rounded,
      label: 'Show Diff in a New Tab',
    ),
    ccMenuItem(
      value: 'source',
      icon: Icons.my_location_rounded,
      label: 'Jump to Source',
      shortcut: '⌘↓',
    ),
    const PopupMenuDivider(),
    ccMenuItem(
      value: 'delete',
      icon: Icons.delete_outline_rounded,
      label: 'Delete…',
      danger: true,
    ),
    if (c.untracked)
      ccMenuItem(
        value: 'add',
        icon: Icons.add_rounded,
        label: 'Add to VCS',
        shortcut: '⌥⌘A',
      ),
    const PopupMenuDivider(),
    ccMenuItem(
      value: 'patch-file',
      icon: Icons.note_add_outlined,
      label: 'Create Patch from Local Changes…',
    ),
    ccMenuItem(
      value: 'patch-clip',
      icon: Icons.content_copy_rounded,
      label: 'Copy as Patch to Clipboard',
    ),
    ccMenuItem(
      value: 'shelve',
      icon: Icons.inventory_2_outlined,
      label: 'Shelve Changes…',
    ),
    const PopupMenuDivider(),
    ccMenuItem(value: 'refresh', icon: Icons.refresh_rounded, label: 'Refresh'),
    const PopupMenuDivider(),
    ccMenuItem(
      value: 'git-more',
      icon: Icons.account_tree_rounded,
      label: 'Git  ▸',
    ),
  ];

  /// 「Git ▸」子菜单:文件级常用 git 操作(原 ⋮ 菜单里那批)。
  Future<void> _showCommitFileGitMenu(
    Offset pos,
    ProjectCfg p,
    GitChange c,
  ) async {
    final v = await showMenu<String>(
      context: context,
      position: menuPosAt(context, pos),
      items: [
        if (c.unstaged && !c.untracked)
          ccMenuItem(
            value: 'stage',
            icon: Icons.add_rounded,
            label: 'Add to VCS (Stage)',
          ),
        if (c.staged)
          ccMenuItem(
            value: 'unstage',
            icon: Icons.remove_rounded,
            label: 'Unstage',
          ),
        if (!c.untracked) ...[
          const PopupMenuDivider(),
          ccMenuItem(
            value: 'compare',
            icon: Icons.difference_rounded,
            label: 'Compare with HEAD',
          ),
          ccMenuItem(
            value: 'history',
            icon: Icons.history_rounded,
            label: 'Show History',
          ),
          ccMenuItem(
            value: 'annotate',
            icon: Icons.format_align_left_rounded,
            label: 'Annotate with Git Blame',
          ),
        ],
      ],
    );
    if (v == null || !mounted) return;
    await _runCommitFileAction(v, p, c);
  }

  /// 把菜单返回的 value 派发到具体操作。委托给已有方法的分支不重复处理
  /// setState/spinner(那些方法内部已处理);仅本文件新增的写操作自管 loading。
  Future<void> _runCommitFileAction(String v, ProjectCfg p, GitChange c) async {
    switch (v) {
      case 'commit':
        await _commitSingleFile(p, c.path);
      case 'rollback':
        await _gitDiscardFileCurrent(p, c.path);
      case 'diff':
        await _openWorkingTreeDiffTab(c.path);
      case 'diff-tab':
        await _openWorkingTreeDiffTab(c.path, newTab: true);
      case 'source':
        _openCodeFile('${p.path}/${c.path}');
      case 'delete':
        await _deleteChangeFile(p, c);
      case 'add':
      case 'stage':
        await _gitStageFileCurrent(p, c.path);
      case 'unstage':
        await _gitUnstageFileCurrent(p, c.path);
      case 'patch-file':
        await _createPatchFromChanges(p, [c]);
      case 'patch-clip':
        await _copyPatchToClipboard(p, [c]);
      case 'shelve':
        await _shelveChange(p, c);
      case 'refresh':
        await _refreshGit();
      case 'compare':
        await _compareProjectFileWithHead(p, c.path);
      case 'history':
        _showFileHistoryForProjectFile(p, c.path);
      case 'annotate':
        _showBlameForProjectFile(p, c.path);
    }
  }

  // ---- 本文件新增的落地操作 ----

  /// Commit File…:只提交此文件。语义同 IDE——先把其它文件退出暂存,只暂存此文件
  /// 再提交(与既有 `_commitSelectedFiles` 一致)。message 走小弹窗,默认取提交框内容。
  Future<void> _commitSingleFile(ProjectCfg p, String path) async {
    final msg = await _promptCommitMessage(path);
    if (msg == null) return;
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitUnstageAll(p.path);
      await gitStageFiles(p.path, [path]);
      await gitCommit(p.path, msg);
      _selectedChangePaths.remove(path);
      await _refreshGit();
      _snack('Commit File 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  /// Delete…:从工作区删除文件(tracked→`git rm -f`;untracked→`git clean -f`)。
  /// 破坏性,confirm 门控。
  Future<void> _deleteChangeFile(ProjectCfg p, GitChange c) async {
    if (!await _confirm(
      '删除文件?',
      '${c.path}\n\n这会从磁盘删除该文件${c.untracked ? '' : '并从 Git 移除'},不可撤销。',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitRemoveFile(p.path, c.path, tracked: !c.untracked);
      _selectedChangePaths.remove(c.path);
      await _refreshGit();
      _snack('已删除 ${c.path}');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  /// 取本地改动的 patch;为空则提示并返回 null(Create Patch / Copy as Patch 共用)。
  Future<String?> _localChangesPatch(
    ProjectCfg p,
    List<GitChange> changes,
  ) async {
    final patch = await gitDiffToPatch(p.path, changes);
    if (patch.trim().isEmpty) {
      _snack('没有改动可导出为 patch');
      return null;
    }
    return patch;
  }

  /// Create Patch from Local Changes…:把本地改动导出成 .patch 文件(原生保存框)。
  Future<void> _createPatchFromChanges(
    ProjectCfg p,
    List<GitChange> changes,
  ) async {
    try {
      final patch = await _localChangesPatch(p, changes);
      if (patch == null) return;
      if (!mounted) return;
      final suggested = changes.length == 1
          ? '${changes.first.path.split('/').last}.patch'
          : 'local-changes.patch';
      final dest = await FilePicker.platform.saveFile(
        dialogTitle: 'Create Patch from Local Changes',
        fileName: suggested,
      );
      if (dest == null) return; // 用户取消
      if (!mounted) return;
      final out = dest.endsWith('.patch') ? dest : '$dest.patch';
      await File(out).writeAsString(patch);
      if (mounted) _snack('已保存 patch: ${out.split('/').last}');
    } catch (e) {
      if (mounted) _snack(errorText(e));
    }
  }

  /// Copy as Patch to Clipboard:本地改动的 patch 直接进剪贴板。
  Future<void> _copyPatchToClipboard(
    ProjectCfg p,
    List<GitChange> changes,
  ) async {
    try {
      final patch = await _localChangesPatch(p, changes);
      if (patch == null) return;
      if (!mounted) return;
      await Clipboard.setData(ClipboardData(text: patch));
      if (mounted) _snack('Patch 已复制到剪贴板');
    } catch (e) {
      if (mounted) _snack(errorText(e));
    }
  }

  /// Shelve Changes…:映射到单文件 `git stash push`(可从 Stash 面板恢复)。
  Future<void> _shelveChange(ProjectCfg p, GitChange c) async {
    final opts = await _askStashOptions(
      title: 'Shelve Changes',
      detail: '将「${c.path}」的改动搁置为一个 git stash(可从 Stash 面板恢复)。',
    );
    if (opts == null) return;
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitStashPush(
        p.path,
        opts.message,
        includeUntracked: opts.includeUntracked,
        files: [c.path],
      );
      _selectedChangePaths.remove(c.path);
      await _refreshGit();
      _snack('Shelve 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  /// Commit File… 的 message 小弹窗。取消或留空 → null(留空时提示)。
  Future<String?> _promptCommitMessage(String path) async {
    final ctl = TextEditingController(text: _commitCtl.text);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: const Text(
            'Commit File',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: SizedBox(
            width: workspaceCommitFileDialogWidth(size),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '只提交此文件:',
                    style: TextStyle(color: CcColors.muted),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: CcType.code(size: 12),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: ctl,
                    autofocus: true,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: 'Commit message',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Commit'),
            ),
          ],
        );
      },
    );
    final text = ctl.text.trim();
    ctl.dispose();
    if (ok != true) return null;
    if (text.isEmpty) {
      if (mounted) _snack('请填写 commit message');
      return null;
    }
    return text;
  }
}
