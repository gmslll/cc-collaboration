part of '../workspace_page.dart';

/// 底部 Git Log 中栏「commit 列表」的右键 / ⋮ 菜单(参考图2 的 JetBrains/GoLand
/// 风格)。从 `_WorkspacePageState` 抽出成独立 part,降合并冲突。原本 commit 行没有
/// 真右键(只有 ⋮ 按钮),这里补上 onSecondaryTapDown(见 workspace_page.dart 的
/// `_commitRow`)并把菜单大幅补齐。
///
/// `on _GitMixin`:git 状态字段 + 既有 git 操作直接用;主类独有的 commit 操作
/// (`_copyCommitHash`/`_selectCommit`/`_cherryPickCommit`/`_revertCommit`/
/// `_createBranchFromCommit`/`_compareCommitWithWorking`)按桥接模式声明为 abstract。
///
/// **边界**:需要「多选」(Drop/Squash 多个 commit)或「交互式 rebase 编辑器 UI」的
/// 项在本端无对应基础设施,按 JetBrains 同款上下文置灰而非造假;破坏性项
/// (reset --hard / drop / fixup / squash / reword=改写历史)全部 confirm 门控,且
/// 只作用于「运行时用户打开的仓库」。
mixin _GitLogCommitMenu on _GitMixin {
  // ---- 主类 (_WorkspacePageState) 提供的桥接 ----
  void _copyCommitHash(GitCommit c);
  Future<void> _createBranchFromCommit(ProjectCfg p, GitCommit c);
  Future<void> _cherryPickCommit(ProjectCfg p, GitCommit c);
  Future<void> _revertCommit(ProjectCfg p, GitCommit c);
  Future<void> _selectCommit(ProjectCfg p, GitCommit c);
  Future<void> _compareCommitWithWorking(ProjectCfg p, GitCommit c);

  /// commit 行的右键菜单(也复用给 ⋮ 按钮)。在 [pos] 弹出。
  Future<void> _showCommitMenu(Offset pos, ProjectCfg p, GitCommit c) async {
    if (_gitLoading) return;
    // HEAD 判定(门控 Undo Commit)。用内存里当前分支的 tip(short hash)前缀比对,
    // 避免每次右键都起一个 login-shell 跑 rev-parse 阻塞菜单弹出。
    final current = _gitBranches.where((b) => b.current).firstOrNull;
    final isHead =
        current != null &&
        current.lastHash.isNotEmpty &&
        c.hash.startsWith(current.lastHash);
    final hasParent = c.parents.isNotEmpty;
    final child = _gitLog.where((x) => x.parents.contains(c.hash)).firstOrNull;
    final v = await showMenu<String>(
      context: context,
      position: menuPosAt(context, pos),
      items: [
        ccMenuItem(
          value: 'copyRev',
          icon: Icons.content_copy_rounded,
          label: 'Copy Revision Number',
          shortcut: '⌥⇧⌘C',
        ),
        ccMenuItem(
          value: 'patch',
          icon: Icons.note_add_outlined,
          label: 'Create Patch…',
        ),
        ccMenuItem(
          value: 'cherryPick',
          icon: Icons.content_paste_rounded,
          label: 'Cherry-Pick',
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'checkoutRev',
          icon: Icons.call_split_rounded,
          label: 'Checkout Revision',
        ),
        ccMenuItem(
          value: 'showAtRev',
          icon: Icons.account_tree_outlined,
          label: 'Show Repository at Revision',
        ),
        ccMenuItem(
          value: 'compareLocal',
          icon: Icons.compare_arrows_rounded,
          label: 'Compare with Local',
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'reset',
          icon: Icons.restart_alt_rounded,
          label: 'Reset Current Branch to Here…',
          danger: true,
        ),
        ccMenuItem(
          value: 'revert',
          icon: Icons.undo_rounded,
          label: 'Revert Commit',
        ),
        ccMenuItem(
          value: 'undo',
          icon: Icons.settings_backup_restore_rounded,
          label: 'Undo Commit…',
          enabled: isHead,
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'reword',
          icon: Icons.edit_outlined,
          label: 'Edit Commit Message…',
          shortcut: 'F2',
        ),
        ccMenuItem(
          value: 'fixup',
          icon: Icons.merge_rounded,
          label: 'Fixup into Parent…',
          enabled: hasParent,
        ),
        ccMenuItem(
          value: 'squash',
          icon: Icons.compress_rounded,
          label: 'Squash into Parent…',
          enabled: hasParent,
        ),
        ccMenuItem(
          value: 'drop',
          icon: Icons.delete_outline_rounded,
          label: 'Drop Commit…',
          danger: true,
          enabled: hasParent,
        ),
        // 需多选,本端无 → 置灰(与 JetBrains 同款上下文)。
        ccMenuItem(
          value: null,
          icon: Icons.layers_clear_rounded,
          label: 'Squash Commits…',
          enabled: false,
        ),
        // 需交互式 rebase 编辑器 UI,本端无 → 置灰。
        ccMenuItem(
          value: null,
          icon: Icons.reorder_rounded,
          label: 'Interactively Rebase from Here…',
          enabled: false,
        ),
        ccMenuItem(
          value: 'pushUpTo',
          icon: Icons.upload_rounded,
          label: 'Push All up to Here…',
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'newBranch',
          icon: Icons.add_rounded,
          label: 'New Branch…',
          shortcut: '⌥⌘N',
        ),
        ccMenuItem(
          value: 'newTag',
          icon: Icons.sell_outlined,
          label: 'New Tag…',
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'goChild',
          icon: Icons.arrow_upward_rounded,
          label: 'Go to Child Commit',
          enabled: child != null,
        ),
        ccMenuItem(
          value: 'goParent',
          icon: Icons.arrow_downward_rounded,
          label: 'Go to Parent Commit',
          enabled: hasParent,
        ),
        ccMenuItem(
          value: 'github',
          icon: Icons.open_in_browser_rounded,
          label: 'Open on GitHub',
        ),
      ],
    );
    if (v == null || !mounted) return;
    switch (v) {
      case 'copyRev':
        _copyCommitHash(c);
      case 'patch':
        await _createPatchFromCommit(p, c);
      case 'cherryPick':
        await _cherryPickCommit(p, c);
      case 'checkoutRev':
        await _checkoutRevision(p, c);
      case 'showAtRev':
        await _selectCommit(p, c);
      case 'compareLocal':
        await _compareCommitWithWorking(p, c);
      case 'reset':
        await _resetToCommit(p, c);
      case 'revert':
        await _revertCommit(p, c);
      case 'undo':
        await _undoCommit(p, c);
      case 'reword':
        await _rewordCommit(p, c);
      case 'fixup':
        await _fixupOrSquash(p, c, keepMessage: false);
      case 'squash':
        await _fixupOrSquash(p, c, keepMessage: true);
      case 'drop':
        await _dropCommit(p, c);
      case 'pushUpTo':
        await _pushUpToCommit(p, c);
      case 'newBranch':
        await _createBranchFromCommit(p, c);
      case 'newTag':
        await _newTagAtCommit(p, c);
      case 'goChild':
        if (child != null) await _selectCommit(p, child);
      case 'goParent':
        await _goToParent(p, c);
      case 'github':
        await _openCommitOnGitHub(p, c);
    }
  }

  // ---- 落地操作 ----

  /// Create Patch…:把该 commit 导出成 .patch(git format-patch -1)。
  Future<void> _createPatchFromCommit(ProjectCfg p, GitCommit c) async {
    try {
      final patch = await gitFormatPatch(p.path, c.hash);
      if (patch.trim().isEmpty) {
        _snack('没有可导出的内容');
        return;
      }
      final out = await pickPatchFilePath('${c.shortHash}.patch');
      if (out == null) return;
      if (!mounted) return;
      final saved = await writePatchFile(out, patch);
      if (mounted) _snack('已保存 patch: $saved');
    } catch (e) {
      if (mounted) _snack(errorText(e));
    }
  }

  /// Checkout Revision:切到该 commit(detached HEAD)。confirm。
  Future<void> _checkoutRevision(ProjectCfg p, GitCommit c) async {
    if (!await _confirm(
      'Checkout revision?',
      '${c.shortHash} · ${c.subject}\n\n会切到该提交(detached HEAD)。未提交改动请先处理。',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitCheckout(p.path, c.hash);
      await _refreshGit();
      _snack('已切到 ${c.shortHash}(detached）');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  /// Reset Current Branch to Here…:soft/mixed/hard 三选一 → git reset。破坏性。
  Future<void> _resetToCommit(ProjectCfg p, GitCommit c) async {
    final mode = await _pickResetMode(c);
    if (mode == null) return;
    if (!mounted) return;
    if (mode == 'hard' &&
        !await _confirm(
          'Hard reset?',
          '${c.shortHash} · ${c.subject}\n\n`git reset --hard` 会丢弃工作区未提交改动,不可撤销。',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitReset(p.path, c.hash, mode: mode);
      await _refreshGit();
      _snack('已 reset --$mode 到 ${c.shortHash}');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  /// Undo Commit…:仅当选中的是 HEAD——soft reset 到父,保留改动在工作区/暂存区。
  Future<void> _undoCommit(ProjectCfg p, GitCommit c) async {
    if (!await _confirm(
      'Undo commit?',
      '${c.shortHash} · ${c.subject}\n\n会 `git reset --soft HEAD^`,撤销这次提交但保留其改动。',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitReset(p.path, '${c.hash}^', mode: 'soft');
      await _refreshGit();
      _snack('已撤销提交 ${c.shortHash}(改动已保留）');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  /// Edit Commit Message…(reword):HEAD 走 amend 快路径,更早的 commit 走脚本化
  /// interactive rebase 的 reword。
  Future<void> _rewordCommit(ProjectCfg p, GitCommit c) async {
    final msg = await _promptRewordMessage(
      title: 'Edit Commit Message',
      hint: '${c.shortHash} · reword',
      initial: c.subject,
    );
    if (msg == null || msg.isEmpty) return;
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      // 走脚本化 rebase 的 reword(--autostash 保留暂存/工作区改动),只改信息;
      // 不用 amend——amend 会把已暂存的改动一并折进该 commit。
      await gitRewordCommit(p.path, c.hash, msg);
      await _refreshGit();
      _snack('已修改提交信息');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  /// Fixup / Squash into Parent:把该 commit 并入其父。改写历史,confirm。
  Future<void> _fixupOrSquash(
    ProjectCfg p,
    GitCommit c, {
    required bool keepMessage,
  }) async {
    final verb = keepMessage ? 'Squash' : 'Fixup';
    if (!await _confirm(
      '$verb into parent?',
      '${c.shortHash} · ${c.subject}\n\n会把该提交并入其父提交'
          '${keepMessage ? '(合并两者的提交信息)' : '(丢弃该提交信息)'},会改写历史。',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitFixupIntoParent(p.path, c.hash, keepMessage: keepMessage);
      await _refreshGit();
      _snack('$verb 完成');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  /// Drop Commit…:从历史移除该 commit(脚本化 rebase drop)。改写历史,confirm。
  Future<void> _dropCommit(ProjectCfg p, GitCommit c) async {
    if (!await _confirm(
      'Drop commit?',
      '${c.shortHash} · ${c.subject}\n\n会从历史中移除该提交并重放其后代,改写历史。'
          '若有冲突会停在 rebase,可在操作条继续/中止。',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitDropCommit(p.path, c.hash);
      await _refreshGit();
      _snack('已 Drop ${c.shortHash}');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  /// Push All up to Here…:把到该 commit 为止的提交推到 origin 的同名分支。
  Future<void> _pushUpToCommit(ProjectCfg p, GitCommit c) async {
    if (!await _confirm(
      'Push up to here?',
      '${c.shortHash} · ${c.subject}\n\n会把到该提交为止的提交推送到 origin 当前分支。',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitPushUpTo(p.path, c.hash);
      await _refreshGit();
      _snack('已 push 到 ${c.shortHash}');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  /// New Tag…:在该 commit 打一个轻量标签。
  Future<void> _newTagAtCommit(ProjectCfg p, GitCommit c) async {
    final name = await textPrompt(
      context,
      title: 'New Tag',
      hint: '${c.shortHash} · ${c.subject}',
      okLabel: 'Create Tag',
    );
    if (name == null) return;
    if (!mounted) return;
    setState(() => _gitLoading = true);
    try {
      await gitTag(p.path, name, ref: c.hash);
      await _refreshGit();
      _snack('已创建标签 $name');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  /// Go to Parent Commit:选中第一个父提交(若已在加载的 log 里)。
  Future<void> _goToParent(ProjectCfg p, GitCommit c) async {
    if (c.parents.isEmpty) return;
    final parentHash = c.parents.first;
    final parent = _gitLog.where((x) => x.hash == parentHash).firstOrNull;
    if (parent == null) {
      _snack('父提交不在当前加载的列表里');
      return;
    }
    await _selectCommit(p, parent);
  }

  /// Open on GitHub:origin 的 web URL + `/commit/<hash>`,系统浏览器打开。
  Future<void> _openCommitOnGitHub(ProjectCfg p, GitCommit c) async {
    final base = await gitRemoteWebUrl(p.path);
    if (base == null) {
      if (mounted) _snack('没有 origin 远端');
      return;
    }
    await _openInBrowser('$base/commit/${c.hash}');
  }

  Future<void> _openInBrowser(String url) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url]);
      } else {
        await Process.run('xdg-open', [url]);
      }
    } catch (e) {
      if (mounted) _snack(errorText(e));
    }
  }

  // ---- 弹窗 ----

  /// Reset 模式三选一(自绘 radio 行,避开已弃用的 RadioListTile.groupValue)。
  /// 返回 soft/mixed/hard,取消 → null。
  Future<String?> _pickResetMode(GitCommit c) async {
    var mode = 'mixed';
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Widget row(String value, String label, {bool danger = false}) =>
              InkWell(
                onTap: () => setLocal(() => mode = value),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        mode == value
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 18,
                        color: mode == value
                            ? CcColors.accent
                            : CcColors.subtle,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: danger ? CcColors.danger : CcColors.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
          return AlertDialog(
            title: const Text('Reset Current Branch to Here'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${c.shortHash} · ${c.subject}',
                  style: CcType.code(size: 12, color: CcColors.muted),
                ),
                const SizedBox(height: 8),
                row('soft', 'Soft — 保留暂存区与工作区改动'),
                row('mixed', 'Mixed — 保留工作区改动,重置暂存区'),
                row('hard', 'Hard — 丢弃所有未提交改动(不可撤销)', danger: true),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, mode),
                child: const Text('Reset'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// commit message 多行小弹窗(reword 用)。取消或空 → null。
  Future<String?> _promptRewordMessage({
    required String title,
    String? hint,
    String? initial,
  }) async {
    final ctl = TextEditingController(text: initial ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: workspaceConfirmDialogWidth(size),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hint != null) ...[
                    SelectableText(
                      hint,
                      style: CcType.code(size: 12, color: CcColors.muted),
                    ),
                    const SizedBox(height: 8),
                  ],
                  TextField(
                    controller: ctl,
                    autofocus: true,
                    minLines: 2,
                    maxLines: 6,
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
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    final text = ctl.text.trim();
    ctl.dispose();
    if (ok != true) return null;
    return text;
  }
}
