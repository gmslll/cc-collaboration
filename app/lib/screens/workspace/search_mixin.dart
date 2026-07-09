part of '../workspace_page.dart';

/// 搜索/导航对话框启动器(从 `_WorkspacePageState` 抽出)。只读共享状态、
/// 不写布局字段;mixin → 主类的调用在下方声明为 abstract。
mixin _SearchMixin on State<WorkspacePage> {
  // ---- 由宿主类 (_WorkspacePageState) 提供:mixin → 主类 的桥接 ----
  void _snack(String s);
  AppConfig get _cfg;
  ({WorkspaceCfg ws, ProjectCfg project})? _defaultProject();
  void _openCodeFile(String path, {int? line});
  List<_OpenFile> get _codeFiles;
  int get _activeFile;

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
    if (!mounted) return;
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
    if (!mounted) return;
    if (hit != null) _openCodeFile(hit.path, line: hit.line);
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
    if (!mounted) return;
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
    if (!mounted) return;
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
    if (!mounted) return;
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
    if (!mounted) return;
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
    if (!mounted) return;
    if (hit != null) _openCodeFile(hit.path, line: hit.line);
  }
}
