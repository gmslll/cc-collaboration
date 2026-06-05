import 'package:flutter/material.dart';

import '../api/github_client.dart';
import '../local/config.dart';
import '../theme.dart';
import '../widgets.dart';

// GitHubPrPage lists a project's open PRs (parsed from its github URL) and opens
// a PR's changed files + diffs. The token comes from config.toml github_token
// (set in 账号 → 本地配置).
class GitHubPrPage extends StatefulWidget {
  final String githubUrl;
  final String name;
  const GitHubPrPage({super.key, required this.githubUrl, required this.name});

  @override
  State<GitHubPrPage> createState() => _GitHubPrPageState();
}

class _GitHubPrPageState extends State<GitHubPrPage> {
  GitHubClient? _client;
  String? _slug;
  List<PullRequest>? _pulls;
  String? _error;
  bool _loading = true;

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
    final slug = GitHubClient.parseSlug(widget.githubUrl);
    if (slug == null) {
      setState(() {
        _error = '无法从 ${widget.githubUrl} 解析 GitHub 仓库';
        _loading = false;
      });
      return;
    }
    final token = (await AppConfig.load())?.githubToken ?? '';
    if (token.isEmpty) {
      setState(() {
        _error = '未设置 GitHub token —— 去「账号 → 本地配置」填 github_token';
        _loading = false;
      });
      return;
    }
    _slug = slug;
    _client = GitHubClient(token);
    try {
      final p = await _client!.listPulls(slug);
      if (!mounted) return;
      setState(() {
        _pulls = p;
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('GitHub PR · ${widget.name}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: '刷新',
                onPressed: _load),
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return centerMsg(_error!, onRetry: _load);
    final pulls = _pulls ?? const [];
    if (pulls.isEmpty) return centerMsg('没有 open PR');
    return DecoratedBox(
      decoration: appGradient,
      child: ListView.separated(
        itemCount: pulls.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final pr = pulls[i];
          return ListTile(
            leading: tag('#${pr.number}',
                pr.draft ? CcColors.subtle : CcColors.accent),
            title: Text(pr.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
                '${pr.author} · ${pr.headRef} → ${pr.baseRef}${pr.draft ? ' · draft' : ''}',
                style: const TextStyle(color: CcColors.muted, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right_rounded,
                color: CcColors.subtle),
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        _PrDiffPage(client: _client!, slug: _slug!, pr: pr))),
          );
        },
      ),
    );
  }
}

// _PrDiffPage shows one PR's changed files, each expandable to its diff.
class _PrDiffPage extends StatefulWidget {
  final GitHubClient client;
  final String slug;
  final PullRequest pr;
  const _PrDiffPage(
      {required this.client, required this.slug, required this.pr});

  @override
  State<_PrDiffPage> createState() => _PrDiffPageState();
}

class _PrDiffPageState extends State<_PrDiffPage> {
  List<PrFile>? _files;
  String? _error;
  bool _loading = true;

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
      final f = await widget.client.pullFiles(widget.slug, widget.pr.number);
      if (!mounted) return;
      setState(() {
        _files = f;
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text('#${widget.pr.number}  ${widget.pr.title}',
              maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return centerMsg(_error!, onRetry: _load);
    final files = _files ?? const [];
    if (files.isEmpty) return centerMsg('没有文件改动');
    return DecoratedBox(
      decoration: appGradient,
      child: ListView.builder(
        itemCount: files.length,
        itemBuilder: (_, i) {
          final f = files[i];
          return Theme(
            data: Theme.of(context)
                .copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              initiallyExpanded: files.length <= 3,
              tilePadding: const EdgeInsets.symmetric(horizontal: 12),
              title: Text(f.filename,
                  style:
                      const TextStyle(fontFamily: CcType.mono, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              subtitle: Text('${f.status} · +${f.additions} −${f.deletions}',
                  style: const TextStyle(color: CcColors.muted, fontSize: 11.5)),
              children: [
                if (f.patch.trim().isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(12),
                      child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text('(无 diff —— 二进制或过大)',
                              style: TextStyle(color: CcColors.subtle))))
                else
                  ColoredBox(
                      color: CcColors.bg,
                      child: diffText(f.patch, scrollable: false)),
              ],
            ),
          );
        },
      ),
    );
  }
}
