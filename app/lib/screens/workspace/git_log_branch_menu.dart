part of '../workspace_page.dart';

/// 底部 Git Log 左栏「分支树」的右键菜单(参考图1 的 JetBrains/GoLand 风格)。
///
/// 从 `_WorkspacePageState` 抽出成独立 part,降与 ts89(左上 Commit 面板)/ts90
/// (go-to-def)在巨文件里的合并冲突。菜单构建 + 落地 action 都收在这里。
///
/// `on _GitMixin`:直接复用 git 状态字段 + 既有 git 操作(`_checkoutBranchCurrent`
/// /`_compareBranch`/`_mergeBranchIntoCurrent`/`_rebaseCurrentOntoBranch`/
/// `_pushBranchCurrent`/`_gitPullCurrent`/`_gitFetchCurrent`/`_createBranchCurrent`
/// /`_showBranchDialog`),不需要额外桥接。
mixin _GitLogBranchMenu on _GitMixin {
  /// 右键分支树里的一个分支。[b] 是被点的分支,[p] 是其所属项目。
  Future<void> _showLogBranchMenu(
    ProjectCfg p,
    GitBranch b,
    Offset position,
  ) async {
    final v = await showMenu<String>(
      context: context,
      position: menuPosAt(context, position),
      items: [
        if (!b.current)
          ccMenuItem(
            value: 'checkout',
            icon: Icons.call_split_rounded,
            label: 'Checkout',
          ),
        ccMenuItem(
          value: 'newFrom',
          icon: Icons.add_rounded,
          label: "New Branch from '${b.name}'…",
        ),
        ccMenuItem(
          value: 'compare',
          icon: Icons.difference_rounded,
          label: 'Show Diff with Working Tree',
        ),
        if (!b.current) ...[
          ccMenuItem(
            value: 'merge',
            icon: Icons.merge_type_rounded,
            label: 'Merge into Current',
          ),
          ccMenuItem(
            value: 'rebase',
            icon: Icons.merge_type_rounded,
            label: 'Rebase Current onto This',
          ),
        ],
        const PopupMenuDivider(),
        ccMenuItem(value: 'update', icon: Icons.sync_rounded, label: 'Update'),
        if (!b.remote) ...[
          ccMenuItem(value: 'push', icon: Icons.upload_rounded, label: 'Push…'),
          if (b.upstream.isEmpty)
            ccMenuItem(
              value: 'publish',
              icon: Icons.cloud_upload_rounded,
              label: 'Publish',
            ),
        ],
        const PopupMenuDivider(),
        if (!b.remote)
          ccMenuItem(
            value: 'rename',
            icon: Icons.drive_file_rename_outline_rounded,
            label: 'Rename…',
            shortcut: 'F2',
          ),
        ccMenuItem(
          value: 'dialog',
          icon: Icons.account_tree_rounded,
          label: 'Branches Popup…',
        ),
      ],
    );
    if (v == null || !mounted) return;
    switch (v) {
      case 'checkout':
        await _checkoutBranchCurrent(p, b);
      case 'newFrom':
        await _newBranchFrom(p, b);
      case 'compare':
        await _compareBranch(p, b);
      case 'merge':
        await _mergeBranchIntoCurrent(p, b);
      case 'rebase':
        await _rebaseCurrentOntoBranch(p, b);
      case 'update':
        await _updateBranch(p, b);
      case 'push':
        await _pushBranchCurrent(p, b);
      case 'publish':
        await _pushBranchCurrent(p, b, publish: true);
      case 'rename':
        await _renameBranchPrompt(p, b);
      case 'dialog':
        await _showBranchDialog();
    }
  }

  /// 右键 Tags 下的一个 tag。最重要的是 Push Tag,对应用户已经本地打好 tag
  /// 但还没有发到 origin 的发布流程。
  Future<void> _showLogTagMenu(ProjectCfg p, GitTag t, Offset position) async {
    final v = await showMenu<String>(
      context: context,
      position: menuPosAt(context, position),
      items: [
        ccMenuItem(
          value: 'push',
          icon: Icons.upload_rounded,
          label: 'Push Tag',
        ),
        ccMenuItem(
          value: 'copy',
          icon: Icons.copy_rounded,
          label: 'Copy Tag Name',
        ),
        ccMenuItem(
          value: 'branch',
          icon: Icons.add_rounded,
          label: "New Branch from '${t.name}'…",
        ),
        ccMenuItem(
          value: 'checkout',
          icon: Icons.label_important_outline_rounded,
          label: 'Checkout Tag…',
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'delete',
          icon: Icons.delete_outline_rounded,
          label: 'Delete Local Tag…',
        ),
      ],
    );
    if (v == null || !mounted) return;
    switch (v) {
      case 'push':
        await _pushTagCurrent(p, t);
      case 'copy':
        Clipboard.setData(ClipboardData(text: t.name));
        _snack('已复制 ${t.name}');
      case 'branch':
        await _newBranchFromTag(p, t);
      case 'checkout':
        await _checkoutTag(p, t);
      case 'delete':
        await _deleteLocalTag(p, t);
    }
  }

  /// New Branch from '<b>'…:以 [b] 为起点创建并切换到新分支。
  Future<void> _newBranchFrom(ProjectCfg p, GitBranch b) async {
    final name = await textPrompt(
      context,
      title: "New Branch from '${b.name}'",
      hint: 'Branch name',
      okLabel: 'Create and Checkout',
    );
    if (name == null) return;
    if (!mounted) return;
    await _createBranchCurrent(p, name, start: b.name);
  }

  Future<void> _newBranchFromTag(ProjectCfg p, GitTag t) async {
    final name = await textPrompt(
      context,
      title: "New Branch from '${t.name}'",
      hint: 'Branch name',
      okLabel: 'Create and Checkout',
    );
    if (name == null) return;
    if (!mounted) return;
    await _createBranchCurrent(p, name, start: t.ref);
  }

  Future<void> _pushTagCurrent(ProjectCfg p, GitTag t) async {
    if (_gitLoading) return;
    setState(() => _gitLoading = true);
    try {
      await gitPushTag(p.path, t.name);
      await _refreshGit();
      _snack('Push tag ${t.name} 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _checkoutTag(ProjectCfg p, GitTag t) async {
    final ok = await _confirm(
      'Checkout tag?',
      '${t.name}\n\n这会进入 detached HEAD。需要继续开发时，通常应该从 tag 创建新分支。',
    );
    if (!ok || !mounted || _gitLoading) return;
    setState(() => _gitLoading = true);
    try {
      await gitCheckout(p.path, t.ref);
      await _refreshGit();
      _snack('已 checkout ${t.name}');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  Future<void> _deleteLocalTag(ProjectCfg p, GitTag t) async {
    final ok = await _confirm(
      'Delete local tag?',
      '${t.name}\n\n只删除本地 tag；不会删除远端 origin 上的 tag。',
    );
    if (!ok || !mounted || _gitLoading) return;
    setState(() => _gitLoading = true);
    try {
      await gitDeleteTag(p.path, t.name);
      await _refreshGit();
      _snack('已删除本地 tag ${t.name}');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  /// Update:对当前分支执行 `git pull`,对其它/远端分支执行 `git fetch`(把远端引用
  /// 拉到本地)。语义贴近 JetBrains 的 Update Branch。
  Future<void> _updateBranch(ProjectCfg p, GitBranch b) async {
    if (b.current) {
      await _gitPullCurrent(p);
    } else {
      await _gitFetchCurrent(p);
    }
  }

  /// Rename…:重命名本地分支(`git branch -m`),完成后刷新。
  Future<void> _renameBranchPrompt(ProjectCfg p, GitBranch b) async {
    final name = await textPrompt(
      context,
      title: 'Rename Branch',
      hint: 'New name',
      initial: b.name,
      okLabel: 'Rename',
    );
    if (name == null || name == b.name) return;
    if (!mounted) return;
    if (_gitLoading) return;
    setState(() => _gitLoading = true);
    try {
      await gitRenameBranch(p.path, b.name, name);
      await _refreshGit();
      _snack('已重命名为 $name');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }
}
