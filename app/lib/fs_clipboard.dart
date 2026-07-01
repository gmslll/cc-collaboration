import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:pasteboard/pasteboard.dart';

import 'local/path_utils.dart';

// 文件级剪贴板：把文件/目录写进系统剪贴板、读回来、复制/移动进目标目录，
// 外加一个 [FsClipboardActions] mixin 把两棵文件树共享的复制/剪切/粘贴/拖入
// UI 胶水收成一份（各屏只注入"选中项 / 提示 / 写盘后刷新"三处差异）。
//
// 复用现有的 pasteboard 依赖（其 files()/writeFiles() 在 macOS 走 NSPasteboard.general，
// 因此与访达的复制/粘贴双向互通）。仅桌面平台可用；其它平台上 pasteboard 会抛错，
// 这里统一吞成空结果/无操作。

/// 剪切意图。Cut 记下这批源路径；Paste 时若系统剪贴板里的文件与之完全一致，
/// 说明是"应用内剪切→粘贴"，执行移动；否则（含访达里复制来的文件）执行复制。
class FsClipboard {
  static Set<String> _cut = {};

  /// 复制：清掉剪切意图 → 后续粘贴为复制。
  static void markCopied() => _cut = {};

  /// 剪切：记下这批路径 → 下次粘贴同一批文件时移动。
  static void markCut(List<String> paths) => _cut = paths.toSet();

  /// 剪贴板里的 [files] 是否正好是刚"剪切"的那一批（据此决定移动 vs 复制）。
  static bool isMoveFor(List<String> files) =>
      files.isNotEmpty &&
      _cut.length == files.length &&
      _cut.containsAll(files);

  /// 移动完成后清空剪切意图（同一批不会被再次移动）。
  static void clearAfterMove() => _cut = {};
}

/// 把一批文件/目录写进系统剪贴板（访达随后可 Cmd+V 粘出）。
Future<void> writeFilesToClipboard(List<String> paths) async {
  if (paths.isEmpty) return;
  try {
    await Pasteboard.writeFiles(paths);
  } catch (_) {
    // 非桌面平台无实现，忽略。
  }
}

/// 读回系统剪贴板里的文件路径（含访达里复制的文件）。
Future<List<String>> readFilesFromClipboard() async {
  try {
    return await Pasteboard.files();
  } catch (_) {
    return const [];
  }
}

bool _exists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

/// 在 [targetDir] 里为 [name] 找一个空闲路径：foo.txt → foo-1.txt → foo-2.txt …
/// 文件与目录都算占用。镜像 remote/file_fs_io.dart 的 _dedupePath，但同时判目录。
String dedupeChildPath(String targetDir, String name) {
  var candidate = pathJoin(targetDir, name);
  if (!_exists(candidate)) return candidate;
  final dot = name.lastIndexOf('.');
  // 前导点（隐藏文件如 .env）不当作扩展名分隔符。
  final hasExt = dot > 0;
  final stem = hasExt ? name.substring(0, dot) : name;
  final ext = hasExt ? name.substring(dot) : '';
  for (var i = 1; i < 10000; i++) {
    candidate = pathJoin(targetDir, '$stem-$i$ext');
    if (!_exists(candidate)) return candidate;
  }
  return pathJoin(
    targetDir,
    '$stem-${DateTime.now().millisecondsSinceEpoch}$ext',
  );
}

/// 递归复制单个已知类型的实体到 [dest]（[dest] 的父目录须已存在）。类型由调用方
/// 传入以避免对同一路径重复 stat；支持文件/目录/符号链接。
Future<void> _copyEntity(
  String src,
  String dest,
  FileSystemEntityType type,
) async {
  if (type == FileSystemEntityType.directory) {
    await Directory(dest).create(recursive: true);
    await for (final e in Directory(src).list(followLinks: false)) {
      await _copyEntity(
        e.path,
        pathJoin(dest, pathBaseName(e.path)),
        FileSystemEntity.typeSync(e.path, followLinks: false),
      );
    }
  } else if (type == FileSystemEntityType.link) {
    await Link(dest).create(await Link(src).target());
  } else {
    await File(src).copy(dest);
  }
}

