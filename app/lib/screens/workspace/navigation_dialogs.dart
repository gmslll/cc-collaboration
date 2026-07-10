part of '../workspace_page.dart';

double workspaceNavigationDialogDimension(
  double available,
  double preferred, {
  double min = 280,
}) {
  if (!available.isFinite || available <= 0) return preferred;
  if (available < min) return available;
  return available < preferred ? available : preferred;
}

Size workspaceQuickOpenDialogSize(
  Size viewport, {
  double preferredWidth = 680,
  double preferredHeight = 620,
}) => Size(
  workspaceNavigationDialogDimension(viewport.width - 32, preferredWidth),
  workspaceNavigationDialogDimension(
    viewport.height - 48,
    preferredHeight,
    min: 260,
  ),
);

double workspaceGoToLineDialogWidth(Size viewport, {double preferred = 420}) =>
    workspaceNavigationDialogDimension(viewport.width - 32, preferred);

class _QuickOpenDialog extends StatefulWidget {
  final List<WorkspaceCfg> workspaces;
  const _QuickOpenDialog({required this.workspaces});

  @override
  State<_QuickOpenDialog> createState() => _QuickOpenDialogState();
}

class _QuickOpenDialogState extends State<_QuickOpenDialog> {
  final _ctl = TextEditingController();
  List<({String label, String path})> _files = const [];
  bool _loading = true;
  String _query = '';

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
    final out = <({String label, String path})>[];
    for (final ws in widget.workspaces) {
      for (final p in ws.projects) {
        await _scanDir(Directory(p.path), p.path, p.name, out);
        if (out.length >= 1600) break;
      }
      if (out.length >= 1600) break;
    }
    out.sort((a, b) => a.label.compareTo(b.label));
    if (mounted) {
      setState(() {
        _files = out;
        _loading = false;
      });
    }
  }

  Future<void> _scanDir(
    Directory dir,
    String root,
    String project,
    List<({String label, String path})> out,
  ) async {
    if (out.length >= 1600) return;
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      if (out.length >= 1600) return;
      final name = pathBaseName(e.path);
      if (_searchSkipDirs.contains(name)) continue;
      if (e is Directory) {
        await _scanDir(e, root, project, out);
      } else if (e is File) {
        final rel = pathRelativeTo(root, e.path);
        out.add((label: '$project/$rel', path: e.path));
      }
    }
  }

  ({String query, int? line}) _parseQuery(String raw) {
    final trimmed = raw.trim();
    final match = RegExp(r'^(.*):(\d+)$').firstMatch(trimmed);
    if (match == null) return (query: trimmed, line: null);
    return (query: match.group(1)!.trim(), line: int.tryParse(match.group(2)!));
  }

  void _openMatch(({String label, String path}) file, int? line) {
    Navigator.pop(context, _CodeLocation(file.path, line: line));
  }

  @override
  Widget build(BuildContext context) {
    final dialogSize = workspaceQuickOpenDialogSize(MediaQuery.sizeOf(context));
    final parsed = _parseQuery(_query);
    final q = parsed.query.toLowerCase();
    final filtered = q.isEmpty
        ? _files.take(80).toList()
        : _files
              .where((f) => f.label.toLowerCase().contains(q))
              .take(120)
              .toList();
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        width: dialogSize.width,
        height: dialogSize.height,
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
                    Icons.search_rounded,
                    size: 18,
                    color: CcColors.muted,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '快速打开文件',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
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
                  hintText: '输入文件名、路径或 file:line',
                  isDense: true,
                  prefixIcon: Icon(Icons.search_rounded, size: 18),
                ),
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) {
                  if (filtered.isNotEmpty) {
                    _openMatch(filtered.first, parsed.line);
                  }
                },
              ),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: filtered.isEmpty && !_loading
                  ? centerMsg('没有匹配文件')
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final f = filtered[i];
                        return ListTile(
                          dense: true,
                          leading: const Icon(
                            Icons.insert_drive_file_outlined,
                            size: 16,
                            color: CcColors.muted,
                          ),
                          title: Text(
                            f.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CcType.code(size: 12.5),
                          ),
                          trailing: parsed.line == null
                              ? null
                              : tag('line ${parsed.line}', CcColors.accent),
                          onTap: () => _openMatch(f, parsed.line),
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

class _GoToLineDialog extends StatefulWidget {
  final String fileName;
  final int lineCount;
  final int? initialLine;
  const _GoToLineDialog({
    required this.fileName,
    required this.lineCount,
    this.initialLine,
  });

  @override
  State<_GoToLineDialog> createState() => _GoToLineDialogState();
}

class _GoToLineDialogState extends State<_GoToLineDialog> {
  late final TextEditingController _ctl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: '${widget.initialLine ?? ''}');
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() {
    final line = int.tryParse(_ctl.text.trim());
    if (line == null || line < 1 || line > widget.lineCount) {
      setState(() => _error = '请输入 1-${widget.lineCount} 之间的行号');
      return;
    }
    Navigator.pop(context, line);
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: workspaceGoToLineDialogWidth(MediaQuery.sizeOf(context)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DialogHeader(
            icon: Icons.format_list_numbered_rounded,
            title: 'Go to Line · ${widget.fileName}',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _ctl,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Line number',
                    hintText: '1-${widget.lineCount}',
                    errorText: _error,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      '${widget.lineCount} lines',
                      style: CcType.code(size: 11.5, color: CcColors.subtle),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _submit, child: const Text('Go')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
