import 'package:flutter/material.dart';

import '../local/diff_parse.dart';
import '../local/git.dart';
import '../local/repo_config.dart';
import '../widgets.dart';
import 'diff_view.dart';

// DiffPage shows a project/worktree's git diff with a toggle between uncommitted
// changes (working tree vs HEAD) and the branch vs its base ref (.cc-handoff.toml
// paths.base, default origin/main). Rendered GoLand-style via DiffView (changed
// files tree + side-by-side / unified).
class DiffPage extends StatefulWidget {
  final String path;
  final String name;
  final Future<String> Function(String path)? loadBaseRef;
  final Future<String> Function(String path, {int context})? loadWorkingDiff;
  final Future<String> Function(String path, String base, {int context})?
  loadBaseDiff;
  const DiffPage({
    super.key,
    required this.path,
    required this.name,
    this.loadBaseRef,
    this.loadWorkingDiff,
    this.loadBaseDiff,
  });

  @override
  State<DiffPage> createState() => _DiffPageState();
}

class _DiffPageState extends State<DiffPage> {
  int _mode = 0; // 0 = uncommitted, 1 = vs base
  String _base = 'origin/main';
  List<FileDiff> _files = const [];
  String? _error;
  bool _loading = true;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _resolveBase().then((_) => _load());
  }

  Future<void> _resolveBase() async {
    final b =
        (widget.loadBaseRef == null
                ? (await RepoConfig.load(widget.path)).base
                : await widget.loadBaseRef!(widget.path))
            .trim();
    if (mounted && b.isNotEmpty) setState(() => _base = b);
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final mode = _mode;
    final path = widget.path;
    final base = _base;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final diff = mode == 0
          ? await _loadWorking(path)
          : await _loadBase(path, base);
      if (!_isCurrentLoad(generation)) return;
      setState(() {
        _files = parseUnifiedDiff(diff);
        _loading = false;
      });
    } catch (e) {
      if (!_isCurrentLoad(generation)) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  bool _isCurrentLoad(int generation) =>
      mounted && generation == _loadGeneration;

  Future<String> _loadWorking(String path, {int context = 3}) =>
      widget.loadWorkingDiff?.call(path, context: context) ??
      gitDiffWorking(path, context: context);

  Future<String> _loadBase(String path, String base, {int context = 3}) =>
      widget.loadBaseDiff?.call(path, base, context: context) ??
      gitDiffBase(path, base, context: context);

  void _setMode(int m) {
    if (m == _mode) return;
    setState(() => _mode = m);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '变动 · ${widget.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: '刷新',
              onPressed: _load,
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<int>(
                segments: [
                  const ButtonSegment(value: 0, label: Text('未提交')),
                  ButtonSegment(value: 1, label: Text('vs $_base')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => _setMode(s.first),
                showSelectedIcon: false,
              ),
            ),
          ),
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() => asyncBody(
    loading: _loading,
    error: _error,
    onRetry: _load,
    child: () => _files.isEmpty
        ? centerMsg(_mode == 0 ? '没有未提交改动' : '与 $_base 无差异')
        // edit/discard only in uncommitted mode — there the new side IS the
        // working file, so line numbers + git checkout/apply line up.
        : DiffView(
            files: _files,
            editRoot: _mode == 0 ? widget.path : null,
            onChanged: _load,
            onReloadContext: (ctx) async => parseUnifiedDiff(
              await (_mode == 0
                  ? _loadWorking(widget.path, context: ctx)
                  : _loadBase(widget.path, _base, context: ctx)),
            ),
          ),
  );
}
