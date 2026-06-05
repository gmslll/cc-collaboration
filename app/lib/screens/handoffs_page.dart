import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../api/sse.dart';
import '../local/cli.dart';
import '../local/config.dart';
import '../theme.dart';
import '../widgets.dart';
import 'terminal_pane.dart';

// HandoffsPage is the cockpit: inbox → 对接文档 → pickup → embedded agent
// terminal. Desktop-focused (the terminal is desktop-only); on mobile the
// pickup/terminal simply aren't shown by the shell.
class HandoffsPage extends StatefulWidget {
  final RelayClient client;
  final AppConfig config;
  final bool showTerminal;
  const HandoffsPage({
    super.key,
    required this.client,
    required this.config,
    this.showTerminal = true,
  });

  @override
  State<HandoffsPage> createState() => _HandoffsPageState();
}

class _HandoffsPageState extends State<HandoffsPage> {
  String? _error;
  bool _loading = true;
  List<ListItem> _inbox = const [];
  ListItem? _selected;
  Package? _pkg;
  bool _detailLoading = false;
  bool _picking = false;
  String? _termWorkdir;
  String? _termCommand;
  List<Comment> _comments = const [];
  final _commentCtl = TextEditingController();
  StreamSubscription<SseEvent>? _sse;

  RelayClient get _client => widget.client;
  AppConfig get _cfg => widget.config;

  @override
  void initState() {
    super.initState();
    _refresh();
    _sse = subscribeEvents(_cfg.relayUrl, _cfg.token, _cfg.identity)
        .listen(_onSse, onError: (_) {});
  }

  @override
  void dispose() {
    _sse?.cancel();
    _commentCtl.dispose();
    super.dispose();
  }

  void _onSse(SseEvent ev) {
    switch (ev.type) {
      case 'handoff.created':
      case 'handoff.retracted':
        _refresh();
      case 'comment.created':
        if (_selected != null) {
          try {
            final m = jsonDecode(ev.data) as Map<String, dynamic>;
            if ((m['handoff_id'] ?? '').toString() == _selected!.id) {
              _loadComments(_selected!.id);
            }
          } catch (_) {}
        }
    }
  }

  Future<void> _loadComments(String id) async {
    try {
      final cs = await _client.comments(id);
      if (mounted && _selected?.id == id) setState(() => _comments = cs);
    } catch (_) {}
  }

  Future<void> _postComment() async {
    final body = _commentCtl.text.trim();
    final sel = _selected;
    if (body.isEmpty || sel == null) return;
    try {
      await _client.postComment(sel.id, body);
      _commentCtl.clear();
      await _loadComments(sel.id);
    } catch (e) {
      _snack('评论失败: $e');
    }
  }

  Future<void> _ack() async {
    final sel = _selected;
    if (sel == null) return;
    try {
      await _client.ack(sel.id);
      _snack('已标记接收');
      _refresh();
    } catch (e) {
      _snack('ack 失败: $e');
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _client.handoffs(as: 'recipient');
      setState(() {
        _inbox = items;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '加载失败: $e';
      });
    }
  }

  Future<void> _select(ListItem it) async {
    setState(() {
      _selected = it;
      _pkg = null;
      _comments = const [];
      _detailLoading = true;
    });
    try {
      final pkg = await _client.get(it.id);
      setState(() {
        _pkg = pkg;
        _detailLoading = false;
      });
      _loadComments(it.id);
    } catch (e) {
      setState(() {
        _detailLoading = false;
      });
      _snack('$e');
    }
  }

  Future<void> _pickup(Package p) async {
    final path = _cfg.repoPath(p.repo.name);
    if (path == null) {
      _snack('本地找不到 repo "${p.repo.name}" —— 在 config.toml 的 [[workspace]] 里把它加上');
      return;
    }
    setState(() => _picking = true);
    try {
      final r = await Cli.pickup(p.id, path);
      setState(() {
        _termWorkdir = r.worktreeDir;
        _termCommand = r.agentCmd;
        _picking = false;
      });
    } catch (e) {
      setState(() => _picking = false);
      _snack('pickup 失败: $e');
    }
  }