/// 把一批源路径导入 [targetDir]：同名自动改名；[move] 为真时移动（同盘 rename，
/// 跨盘复制后删源），否则复制。每个源只 stat 一次。返回真正写入的目标路径
/// ([written]，用于刷新/选中) 和被跳过的说明 ([skipped]，已格式化为"名称：原因")。
Future<({List<String> written, List<String> skipped})> importPathsInto(
  List<String> srcPaths,
  String targetDir, {
  bool move = false,
}) async {
  final written = <String>[];
  final skipped = <String>[];
  for (final src in srcPaths) {
    final type = FileSystemEntity.typeSync(src, followLinks: false);
    final name = pathBaseName(src);
    if (type == FileSystemEntityType.notFound) {
      skipped.add('$name：源不存在');
      continue;
    }
    if (name.isEmpty) continue;
    final isDir = type == FileSystemEntityType.directory;
    // 自嵌套保护：不能把目录复制/移动进它自身或其子目录。
    if (isDir && pathWithin(targetDir, src)) {
      skipped.add('$name：不能把文件夹放进它自身');
      continue;
    }
    final dest = dedupeChildPath(targetDir, name);
    try {
      if (move) {
        try {
          // 同盘直接 rename（快且保留 inode）。
          await (isDir ? Directory(src).rename(dest) : File(src).rename(dest));
        } on FileSystemException {
          // 跨盘：复制后删源。
          await _copyEntity(src, dest, type);
          if (isDir) {
            await Directory(src).delete(recursive: true);
          } else {
            await File(src).delete();
          }
        }
      } else {
        await _copyEntity(src, dest, type);
      }
      written.add(dest);
    } catch (e) {
      skipped.add('$name：$e');
    }
  }
  return (written: written, skipped: skipped);
}

/// 两棵文件树共享的剪贴板/拖入行为。屏幕 State `with FsClipboardActions`，只需
/// 实现三个注入点，四个操作 + 键盘绑定就都来自这里，保证两处行为永远一致。
mixin FsClipboardActions<T extends StatefulWidget> on State<T> {
  /// 当前选中的树节点绝对路径（无选中返回 null）。
  String? get fsSelectedPath;

  /// 弹一条提示（实现方负责 mounted 守卫）。
  void fsNotify(String msg);

  /// 写盘成功后刷新树/git，并把 [firstPath] 设为选中。
  Future<void> fsOnWritten(String firstPath);

  Future<void> fsCopy(List<String> paths) async {
    if (paths.isEmpty) return;
    await writeFilesToClipboard(paths);
    FsClipboard.markCopied();
    fsNotify('已复制到剪贴板');
  }

  Future<void> fsCut(List<String> paths) async {
    if (paths.isEmpty) return;
    await writeFilesToClipboard(paths);
    FsClipboard.markCut(paths);
    fsNotify('已剪切');
  }

  /// 把系统剪贴板里的文件粘进 [targetDir]。剪切意图命中则移动，否则复制。
  Future<void> fsPaste(String targetDir) async {
    final files = await readFilesFromClipboard();
    if (files.isEmpty) {
      fsNotify('剪贴板里没有文件');
      return;
    }
    final move = FsClipboard.isMoveFor(files);
    final (:written, :skipped) = await importPathsInto(
      files,
      targetDir,
      move: move,
    );
    if (move) FsClipboard.clearAfterMove();
    if (written.isNotEmpty) await fsOnWritten(written.first);
    if (skipped.isNotEmpty) {
      fsNotify('部分未粘贴：${skipped.join('；')}');
    } else {
      fsNotify(move ? '已移动 ${written.length} 项' : '已粘贴 ${written.length} 项');
    }
  }

  /// 从访达把文件拖到某目录行上：复制进该目录（外部来源恒为复制）。
  Future<void> fsDrop(String targetDir, List<String> paths) async {
    if (paths.isEmpty) return;
    final (:written, :skipped) = await importPathsInto(paths, targetDir);
    if (written.isNotEmpty) await fsOnWritten(written.first);
    if (skipped.isNotEmpty) {
      fsNotify('部分未拖入：${skipped.join('；')}');
    } else if (written.isNotEmpty) {
      fsNotify('已拖入 ${written.length} 项');
    }
  }

  void _fsRun(String action) {
    final sel = fsSelectedPath;
    if (sel == null) {
      fsNotify('先选中一个文件');
      return;
    }
    switch (action) {
      case 'copy':
        fsCopy([sel]);
      case 'cut':
        fsCut([sel]);
      case 'paste':
        // 目标目录：选中目录用它自身，选中文件用其父目录。
        fsPaste(FileSystemEntity.isDirectorySync(sel) ? sel : pathDirName(sel));
    }
  }

  /// 文件树聚焦时的 Cmd/Ctrl+C/X/V 绑定。建一次即可（读选中项在触发时才发生），
  /// 避免每帧、每棵树重复分配 map + 闭包。
  late final Map<ShortcutActivator, VoidCallback> fsShortcuts = {
    for (final e in {
      LogicalKeyboardKey.keyC: 'copy',
      LogicalKeyboardKey.keyX: 'cut',
      LogicalKeyboardKey.keyV: 'paste',
    }.entries) ...{
      SingleActivator(e.key, meta: true): () => _fsRun(e.value),
      SingleActivator(e.key, control: true): () => _fsRun(e.value),
    },
  };
}
