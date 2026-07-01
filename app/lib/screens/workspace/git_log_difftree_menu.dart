part of '../workspace_page.dart';

/// 底部 Git Log 右栏「diff 文件树」的右键菜单(参考图3 的 JetBrains/GoLand 风格)。
/// 原本这栏完全没有右键,这里从零补齐。抽成独立 part 降合并冲突。
///
/// `on _GitMixin`:复用 git 状态字段 + 既有 git 操作;主类独有的视图方法
/// (`_openDiffTab`/`_openCodeFile`/…)按桥接模式声明为 abstract。
mixin _GitLogDiffTreeMenu on _GitMixin {
  // (Milestone 2 填充)
}
