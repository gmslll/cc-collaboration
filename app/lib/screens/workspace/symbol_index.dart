part of '../workspace_page.dart';

/// Go-to-definition (阶段一:正则打底) —— 从 `_WorkspacePageState` 抽出的符号索引 +
/// 跳转逻辑。复用 `_extractCodeSymbols` 的多语言正则,把工作区里所有定义扫成
/// `name → 定义位置` 的缓存;点标识符(Cmd/Ctrl+左键)或按键(F12 / Cmd/Ctrl+B)时
/// 查表跳到定义,多处定义弹 `_GoToDefinitionDialog` 消歧。缓存字段留在本 mixin
/// (不进主类字段块),失效点挂在 `_refreshFileTrees`。
///
/// 阶段二(后续 loop)在同一 `_openCodeFile` 落点后接 LSP(gopls/dart)提精度,正则
/// 只作回退。mixin → 主类的桥接方法在下方声明为 abstract,由宿主类实现。
mixin _SymbolIndex on State<WorkspacePage> {
  // ---- 由宿主类 (_WorkspacePageState) 提供:mixin → 主类 的桥接 ----
  void _snack(String s);
  AppConfig get _cfg;
  void _openCodeFile(String path, {int? line});
  List<_OpenFile> get _codeFiles;
  int get _activeFile;

  // name → 定义位置。懒建、缓存,直到文件树刷新/新建/删除时失效重建。
  // null = 尚未构建;_symbolBuild 非空 = 正在构建(合并并发请求)。
  Map<String, List<_SymbolHit>>? _symbolDefs;
  Future<Map<String, List<_SymbolHit>>>? _symbolBuild;

  // 索引规模上限:符号解析是纯内存操作,但要读遍工作区文件,给个硬顶避免超大
  // monorepo 卡住首次跳转。够覆盖常规工程。
  static const _symbolIndexCap = 8000;

  void _invalidateSymbolIndex() {
    _symbolDefs = null;
    _symbolBuild = null;
  }

  Future<Map<String, List<_SymbolHit>>> _ensureSymbolIndex() {
    final done = _symbolDefs;
    if (done != null) return Future.value(done);
    return _symbolBuild ??= _buildSymbolIndex();
  }

  Future<Map<String, List<_SymbolHit>>> _buildSymbolIndex() async {
    final map = <String, List<_SymbolHit>>{};
    var count = 0;
    for (final ws in _cfg.workspaces) {
      for (final p in ws.projects) {
        count = await _indexDir(Directory(p.path), p.path, p.name, map, count);
        if (count >= _symbolIndexCap) break;
      }
      if (count >= _symbolIndexCap) break;
    }
    _symbolDefs = map;
    _symbolBuild = null;
    return map;
  }

  Future<int> _indexDir(
    Directory dir,
    String root,
    String project,
    Map<String, List<_SymbolHit>> map,
    int count,
  ) async {
    if (count >= _symbolIndexCap) return count;
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      return count;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      if (count >= _symbolIndexCap) return count;
      final name = pathBaseName(e.path);
      if (_searchSkipDirs.contains(name)) continue;
      if (e is Directory) {
        count = await _indexDir(e, root, project, map, count);
      } else if (e is File) {
        final ext = name.contains('.')
            ? name.split('.').last.toLowerCase()
            : '';
        if (!_symbolIndexExts.contains(ext)) continue;
        String text;
        try {
          if (await e.length() > 700 * 1024) continue;
          text = await e.readAsString();
        } catch (_) {
          continue;
        }
        final rel = pathRelativeTo(root, e.path);
        for (final s in _extractCodeSymbols(e.path, text)) {
          (map[s.name] ??= []).add(
            _SymbolHit(project: project, path: e.path, rel: rel, symbol: s),
          );
          if (++count >= _symbolIndexCap) return count;
        }
      }
    }
    return count;
  }

  // _goToDefinition is the F12 / Cmd(Ctrl)+B entry: resolve the identifier under
  // the active editor's caret to its definition(s) and jump / disambiguate.
  Future<void> _goToDefinition() async {
    final loc = _activeCodeEditor();
    if (loc == null) {
      _snack('把光标放到代码标识符上再跳转');
      return;
    }
    final ident = loc.state.identifierAtCursor;
    if (ident == null) {
      _snack('光标不在标识符上');
      return;
    }
    await _goToDefinitionOf(ident, fromPath: loc.path, fromLine: loc.caretLine);
  }

  // _activeCodeEditor returns the mounted editor state of the active code tab
  // (null when the active tab is a diff / nothing is open / editor not ready).
  ({CodeEditorPaneState state, String path, int? caretLine})?
  _activeCodeEditor() {
    if (_activeFile < 0 || _activeFile >= _codeFiles.length) return null;
    final f = _codeFiles[_activeFile];
    if (f.isDiff) return null;
    final state = f.key.currentState;
    if (state == null) return null;
    return (state: state, path: f.path, caretLine: state.caretLine);
  }

  // _goToDefinitionOf looks [name] up in the symbol index and navigates. When
  // the caret already sits on a definition of [name], that site is dropped so
  // the jump targets the *other* definitions (and, if there are none, says so).
  Future<void> _goToDefinitionOf(
    String name, {
    String? fromPath,
    int? fromLine,
  }) async {
    final index = await _ensureSymbolIndex();
    if (!mounted) return;
    final hits = index[name];
    if (hits == null || hits.isEmpty) {
      _snack('未找到定义: $name');
      return;
    }
    final onSelf = (fromPath != null && fromLine != null)
        ? hits.where((h) => h.path == fromPath && h.symbol.line == fromLine)
        : const Iterable<_SymbolHit>.empty();
    final candidates = hits
        .where((h) => !(h.path == fromPath && h.symbol.line == fromLine))
        .toList();
    if (candidates.isEmpty) {
      // Caret is on the sole definition — nowhere else to jump.
      if (onSelf.isNotEmpty) {
        _snack('已在 $name 的定义处 · Cmd/Ctrl+Alt+F7 查看引用');
      }
      return;
    }
    if (candidates.length == 1) {
      final h = candidates.first;
      _openCodeFile(h.path, line: h.symbol.line);
      return;
    }
    final picked = await showDialog<_SymbolHit>(
      context: context,
      builder: (_) => _GoToDefinitionDialog(name: name, hits: candidates),
    );
    if (picked != null) _openCodeFile(picked.path, line: picked.symbol.line);
  }
}

