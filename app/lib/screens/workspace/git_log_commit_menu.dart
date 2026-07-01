part of '../workspace_page.dart';

/// 底部 Git Log 中栏「commit 列表」的右键 / ⋮ 菜单(参考图2 的 JetBrains/GoLand
/// 风格)。从 `_WorkspacePageState` 抽出成独立 part,降合并冲突。
///
/// `on _GitMixin`:复用 git 状态字段 + 既有 git 操作;主类独有的 commit 视图方法
/// (`_copyCommitHash`/`_selectCommit`/`_cherryPickCommit`/…)按桥接模式声明为
/// abstract,由 `_WorkspacePageState` 提供。
mixin _GitLogCommitMenu on _GitMixin {
  // (Milestone 3 填充)
}