  void _snack(String s) {
    if (mounted) snack(context, s);
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && _inbox.isEmpty) {
      return _centerMsg(_error!, onRetry: _refresh);
    }
    return Row(children: [
      SizedBox(width: 320, child: _buildList()),
      const VerticalDivider(width: 1),
      Expanded(flex: 4, child: _buildDetail()),
      if (widget.showTerminal && _termWorkdir != null) ...[
        const VerticalDivider(width: 1),
        Expanded(flex: 5, child: _buildTerminal()),
      ],
    ]);
  }

  Widget _buildList() {
    if (_loading && _inbox.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_inbox.isEmpty) return _centerMsg('收件箱为空', onRetry: _refresh);
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        itemCount: _inbox.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final it = _inbox[i];
          return ListTile(
            selected: _selected?.id == it.id,
            leading: Icon(Icons.circle,
                size: 10,
                color:
                    it.urgency == 'urgent' ? CcColors.danger : CcColors.muted),
            title: Text(it.sender,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              it.headline.isNotEmpty ? it.headline : it.repoName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: CcColors.muted),
            ),
            trailing: Text(relativeTime(it.createdAt),
                style: const TextStyle(color: CcColors.muted, fontSize: 12)),
            onTap: () => _select(it),
          );
        },
      ),
    );
  }

  Widget _buildDetail() {
    if (_selected == null) {
      return _centerMsg('从左侧选择一个 handoff,查看对接文档');
    }
    if (_detailLoading || _pkg == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final p = _pkg!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                '${p.sender} → ${p.recipient.isNotEmpty ? p.recipient : _cfg.identity}',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                chip(p.repo.branch.isNotEmpty
                    ? '${p.repo.name} @ ${p.repo.branch}'
                    : p.repo.name),
                kindBadge(p.kind),
              ]),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (widget.showTerminal)
                  FilledButton.icon(
                    onPressed: _picking ? null : () => _pickup(p),
                    icon: _picking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.download),
                    label: Text(_picking ? '接收中…' : '接收并物化 → 开终端'),
                  ),
                OutlinedButton.icon(
                  onPressed: _ack,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('仅标记已接收'),
                ),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: MarkdownBody(
              data: p.summaryMd.isNotEmpty ? p.summaryMd : '_(无 summary)_',
              selectable: true,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildComments(),
      ]),
    );
  }

  Widget _buildComments() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('评论', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (_comments.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('暂无评论', style: TextStyle(color: CcColors.muted)),
            )
          else
            ..._comments.map((c) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Text(c.sender,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 13)),
                          const SizedBox(width: 8),
                          Text(relativeTime(c.createdAt),
                              style: const TextStyle(
                                  color: CcColors.muted, fontSize: 11)),
                        ]),
                        const SizedBox(height: 2),
                        SelectableText(c.body),
                      ]),
                )),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _commentCtl,
                minLines: 1,
                maxLines: 4,
                decoration:
                    const InputDecoration(hintText: '写评论…', isDense: true),
                onSubmitted: (_) => _postComment(),
              ),
            ),
            IconButton(
                onPressed: _postComment, icon: const Icon(Icons.send, size: 20)),
          ]),
        ]),
      ),
    );
  }

  Widget _buildTerminal() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        color: CcColors.panel,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          const Icon(Icons.terminal, size: 16, color: CcColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_termWorkdir!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: CcColors.muted, fontSize: 12)),
          ),
        ]),
      ),
      Expanded(
        child: ColoredBox(
          color: CcColors.bg,
          child: TerminalPane(
            key: ValueKey(_termWorkdir),
            workdir: _termWorkdir!,
            command: _termCommand!,
          ),
        ),
      ),
    ]);
  }

  Widget _centerMsg(String s, {VoidCallback? onRetry}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(s,
                textAlign: TextAlign.center,
                style: const TextStyle(color: CcColors.muted)),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ]),
        ),
      );

}
