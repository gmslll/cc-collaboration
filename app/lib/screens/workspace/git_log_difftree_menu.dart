part of '../workspace_page.dart';

/// 底部 Git Log 右栏「diff 文件树」的右键菜单(参考图3 的 JetBrains/GoLand 风格)。
/// 原本这栏完全没有右键,这里从零补齐。抽成独立 part 降合并冲突。
///
/// 上下文:右栏展示的是「某个 commit」或「某次 compare」的改动文件。当前修订取
/// `_selectedCommit`(commit 视图 / commit↔工作区比较时有值;纯分支 compare 时为
/// null,依赖修订的项禁用)。项目取 `_currentGitProject`,故不必把 `p` 透传进
/// 视图构建器,workspace_page.dart 里只需给文件行挂一个 onSecondaryTapDown。
///
/// `on _GitMixin, _SearchMixin`:git 状态/操作来自 `_GitMixin`,`_openCodeFile`
/// 来自 `_SearchMixin`;主类独有的 `_openDiffTab`/`_showFileHistoryForProjectFile`
/// 按桥接模式声明为 abstract。
mixin _GitLogDiffTreeMenu on _GitMixin, _SearchMixin {
  // ---- 主类 (_WorkspacePageState) 提供的视图桥接 ----
  void _openDiffTab(
    List<FileDiff> diffs,
    String title, {
    String? initialPath,
    Future<List<FileDiff>> Function(int context)? reload,
  });
  void _showFileHistoryForProjectFile(ProjectCfg project, String relPath);

  /// 右键 diff 文件树里的一个文件。[f] 是被点的文件,[all]/[title]/[reload] 是当前
  /// 整组 diff 的上下文(供 Show Diff 复用中央 diff 视图)。
  Future<void> _showDiffTreeMenu(
    Offset pos,
    FileDiff f,
    List<FileDiff> all,
    String title,
    Future<List<FileDiff>> Function(int context)? reload,
  ) async {
    final p = _currentGitProject;
    if (p == null) return;
    final hash = _selectedCommit; // null = 纯分支 compare 视图
    final hasRev = hash != null && hash.isNotEmpty;
    final v = await showMenu<String>(
      context: context,
      position: menuPosAt(context, pos),
      items: [
        ccMenuItem(
          value: 'diff',
          icon: Icons.difference_rounded,
          label: 'Show Diff',
          shortcut: '⌘D',
        ),
        ccMenuItem(
          value: 'diffTab',
          icon: Icons.open_in_new_rounded,
          label: 'Show Diff in a New Tab',
        ),
        ccMenuItem(
          value: 'cmpLocal',
          icon: Icons.compare_arrows_rounded,
          label: 'Compare with Local',
          enabled: hasRev,
        ),
        ccMenuItem(
          value: 'cmpBeforeLocal',
          icon: Icons.compare_rounded,
          label: 'Compare Before with Local',
          enabled: hasRev,
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'edit',
          icon: Icons.edit_outlined,
          label: 'Edit Source',
          shortcut: '⌘↓',
        ),
        ccMenuItem(
          value: 'repoVer',
          icon: Icons.history_toggle_off_rounded,
          label: 'Open Repository Version',
          enabled: hasRev,
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'revert',
          icon: Icons.undo_rounded,
          label: 'Revert Selected Changes',
          danger: true,
        ),
        ccMenuItem(
          value: 'pick',
          icon: Icons.content_paste_rounded,
          label: 'Cherry-Pick Selected Changes',
        ),
        ccMenuItem(
          value: 'patch',
          icon: Icons.note_add_outlined,
          label: 'Create Patch…',
        ),
        const PopupMenuDivider(),
        ccMenuItem(
          value: 'getRev',
          icon: Icons.download_rounded,
          label: 'Get from Revision',
          enabled: hasRev,
          danger: true,
        ),
        ccMenuItem(
          value: 'history',
          icon: Icons.history_rounded,
          label: 'History Up to Here',
        ),
        ccMenuItem(
          value: 'changesToParents',
          icon: Icons.account_tree_outlined,
          label: 'Show Changes to Parents',
        ),
      ],
    );
    if (v == null || !mounted) return;
    switch (v) {
      case 'diff':
        _openDiffTab(all, title, initialPath: f.path, reload: reload);
      case 'diffTab':
        _openDiffTab(
          [f],
          'Diff · ${f.path}${hasRev ? ' @${_revShort(hash)}' : ''}',
          initialPath: f.path,
        );
      case 'cmpLocal':
        await _compareFileRefWithLocal(p, hash!, f, before: false);
      case 'cmpBeforeLocal':
        await _compareFileRefWithLocal(p, hash!, f, before: true);
      case 'edit':
        _openCodeFile('${p.path}/${f.path}');
      case 'repoVer':
        await _openRepositoryVersion(p, hash!, f);
      case 'revert':
        await _applyFileDiffPatch(p, f, reverse: true);
      case 'pick':
        await _applyFileDiffPatch(p, f, reverse: false);
      case 'patch':
        await _createPatchFromFileDiff(f);
      case 'getRev':
        await _getFileFromRevision(p, hash!, f);
      case 'history':
        _showFileHistoryForProjectFile(p, f.path);
      case 'changesToParents':
        _openDiffTab(
          [f],
          'Changes to parents · ${f.path}',
          initialPath: f.path,
        );
    }
  }

  // ---- 落地操作 ----

  /// Compare (Before) with Local:把该文件在 [hash](before → 其父 `hash^`)的版本
  /// 与工作区当前版本比较,结果打进中央 diff 视图。复用 gitDiffRefToWorking(整仓
  /// commit↔工作区)后按路径筛出这一个文件。
  Future<void> _compareFileRefWithLocal(
    ProjectCfg p,
    String hash,
    FileDiff f, {
    required bool before,
  }) async {
    final ref = before ? '$hash^' : hash;
    try {
      final diff = await gitDiffRefToWorking(p.path, ref);
      final files = parseUnifiedDiff(diff);
      final one = files.where((x) => x.path == f.path).toList();
      if (!mounted) return;
      _openDiffTab(
        one.isEmpty ? files : one,
        '${before ? 'Before ' : ''}${_revShort(hash)}..Local · ${f.path}',
        initialPath: f.path,
      );
    } catch (e) {
      if (mounted) _snack(errorText(e));
    }
  }

  /// Open Repository Version:以该修订下这个文件的完整内容(全上下文 diff)打开一个
  /// 视图,近似 JetBrains 的「查看该修订版本的文件」。
  Future<void> _openRepositoryVersion(
    ProjectCfg p,
    String hash,
    FileDiff f,
  ) async {
    try {
      final diff = await gitShowCommitFile(p.path, hash, f.path, context: 999999);
      final files = parseUnifiedDiff(diff);
      if (!mounted) return;
      if (files.isEmpty) {
        _snack('该修订下没有此文件的改动内容');
        return;
      }
      _openDiffTab(
        files,
        'Repo @${_revShort(hash)} · ${f.path}',
        initialPath: f.path,
      );
    } catch (e) {
      if (mounted) _snack(errorText(e));
    }
  }

  /// Revert(reverse) / Cherry-Pick(forward) Selected Changes:把这个文件在该
  /// commit 引入的改动,正向/反向应用到工作区(git apply [-R])。用 FileDiff.raw
  /// 里的整-file patch,commit 视图与 compare 视图都适用。
  Future<void> _applyFileDiffPatch(
    ProjectCfg p,
    FileDiff f, {
    required bool reverse,
  }) async {
    if (f.raw.trim().isEmpty) {
      _snack('没有可应用的改动');
      return;
    }
    if (reverse &&
        !await _confirm(
          'Revert selected changes?',
          '${f.path}\n\n会在工作区反向应用该文件的改动(git apply -R)。',
        )) {
      return;
    }
    if (_gitLoading) return;
    setState(() => _gitLoading = true);
    try {
      await gitApplyPatch(p.path, f.raw, reverse: reverse);
      await _refreshGit();
      _snack(reverse ? '已 Revert ${f.path}' : '已 Cherry-Pick ${f.path}');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  /// Create Patch…:把这个文件的改动(FileDiff.raw)导出成 .patch 文件。
  Future<void> _createPatchFromFileDiff(FileDiff f) async {
    if (f.raw.trim().isEmpty) {
      _snack('没有可导出的改动');
      return;
    }
    try {
      final saved = await writePatchToPickedFile(
        f.raw,
        '${f.path.split('/').last}.patch',
      );
      if (saved != null && mounted) _snack('已保存 patch: $saved');
    } catch (e) {
      if (mounted) _snack(errorText(e));
    }
  }

  /// Get from Revision:用该修订的版本覆盖工作区文件(丢弃当前改动)。破坏性,confirm。
  Future<void> _getFileFromRevision(
    ProjectCfg p,
    String hash,
    FileDiff f,
  ) async {
    if (!await _confirm(
      'Get from revision?',
      '${f.path}\n\n会用修订 ${_revShort(hash)} 的版本覆盖工作区文件'
          '(git checkout ${_revShort(hash)} -- file),丢弃当前改动。',
    )) {
      return;
    }
    if (_gitLoading) return;
    setState(() => _gitLoading = true);
    try {
      await gitCheckoutPathAtRev(p.path, hash, f.path);
      await _refreshGit();
      _snack('已从 ${_revShort(hash)} 取回 ${f.path}');
    } catch (e) {
      if (mounted) {
        setState(() => _gitLoading = false);
        _snack(errorText(e));
      }
    }
  }

  String _revShort(String h) => h.length <= 10 ? h : h.substring(0, 10);
}

/// 把 patch 内容存到用户选的 .patch 文件,返回保存的文件名(取消 → null)。补 `.patch`
/// 后缀、规整末尾换行。中栏(commit format-patch)与右栏(单文件 diff)的 Create Patch
/// 共用(同一 library 的 part,顶层函数彼此可见)。
Future<String?> writePatchToPickedFile(String patch, String suggestedName) async {
  final dest = await FilePicker.platform.saveFile(
    dialogTitle: 'Create Patch',
    fileName: suggestedName,
  );
  if (dest == null) return null;
  final out = dest.endsWith('.patch') ? dest : '$dest.patch';
  await File(out).writeAsString(patch.endsWith('\n') ? patch : '$patch\n');
  return out.split('/').last;
}
