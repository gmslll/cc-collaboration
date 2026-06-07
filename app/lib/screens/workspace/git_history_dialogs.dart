part of '../workspace_page.dart';

class _BlameDialog extends StatefulWidget {
  final ProjectCfg project;
  final String relPath;
  const _BlameDialog({required this.project, required this.relPath});

  @override
  State<_BlameDialog> createState() => _BlameDialogState();
}

class _BlameDialogState extends State<_BlameDialog> {
  List<GitBlameLine> _lines = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lines = await gitBlame(widget.project.path, widget.relPath);
      if (!mounted) return;
      setState(() {
        _lines = lines;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 980,
      height: 720,
      child: Column(
        children: [
          _DialogHeader(
            icon: Icons.person_search_rounded,
            title: 'Annotate · ${widget.relPath}',
            trailing: [
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 18),
                tooltip: '刷新',
                onPressed: _load,
              ),
            ],
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _error != null
                ? centerMsg(_error!, onRetry: _load)
                : _lines.isEmpty && !_loading
                ? centerMsg('没有 blame 信息')
                : ListView.builder(
                    itemCount: _lines.length,
                    itemBuilder: (_, i) {
                      final l = _lines[i];
                      final date = l.date.millisecondsSinceEpoch == 0
                          ? ''
                          : relativeTime(l.date);
                      return Container(
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: CcColors.border,
                              width: 0.5,
                            ),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 58,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 5),
                                child: Text(
                                  '${l.line}',
                                  textAlign: TextAlign.right,
                                  style: CcType.code(
                                    size: 11,
                                    color: CcColors.subtle,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 220,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${l.hash.substring(0, 8)} · ${l.author}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: CcType.code(
                                        size: 11.5,
                                        color: CcColors.muted,
                                      ),
                                    ),
                                    Text(
                                      date.isEmpty
                                          ? l.summary
                                          : '$date · ${l.summary}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: CcColors.subtle,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  10,
                                  5,
                                  10,
                                  5,
                                ),
                                child: Text(
                                  l.content.isEmpty ? ' ' : l.content,
                                  style: CcType.code(size: 12.5),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}

class _FileHistoryDialog extends StatefulWidget {
  final ProjectCfg project;
  final String relPath;
  const _FileHistoryDialog({required this.project, required this.relPath});

  @override
  State<_FileHistoryDialog> createState() => _FileHistoryDialogState();
}

class _FileHistoryDialogState extends State<_FileHistoryDialog> {
  List<GitCommit> _commits = const [];
  List<FileDiff> _files = const [];
  String? _selectedHash;
  String? _error;
  String? _diffError;
  bool _loading = true;
  bool _diffLoading = false;

  GitCommit? get _selectedCommit {
    final hash = _selectedHash;
    if (hash == null) return null;
    return _commits.where((c) => c.hash == hash).firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _diffError = null;
      _files = const [];
      _selectedHash = null;
    });
    try {
      final commits = await gitLogFile(widget.project.path, widget.relPath);
      if (!mounted) return;
      setState(() {
        _commits = commits;
        _loading = false;
      });
      if (commits.isNotEmpty) {
        await _selectCommit(commits.first);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  Future<void> _selectCommit(GitCommit c) async {
    setState(() {
      _selectedHash = c.hash;
      _diffLoading = true;
      _diffError = null;
      _files = const [];
    });
    try {
      final diff = await gitShowCommitFile(
        widget.project.path,
        c.hash,
        widget.relPath,
      );
      final files = parseUnifiedDiff(diff);
      if (!mounted || _selectedHash != c.hash) return;
      setState(() {
        _files = files;
        _diffLoading = false;
      });
    } catch (e) {
      if (!mounted || _selectedHash != c.hash) return;
      setState(() {
        _diffError = errorText(e);
        _diffLoading = false;
      });
    }
  }

  void _copySelectedHash() {
    final commit = _selectedCommit;
    if (commit == null) return;
    Clipboard.setData(ClipboardData(text: commit.hash));
    snack(context, '已复制 ${commit.shortHash}');
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 1080,
      height: 740,
      child: Column(
        children: [
          _DialogHeader(
            icon: Icons.history_rounded,
            title: 'File History · ${widget.relPath}',
            trailing: [
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 18),
                tooltip: '刷新',
                onPressed: _loading ? null : _load,
              ),
            ],
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: 360,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(color: CcColors.panel),
                    child: _historyList(),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _historyDiff()),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _historyList() {
    if (_error != null) return centerMsg(_error!, onRetry: _load);
    if (_commits.isEmpty && !_loading) return centerMsg('没有文件历史');
    return ListView.separated(
      itemCount: _commits.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final c = _commits[i];
        final sel = c.hash == _selectedHash;
        final age = c.date.millisecondsSinceEpoch == 0
            ? ''
            : relativeTime(c.date);
        return Container(
          color: sel
              ? CcColors.accent.withValues(alpha: 0.10)
              : Colors.transparent,
          child: ListTile(
            dense: true,
            selected: sel,
            leading: Icon(
              Icons.commit_rounded,
              size: 17,
              color: sel ? CcColors.accentBright : CcColors.muted,
            ),
            title: Text(
              c.subject,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                [c.shortHash, c.author, if (age.isNotEmpty) age].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.code(size: 11, color: CcColors.subtle),
              ),
            ),
            trailing: c.refs.isEmpty
                ? null
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 86),
                    child: tag(
                      c.refs.replaceAll('HEAD -> ', '').split(',').first.trim(),
                      CcColors.accent,
                    ),
                  ),
            onTap: _diffLoading && sel ? null : () => _selectCommit(c),
          ),
        );
      },
    );
  }

  Widget _historyDiff() {
    final commit = _selectedCommit;
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.only(left: 12, right: 6),
          decoration: const BoxDecoration(
            color: CcColors.editorTabBar,
            border: Border(bottom: BorderSide(color: CcColors.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: commit == null
                    ? const Text(
                        '选择 commit 查看文件 diff',
                        style: TextStyle(fontSize: 12.5),
                      )
                    : Text(
                        '${commit.shortHash} · ${commit.subject}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
              IconButton(
                icon: const Icon(Icons.copy_rounded, size: 17),
                tooltip: 'Copy Hash',
                visualDensity: VisualDensity.compact,
                onPressed: commit == null ? null : _copySelectedHash,
              ),
            ],
          ),
        ),
        if (_diffLoading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _diffError != null
              ? centerMsg(_diffError!)
              : _files.isEmpty && !_diffLoading
              ? centerMsg(
                  commit == null ? '选择 commit 查看文件 diff' : '该提交没有文件 diff',
                )
              : DiffView(files: _files),
        ),
      ],
    );
  }
}
