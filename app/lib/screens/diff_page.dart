import 'package:flutter/material.dart';

import '../local/git.dart';
import '../local/repo_config.dart';
import '../widgets.dart';

// DiffPage shows a project/worktree's git diff with a toggle between uncommitted
// changes (working tree vs HEAD) and the branch vs its base ref (.cc-handoff.toml
// paths.base, default origin/main). Rendered in-app via diffText.
class DiffPage extends StatefulWidget {
  final String path;
  final String name;
  const DiffPage({super.key, required this.path, required this.name});

  @override
  State<DiffPage> createState() => _DiffPageState();
}

class _DiffPageState extends State<DiffPage> {
  int _mode = 0; // 0 = uncommitted, 1 = vs base
  String _base = 'origin/main';
  String? _diff;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _resolveBase().then((_) => _load());
  }

  Future<void> _resolveBase() async {
    final cfg = await RepoConfig.load(widget.path);
    final b = cfg.base.trim();
    if (mounted && b.isNotEmpty) setState(() => _base = b);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final diff = _mode == 0
          ? await gitDiffWorking(widget.path)
          : await gitDiffBase(widget.path, _base);
      if (!mounted) return;
      setState(() {
        _diff = diff;
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

  void _setMode(int m) {
    if (m == _mode) return;
    setState(() => _mode = m);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('变动 · ${widget.name}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: '刷新',
                onPressed: _load),
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

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return centerMsg(_error!, onRetry: _load);
    final d = _diff ?? '';
    if (d.trim().isEmpty) {
      return centerMsg(_mode == 0 ? '没有未提交改动' : '与 $_base 无差异');
    }
    return DecoratedBox(decoration: appGradient, child: diffText(d));
  }
}