// Extensions the go-to-definition regex index scans. Code definitions only —
// markdown headings (indexed elsewhere for Go to Symbol) aren't jump targets.
const _symbolIndexExts = {
  'go',
  'dart',
  'js',
  'jsx',
  'ts',
  'tsx',
  'py',
  'java',
  'kt',
  'kts',
  'rs',
};

// _GoToDefinitionDialog is the disambiguation picker shown when an identifier
// resolves to more than one definition site (regex over-match, overloads, or a
// name reused across files). Tapping a row returns its _SymbolHit to navigate.
class _GoToDefinitionDialog extends StatelessWidget {
  final String name;
  final List<_SymbolHit> hits;
  const _GoToDefinitionDialog({required this.name, required this.hits});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 720,
        height: (hits.length * 56 + 120).clamp(220, 620).toDouble(),
        child: Column(
          children: [
            _DialogHeader(
              icon: Icons.my_location_rounded,
              title: 'Go to Definition · $name',
              trailing: [
                Text(
                  '${hits.length} 处定义',
                  style: CcType.code(size: 11.5, color: CcColors.subtle),
                ),
              ],
            ),
            Expanded(
              child: ListView.separated(
                itemCount: hits.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: CcColors.border),
                itemBuilder: (_, i) {
                  final h = hits[i];
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      h.symbol.icon,
                      size: 16,
                      color: CcColors.accentBright,
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            h.symbol.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CcType.code(size: 12.5),
                          ),
                        ),
                        const SizedBox(width: 8),
                        tag(h.symbol.kind, CcColors.accent),
                      ],
                    ),
                    subtitle: Text(
                      '${h.project}/${h.rel}:${h.symbol.line}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CcType.code(size: 10.8, color: CcColors.subtle),
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
}
