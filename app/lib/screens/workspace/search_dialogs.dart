part of '../workspace_page.dart';

class _SearchHit {
  final String project;
  final String path;
  final String rel;
  final int line;
  final String text;

  const _SearchHit({
    required this.project,
    required this.path,
    required this.rel,
    required this.line,
    required this.text,
  });
}

class _SymbolHit {
  final String project;
  final String path;
  final String rel;
  final _CodeSymbol symbol;

  const _SymbolHit({
    required this.project,
    required this.path,
    required this.rel,
    required this.symbol,
  });

  int get line => symbol.line;
}

class _GoToSymbolDialog extends StatefulWidget {
  final List<WorkspaceCfg> workspaces;
  const _GoToSymbolDialog({required this.workspaces});

  @override
  State<_GoToSymbolDialog> createState() => _GoToSymbolDialogState();
}

class _GoToSymbolDialogState extends State<_GoToSymbolDialog> {
  final _ctl = TextEditingController();
  List<_SymbolHit> _symbols = const [];
  bool _loading = true;
  String _query = '';

  static const _symbolExts = {
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
    'md',
    'markdown',
  };

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final out = <_SymbolHit>[];
    for (final ws in widget.workspaces) {
      for (final p in ws.projects) {
        await _scanDir(Directory(p.path), p.path, p.name, out);
        if (out.length >= 2200) break;
      }
      if (out.length >= 2200) break;
    }
    out.sort((a, b) => a.symbol.name.compareTo(b.symbol.name));
    if (!mounted) return;
    setState(() {
      _symbols = out;
      _loading = false;
    });
  }

  Future<void> _scanDir(
    Directory dir,
    String root,
    String project,
    List<_SymbolHit> out,
  ) async {
    if (out.length >= 2200) return;
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      if (out.length >= 2200) return;
      final name = e.path.split('/').last;
      if (_searchSkipDirs.contains(name)) continue;
      if (e is Directory) {
        await _scanDir(e, root, project, out);
      } else if (e is File) {
        final ext = name.contains('.')
            ? name.split('.').last.toLowerCase()
            : '';
        if (!_symbolExts.contains(ext)) continue;
        String text;
        try {
          text = await e.readAsString();
        } catch (_) {
          continue;
        }
        final rel = e.path.startsWith('$root/')
            ? e.path.substring(root.length + 1)
            : e.path;
        for (final s in _extractCodeSymbols(e.path, text)) {
          out.add(
            _SymbolHit(project: project, path: e.path, rel: rel, symbol: s),
          );
          if (out.length >= 2200) return;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? _symbols.take(100).toList()
        : _symbols
              .where(
                (h) =>
                    h.symbol.name.toLowerCase().contains(q) ||
                    h.symbol.kind.toLowerCase().contains(q) ||
                    h.rel.toLowerCase().contains(q) ||
                    h.project.toLowerCase().contains(q),
              )
              .take(140)
              .toList();
    return Dialog(
      child: SizedBox(
        width: 760,
        height: 660,
        child: Column(
          children: [
            Container(
              height: 44,
              padding: const EdgeInsets.only(left: 14, right: 6),
              decoration: const BoxDecoration(
                color: CcColors.panel,
                border: Border(bottom: BorderSide(color: CcColors.border)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.data_object_rounded,
                    size: 18,
                    color: CcColors.muted,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Go to Symbol',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    '${_symbols.length}',
                    style: CcType.code(size: 11.5, color: CcColors.subtle),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: TextField(
                controller: _ctl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '输入 symbol / kind / path',
                  isDense: true,
                  prefixIcon: Icon(Icons.search_rounded, size: 18),
                ),
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) {
                  if (filtered.isNotEmpty) {
                    Navigator.pop(context, filtered.first);
                  }
                },
              ),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: filtered.isEmpty && !_loading
                  ? centerMsg('没有匹配 symbol')
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, color: CcColors.border),
                      itemBuilder: (_, i) {
                        final h = filtered[i];
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
                            '${h.project}/${h.rel}:${h.line}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CcType.code(
                              size: 10.8,
                              color: CcColors.subtle,
                            ),
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

List<_CodeSymbol> _extractCodeSymbols(String path, String text) {
  final ext = path.split('.').last.toLowerCase();
  final symbols = <_CodeSymbol>[];
  final lines = text.split('\n');
  final markdown = ext == 'md' || ext == 'markdown';

  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final trimmed = raw.trimLeft();
    if (trimmed.isEmpty) continue;
    if (!markdown &&
        (trimmed.startsWith('//') ||
            trimmed.startsWith('#') ||
            trimmed.startsWith('*'))) {
      continue;
    }
    final indent = raw.length - trimmed.length;
    _CodeSymbol? symbol;
    switch (ext) {
      case 'go':
        symbol = _goSymbol(trimmed, i + 1, indent);
      case 'dart':
        symbol = _dartLikeSymbol(trimmed, i + 1, indent);
      case 'js':
      case 'jsx':
      case 'ts':
      case 'tsx':
        symbol = _jsLikeSymbol(trimmed, i + 1, indent);
      case 'py':
        symbol = _pythonSymbol(trimmed, i + 1, indent);
      case 'java':
      case 'kt':
      case 'kts':
        symbol = _jvmSymbol(trimmed, i + 1, indent);
      case 'rs':
        symbol = _rustSymbol(trimmed, i + 1, indent);
      case 'md':
      case 'markdown':
        symbol = _markdownSymbol(trimmed, i + 1, indent);
      default:
        symbol = _genericSymbol(trimmed, i + 1, indent);
    }
    if (symbol != null) symbols.add(symbol);
    if (symbols.length >= 500) break;
  }
  return symbols;
}

// 符号解析正则:提为模块级 final,编译一次(原先在逐行循环里每行重建)。
final _reGoFunc = RegExp(
  r'^(?:func\s+\([^)]*\)\s*)?func\s+([A-Za-z_][\w]*)\s*\(',
);
final _reGoType = RegExp(r'^type\s+([A-Za-z_][\w]*)\s+(struct|interface)\b');
final _reDartType = RegExp(
  r'^(?:abstract\s+|base\s+|final\s+|sealed\s+|mixin\s+)*'
  r'(class|mixin|enum|extension)\s+([A-Za-z_][\w]*)',
);
final _reDartMethod = RegExp(
  r'^(?:static\s+)?(?:Future<[^>]+>|[\w<>?,\s]+)\s+'
  r'([A-Za-z_][\w]*)\s*\([^;]*\)\s*(?:async\s*)?[{=>]?',
);
final _reJsClass = RegExp(
  r'^(?:export\s+default\s+|export\s+)?class\s+([\w$]+)',
);
final _reJsFunc = RegExp(
  r'^(?:export\s+)?(?:async\s+)?function\s+([\w$]+)\s*\(',
);
final _reJsArrow = RegExp(
  r'^(?:export\s+)?(?:const|let|var)\s+([\w$]+)\s*=\s*(?:async\s*)?'
  r'(?:\([^)]*\)|[\w$]+)?\s*=>',
);
final _reJsMethod = RegExp(r'^([\w$]+)\s*\([^)]*\)\s*\{');
final _rePy = RegExp(r'^(class|def|async\s+def)\s+([A-Za-z_][\w]*)');
final _reJvmType = RegExp(
  r'^(?:[\w\s]+)?(class|interface|enum|object)\s+([\w$]+)',
);
final _reJvmMethod = RegExp(
  r'^(?:public|private|protected|internal|static|final|open|override|'
  r'suspend|fun|\s)+[\w<>\[\]?,\s.]*\s+([\w$]+)\s*\(',
);
final _reRust = RegExp(
  r'^(?:pub\s+)?(struct|enum|trait|impl|fn)\s+([A-Za-z_][\w]*)?',
);
final _reMd = RegExp(r'^(#{1,6})\s+(.+)$');
final _reGeneric = RegExp(
  r'^(?:class|interface|enum|func|function|def)\s+([A-Za-z_][\w]*)',
);

_CodeSymbol? _goSymbol(String line, int lineNo, int indent) {
  var m = _reGoFunc.firstMatch(line);
  if (m != null) {
    return _symbol(m.group(1)!, 'func', lineNo, indent, Icons.functions);
  }
  m = _reGoType.firstMatch(line);
  if (m != null) {
    final kind = m.group(2)!;
    return _symbol(
      m.group(1)!,
      kind,
      lineNo,
      indent,
      kind == 'interface' ? Icons.hub_outlined : Icons.data_object_rounded,
    );
  }
  return null;
}

_CodeSymbol? _dartLikeSymbol(String line, int lineNo, int indent) {
  var m = _reDartType.firstMatch(line);
  if (m != null) {
    return _symbol(m.group(2)!, m.group(1)!, lineNo, indent, Icons.category);
  }
  m = _reDartMethod.firstMatch(line);
  if (m != null && !_controlWords.contains(m.group(1))) {
    return _symbol(m.group(1)!, 'method', lineNo, indent, Icons.functions);
  }
  return null;
}

_CodeSymbol? _jsLikeSymbol(String line, int lineNo, int indent) {
  var m = _reJsClass.firstMatch(line);
  if (m != null) {
    return _symbol(m.group(1)!, 'class', lineNo, indent, Icons.category);
  }
  m = _reJsFunc.firstMatch(line);
  if (m != null) {
    return _symbol(m.group(1)!, 'function', lineNo, indent, Icons.functions);
  }
  m = _reJsArrow.firstMatch(line);
  if (m != null) {
    return _symbol(m.group(1)!, 'function', lineNo, indent, Icons.functions);
  }
  m = _reJsMethod.firstMatch(line);
  if (m != null && !_controlWords.contains(m.group(1))) {
    return _symbol(m.group(1)!, 'method', lineNo, indent, Icons.functions);
  }
  return null;
}

_CodeSymbol? _pythonSymbol(String line, int lineNo, int indent) {
  final m = _rePy.firstMatch(line);
  if (m == null) return null;
  final kind = m.group(1)!.replaceAll('async ', '');
  return _symbol(
    m.group(2)!,
    kind,
    lineNo,
    indent,
    kind == 'class' ? Icons.category : Icons.functions,
  );
}

_CodeSymbol? _jvmSymbol(String line, int lineNo, int indent) {
  var m = _reJvmType.firstMatch(line);
  if (m != null) {
    return _symbol(m.group(2)!, m.group(1)!, lineNo, indent, Icons.category);
  }
  m = _reJvmMethod.firstMatch(line);
  if (m != null && !_controlWords.contains(m.group(1))) {
    return _symbol(m.group(1)!, 'method', lineNo, indent, Icons.functions);
  }
  return null;
}

_CodeSymbol? _rustSymbol(String line, int lineNo, int indent) {
  final m = _reRust.firstMatch(line);
  if (m == null) return null;
  final kind = m.group(1)!;
  final name = m.group(2) ?? 'impl';
  return _symbol(
    name,
    kind,
    lineNo,
    indent,
    kind == 'fn' ? Icons.functions : Icons.category,
  );
}

_CodeSymbol? _markdownSymbol(String line, int lineNo, int indent) {
  final m = _reMd.firstMatch(line);
  if (m == null) return null;
  return _symbol(
    m.group(2)!.trim(),
    'h${m.group(1)!.length}',
    lineNo,
    indent + (m.group(1)!.length - 1) * 2,
    Icons.notes_rounded,
  );
}

_CodeSymbol? _genericSymbol(String line, int lineNo, int indent) {
  final m = _reGeneric.firstMatch(line);
  if (m == null) return null;
  return _symbol(m.group(1)!, 'symbol', lineNo, indent, Icons.account_tree);
}

_CodeSymbol _symbol(
  String name,
  String kind,
  int line,
  int indent,
  IconData icon,
) =>
    _CodeSymbol(name: name, kind: kind, line: line, indent: indent, icon: icon);

const _controlWords = {
  'if',
  'for',
  'while',
  'switch',
  'catch',
  'return',
  'else',
};

class _FindInFilesDialog extends StatefulWidget {
  final List<WorkspaceCfg> workspaces;
  const _FindInFilesDialog({required this.workspaces});

  @override
  State<_FindInFilesDialog> createState() => _FindInFilesDialogState();
}

class _FindInFilesDialogState extends State<_FindInFilesDialog> {
  final _ctl = TextEditingController();
  List<_SearchHit> _hits = const [];
  bool _loading = false;
  String _query = '';
  String? _error;
  int _searchId = 0;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _search(String value) async {
    final query = value.trim();
    final id = ++_searchId;
    setState(() {
      _query = query;
      _error = null;
      _hits = const [];
      _loading = query.length >= 2;
    });
    if (query.length < 2) return;
    try {
      final out = <_SearchHit>[];
      for (final ws in widget.workspaces) {
        for (final p in ws.projects) {
          await _searchDir(Directory(p.path), p.path, p.name, query, out);
          if (out.length >= 300 || id != _searchId) break;
        }
        if (out.length >= 300 || id != _searchId) break;
      }
      if (!mounted || id != _searchId) return;
      setState(() {
        _hits = out;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _searchId) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  Future<void> _searchDir(
    Directory dir,
    String root,
    String project,
    String query,
    List<_SearchHit> out,
  ) async {
    if (out.length >= 300) return;
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      if (out.length >= 300) return;
      final name = e.path.split('/').last;
      if (_searchSkipDirs.contains(name)) continue;
      if (e is Directory) {
        await _searchDir(e, root, project, query, out);
      } else if (e is File) {
        await _searchFile(e, root, project, query, out);
      }
    }
  }

  Future<void> _searchFile(
    File file,
    String root,
    String project,
    String query,
    List<_SearchHit> out,
  ) async {
    if (out.length >= 300) return;
    final name = file.path.split('/').last;
    if (_looksBinaryOrHuge(file, name)) return;
    String content;
    try {
      content = await file.readAsString();
    } catch (_) {
      return;
    }
    final lower = query.toLowerCase();
    final rel = file.path.startsWith('$root/')
        ? file.path.substring(root.length + 1)
        : file.path;
    final lines = content.split('\n');
    for (var i = 0; i < lines.length && out.length < 300; i++) {
      final line = lines[i];
      if (!line.toLowerCase().contains(lower)) continue;
      out.add(
        _SearchHit(
          project: project,
          path: file.path,
          rel: rel,
          line: i + 1,
          text: line.trim(),
        ),
      );
    }
  }

  bool _looksBinaryOrHuge(File file, String name) {
    try {
      if (file.lengthSync() > 700 * 1024) return true;
    } catch (_) {
      return true;
    }
    final ext = name.split('.').last.toLowerCase();
    const binary = {
      'png',
      'jpg',
      'jpeg',
      'gif',
      'webp',
      'ico',
      'pdf',
      'zip',
      'gz',
      'tar',
      'jar',
      'class',
      'so',
      'dylib',
      'a',
      'o',
      'mp4',
      'mov',
      'mp3',
    };
    return binary.contains(ext);
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 860,
      height: 680,
      child: Column(
        children: [
          Container(
            height: 42,
            padding: const EdgeInsets.only(left: 14, right: 6),
            decoration: const BoxDecoration(
              color: CcColors.panel,
              border: Border(bottom: BorderSide(color: CcColors.border)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.search_rounded,
                  size: 17,
                  color: CcColors.muted,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Find in Files',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (_hits.isNotEmpty)
                  Text(
                    '${_hits.length} results',
                    style: CcType.code(size: 11.5, color: CcColors.subtle),
                  ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: TextField(
              controller: _ctl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search text in project files',
                isDense: true,
                prefixIcon: Icon(Icons.search_rounded, size: 18),
              ),
              onChanged: _search,
              onSubmitted: (_) {
                if (_hits.isNotEmpty) Navigator.pop(context, _hits.first);
              },
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _error != null
                ? centerMsg(_error!, onRetry: () => _search(_query))
                : _query.length < 2
                ? centerMsg('输入至少 2 个字符开始搜索')
                : !_loading && _hits.isEmpty
                ? centerMsg('没有匹配结果')
                : ListView.separated(
                    itemCount: _hits.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: CcColors.border),
                    itemBuilder: (_, i) {
                      final h = _hits[i];
                      return ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.manage_search_rounded,
                          size: 18,
                          color: CcColors.muted,
                        ),
                        title: Text(
                          h.text.isEmpty ? ' ' : h.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CcType.code(size: 12.5),
                        ),
                        subtitle: Text(
                          '${h.project}/${h.rel}:${h.line}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CcType.code(size: 11, color: CcColors.subtle),
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

class _FindUsagesDialog extends StatefulWidget {
  final List<WorkspaceCfg> workspaces;
  final String sourcePath;
  final List<_CodeSymbol> symbols;

  const _FindUsagesDialog({
    required this.workspaces,
    required this.sourcePath,
    required this.symbols,
  });

  @override
  State<_FindUsagesDialog> createState() => _FindUsagesDialogState();
}

class _FindUsagesDialogState extends State<_FindUsagesDialog> {
  _CodeSymbol? _symbol;
  List<_SearchHit> _hits = const [];
  bool _loading = false;
  String? _error;
  int _searchId = 0;

  @override
  void initState() {
    super.initState();
    _symbol = widget.symbols.firstOrNull;
    final initial = _symbol;
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search(initial));
    }
  }

  Future<void> _search(_CodeSymbol symbol) async {
    final id = ++_searchId;
    setState(() {
      _symbol = symbol;
      _hits = const [];
      _error = null;
      _loading = true;
    });
    try {
      final out = <_SearchHit>[];
      for (final ws in widget.workspaces) {
        for (final p in ws.projects) {
          await _searchDir(Directory(p.path), p.path, p.name, symbol.name, out);
          if (out.length >= 300 || id != _searchId) break;
        }
        if (out.length >= 300 || id != _searchId) break;
      }
      if (!mounted || id != _searchId) return;
      setState(() {
        _hits = out;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _searchId) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  Future<void> _searchDir(
    Directory dir,
    String root,
    String project,
    String symbolName,
    List<_SearchHit> out,
  ) async {
    if (out.length >= 300) return;
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      if (out.length >= 300) return;
      final entryName = e.path.split('/').last;
      if (_searchSkipDirs.contains(entryName)) continue;
      if (e is Directory) {
        await _searchDir(e, root, project, symbolName, out);
      } else if (e is File) {
        await _searchFile(e, root, project, symbolName, out);
      }
    }
  }

  Future<void> _searchFile(
    File file,
    String root,
    String project,
    String symbolName,
    List<_SearchHit> out,
  ) async {
    if (out.length >= 300) return;
    final name = file.path.split('/').last;
    if (_looksBinaryOrHuge(file, name)) return;
    String content;
    try {
      content = await file.readAsString();
    } catch (_) {
      return;
    }
    final rel = file.path.startsWith('$root/')
        ? file.path.substring(root.length + 1)
        : file.path;
    final lines = content.split('\n');
    for (var i = 0; i < lines.length && out.length < 300; i++) {
      final line = lines[i];
      if (!_lineContainsIdentifier(line, symbolName)) continue;
      out.add(
        _SearchHit(
          project: project,
          path: file.path,
          rel: rel,
          line: i + 1,
          text: line.trim(),
        ),
      );
    }
  }

  bool _lineContainsIdentifier(String line, String name) {
    var start = 0;
    while (true) {
      final index = line.indexOf(name, start);
      if (index < 0) return false;
      final before = index == 0 ? null : line.codeUnitAt(index - 1);
      final afterIndex = index + name.length;
      final after = afterIndex >= line.length
          ? null
          : line.codeUnitAt(afterIndex);
      if (!_isIdentifierCode(before) && !_isIdentifierCode(after)) return true;
      start = index + name.length;
    }
  }

  bool _isIdentifierCode(int? code) {
    if (code == null) return false;
    return code == 95 ||
        (code >= 48 && code <= 57) ||
        (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122);
  }

  bool _looksBinaryOrHuge(File file, String name) {
    try {
      if (file.lengthSync() > 700 * 1024) return true;
    } catch (_) {
      return true;
    }
    final ext = name.split('.').last.toLowerCase();
    const binary = {
      'png',
      'jpg',
      'jpeg',
      'gif',
      'webp',
      'ico',
      'pdf',
      'zip',
      'gz',
      'tar',
      'jar',
      'class',
      'so',
      'dylib',
      'a',
      'o',
      'mp4',
      'mov',
      'mp3',
    };
    return binary.contains(ext);
  }

  @override
  Widget build(BuildContext context) {
    final symbol = _symbol;
    return Dialog(
      child: SizedBox(
        width: 940,
        height: 680,
        child: Column(
          children: [
            Container(
              height: 42,
              padding: const EdgeInsets.only(left: 14, right: 6),
              decoration: const BoxDecoration(
                color: CcColors.panel,
                border: Border(bottom: BorderSide(color: CcColors.border)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.travel_explore_rounded,
                    size: 17,
                    color: CcColors.muted,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Find Usages',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (symbol != null)
                    Text(
                      '${symbol.name} · ${_hits.length} results',
                      style: CcType.code(size: 11.5, color: CcColors.subtle),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 280,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        color: CcColors.panel,
                        border: Border(
                          right: BorderSide(color: CcColors.border),
                        ),
                      ),
                      child: ListView.separated(
                        itemCount: widget.symbols.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, color: CcColors.border),
                        itemBuilder: (_, i) {
                          final s = widget.symbols[i];
                          final selected = s == symbol;
                          return Material(
                            color: selected
                                ? CcColors.accent.withValues(alpha: 0.10)
                                : Colors.transparent,
                            child: ListTile(
                              dense: true,
                              leading: Icon(
                                s.icon,
                                size: 17,
                                color: selected
                                    ? CcColors.accentBright
                                    : CcColors.muted,
                              ),
                              title: Text(
                                s.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CcType.code(size: 12.5),
                              ),
                              subtitle: Text(
                                '${s.kind} · line ${s.line}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CcType.code(
                                  size: 10.8,
                                  color: CcColors.subtle,
                                ),
                              ),
                              onTap: () => _search(s),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Container(
                          height: 36,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: const BoxDecoration(
                            color: CcColors.editor,
                            border: Border(
                              bottom: BorderSide(color: CcColors.border),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  symbol == null
                                      ? widget.sourcePath
                                      : '${symbol.kind} ${symbol.name}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: CcType.code(
                                    size: 11.5,
                                    color: CcColors.muted,
                                  ),
                                ),
                              ),
                              if (_loading)
                                const SizedBox(
                                  width: 110,
                                  child: LinearProgressIndicator(minHeight: 2),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: _error != null
                              ? centerMsg(
                                  _error!,
                                  onRetry: symbol == null
                                      ? null
                                      : () => _search(symbol),
                                )
                              : symbol == null
                              ? centerMsg('选择一个符号')
                              : !_loading && _hits.isEmpty
                              ? centerMsg('没有找到引用')
                              : ListView.separated(
                                  itemCount: _hits.length,
                                  separatorBuilder: (_, _) => const Divider(
                                    height: 1,
                                    color: CcColors.border,
                                  ),
                                  itemBuilder: (_, i) {
                                    final h = _hits[i];
                                    final isDeclaration =
                                        h.path == widget.sourcePath &&
                                        h.line == symbol.line;
                                    return ListTile(
                                      dense: true,
                                      leading: Icon(
                                        isDeclaration
                                            ? Icons.flag_rounded
                                            : Icons.manage_search_rounded,
                                        size: 18,
                                        color: isDeclaration
                                            ? CcColors.accentBright
                                            : CcColors.muted,
                                      ),
                                      title: Text(
                                        h.text.isEmpty ? ' ' : h.text,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: CcType.code(size: 12.5),
                                      ),
                                      subtitle: Text(
                                        '${h.project}/${h.rel}:${h.line}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: CcType.code(
                                          size: 11,
                                          color: CcColors.subtle,
                                        ),
                                      ),
                                      trailing: isDeclaration
                                          ? tag('declaration', CcColors.ok)
                                          : null,
                                      onTap: () => Navigator.pop(context, h),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileLineHit {
  final int line;
  final String text;

  const _FileLineHit({required this.line, required this.text});
}

class _FileStructureDialog extends StatefulWidget {
  final String path;
  final List<_CodeSymbol> symbols;
  const _FileStructureDialog({required this.path, required this.symbols});

  @override
  State<_FileStructureDialog> createState() => _FileStructureDialogState();
}

class _FileStructureDialogState extends State<_FileStructureDialog> {
  final _ctl = TextEditingController();
  String _query = '';

  List<_CodeSymbol> get _filtered {
    final q = _query.toLowerCase();
    if (q.isEmpty) return widget.symbols;
    return widget.symbols
        .where(
          (s) =>
              s.name.toLowerCase().contains(q) ||
              s.kind.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.path.split('/').last;
    final symbols = _filtered;
    return Dialog(
      child: SizedBox(
        width: 680,
        height: 620,
        child: Column(
          children: [
            Container(
              height: 42,
              padding: const EdgeInsets.only(left: 14, right: 6),
              decoration: const BoxDecoration(
                color: CcColors.panel,
                border: Border(bottom: BorderSide(color: CcColors.border)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.account_tree_rounded,
                    size: 17,
                    color: CcColors.muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'File Structure · $name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    '${symbols.length}/${widget.symbols.length}',
                    style: CcType.code(size: 11.5, color: CcColors.subtle),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: TextField(
                controller: _ctl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search symbols',
                  isDense: true,
                  prefixIcon: Icon(Icons.filter_list_rounded, size: 18),
                ),
                onChanged: (v) => setState(() => _query = v.trim()),
                onSubmitted: (_) {
                  if (symbols.isNotEmpty) Navigator.pop(context, symbols.first);
                },
              ),
            ),
            Expanded(
              child: symbols.isEmpty
                  ? centerMsg('没有匹配符号')
                  : ListView.separated(
                      itemCount: symbols.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, color: CcColors.border),
                      itemBuilder: (_, i) {
                        final s = symbols[i];
                        final level = (s.indent ~/ 2).clamp(0, 8).toDouble();
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.only(
                            left: 14 + level * 14,
                            right: 12,
                          ),
                          leading: Icon(
                            s.icon,
                            size: 18,
                            color: CcColors.accentBright,
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  s.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: CcType.code(size: 12.5),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                s.kind,
                                style: CcType.code(
                                  size: 10.5,
                                  color: CcColors.subtle,
                                ),
                              ),
                            ],
                          ),
                          trailing: Text(
                            '${s.line}',
                            style: CcType.code(
                              size: 11,
                              color: CcColors.subtle,
                            ),
                          ),
                          onTap: () => Navigator.pop(context, s),
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

class _FindInCurrentFileDialog extends StatefulWidget {
  final String path;
  final String text;
  const _FindInCurrentFileDialog({required this.path, required this.text});

  @override
  State<_FindInCurrentFileDialog> createState() =>
      _FindInCurrentFileDialogState();
}

class _FindInCurrentFileDialogState extends State<_FindInCurrentFileDialog> {
  final _ctl = TextEditingController();
  List<_FileLineHit> _hits = const [];
  String _query = '';

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _search(String value) {
    final query = value.trim();
    final out = <_FileLineHit>[];
    if (query.isNotEmpty) {
      final lower = query.toLowerCase();
      final lines = widget.text.split('\n');
      for (var i = 0; i < lines.length && out.length < 300; i++) {
        final line = lines[i];
        if (!line.toLowerCase().contains(lower)) continue;
        out.add(_FileLineHit(line: i + 1, text: line.trim()));
      }
    }
    setState(() {
      _query = query;
      _hits = out;
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.path.split('/').last;
    return Dialog(
      child: SizedBox(
        width: 760,
        height: 560,
        child: Column(
          children: [
            Container(
              height: 42,
              padding: const EdgeInsets.only(left: 14, right: 6),
              decoration: const BoxDecoration(
                color: CcColors.panel,
                border: Border(bottom: BorderSide(color: CcColors.border)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.search_rounded,
                    size: 17,
                    color: CcColors.muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Find in File · $name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (_hits.isNotEmpty)
                    Text(
                      '${_hits.length} matches',
                      style: CcType.code(size: 11.5, color: CcColors.subtle),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: TextField(
                controller: _ctl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search in current file',
                  isDense: true,
                  prefixIcon: Icon(Icons.search_rounded, size: 18),
                ),
                onChanged: _search,
                onSubmitted: (_) {
                  if (_hits.isNotEmpty) {
                    Navigator.pop(context, _hits.first.line);
                  }
                },
              ),
            ),
            Expanded(
              child: _query.isEmpty
                  ? centerMsg('输入内容查找当前文件')
                  : _hits.isEmpty
                  ? centerMsg('没有匹配结果')
                  : ListView.separated(
                      itemCount: _hits.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, color: CcColors.border),
                      itemBuilder: (_, i) {
                        final h = _hits[i];
                        return ListTile(
                          dense: true,
                          leading: Text(
                            '${h.line}',
                            textAlign: TextAlign.right,
                            style: CcType.code(
                              size: 11,
                              color: CcColors.subtle,
                            ),
                          ),
                          title: Text(
                            h.text.isEmpty ? ' ' : h.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CcType.code(size: 12.5),
                          ),
                          onTap: () => Navigator.pop(context, h.line),
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
