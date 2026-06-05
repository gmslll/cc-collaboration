import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../local/cli.dart';
import '../local/config.dart';
import '../theme.dart';
import '../widgets.dart';

// HandoffDetailView is the reusable 对接文档: a 5-tab view (文档 / Prompt / API /
// 文件 / 评论) + header + actions. Shared by the inbox cockpit (right pane) and
// the workspace cockpit (a dialog).
//
// Callbacks let the host wire local-only bits without owning detail state:
//  - onOpenTerminal(workdir, command): pickup → host adds a terminal session.
//    Null hides the pickup button (e.g. mobile / no terminal deck).
//  - onSendToTerminal(text): "发送到终端". Null hides the button.
//  - onChanged: after ack/retract/reassign, so the host can refresh its list.
class HandoffDetailView extends StatefulWidget {
  final RelayClient client;
  final AppConfig config;
  final ListItem item;
  final void Function(String workdir, String command)? onOpenTerminal;
  final void Function(String text)? onSendToTerminal;
  final VoidCallback? onChanged;

  const HandoffDetailView({
    super.key,
    required this.client,
    required this.config,
    required this.item,
    this.onOpenTerminal,
    this.onSendToTerminal,
    this.onChanged,
  });

  @override
  State<HandoffDetailView> createState() => HandoffDetailViewState();
}

class HandoffDetailViewState extends State<HandoffDetailView> {
  Package? _pkg;
  Status? _status;
  String? _prompt;
  List<Comment> _comments = const [];
  bool _loading = true;
  bool _picking = false;
  final _commentCtl = TextEditingController();

  RelayClient get _client => widget.client;
  AppConfig get _cfg => widget.config;
  String get _id => widget.item.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(HandoffDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) _load();
  }

  @override
  void dispose() {
    _commentCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _pkg = null;
      _status = null;
      _prompt = null;
      _comments = const [];
      _loading = true;
    });
    try {
      final pkg = await _client.get(_id);
      if (!mounted) return;
      setState(() {
        _pkg = pkg;
        _loading = false;
      });
      reloadComments();
      _loadExtras();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(errorText(e));
    }
  }

  // reloadComments is public so the host's SSE can refresh on comment.created.
  Future<void> reloadComments() async {
    try {
      final cs = await _client.comments(_id);
      if (mounted) setState(() => _comments = cs);
    } catch (_) {}
  }

  Future<void> _loadExtras() async {
    try {
      final p = await _client.prompt(_id);
      if (mounted) setState(() => _prompt = p);
    } catch (_) {}
    try {
      final s = await _client.status(_id);
      if (mounted) setState(() => _status = s);
    } catch (_) {}
  }

  void _snack(String s) {
    if (mounted) snack(context, s);
  }

  Future<void> _postComment() async {
    final body = _commentCtl.text.trim();
    if (body.isEmpty) return;
    try {
      await _client.postComment(_id, body);
      _commentCtl.clear();
      await reloadComments();
    } catch (e) {
      _snack('评论失败: ${errorText(e)}');
    }
  }

  Future<void> _ack() async {
    try {
      await _client.ack(_id);
      _snack('已标记接收');
      _loadExtras();
      widget.onChanged?.call();
    } catch (e) {
      _snack('ack 失败: ${errorText(e)}');
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
      widget.onOpenTerminal?.call(r.worktreeDir, r.agentCmd);
      if (mounted) setState(() => _picking = false);
    } catch (e) {
      if (mounted) setState(() => _picking = false);
      _snack('pickup 失败: ${errorText(e)}');
    }
  }

  Future<void> _retract(Package p) async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤回 handoff'),
        content: TextField(
            controller: ctl,
            decoration: const InputDecoration(hintText: '原因(可选)')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('撤回')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _client.retract(p.id, ctl.text.trim());
      _snack('已撤回');
      _loadExtras();
      widget.onChanged?.call();
    } catch (e) {
      _snack('撤回失败: ${errorText(e)}');
    }
  }

  Future<void> _reassign(Package p) async {
    final to = TextEditingController();
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('转交 bug'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: to,
              decoration: const InputDecoration(labelText: '转交给(identity)')),
          const SizedBox(height: 8),
          TextField(
              controller: reason,
              decoration: const InputDecoration(labelText: '原因')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('转交')),
        ],
      ),
    );
    if (ok != true) return;
    if (to.text.trim().isEmpty || reason.text.trim().isEmpty) {
      _snack('需填转交对象和原因');
      return;
    }
    try {
      await _client.reassign(p.id, to.text.trim(), reason.text.trim());
      _snack('已转交');
      _loadExtras();
      widget.onChanged?.call();
    } catch (e) {
      _snack('转交失败: ${errorText(e)}');
    }
  }

  Future<void> _downloadAttachment(String name) async {
    try {
      final bytes = await _client.attachment(_id, name);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes);
      final res = await OpenFilex.open(file.path);
      if (res.type != ResultType.done) _snack('已保存到 ${file.path}');
    } catch (e) {
      _snack('附件失败: ${errorText(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _pkg == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final p = _pkg!;
    return DefaultTabController(
      length: 5,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _header(p),
        const TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: '文档'),
            Tab(text: 'Prompt'),
            Tab(text: 'API'),
            Tab(text: '文件'),
            Tab(text: '评论'),
          ],
        ),
        Expanded(
          child: TabBarView(children: [
            _mdScroll(p.summaryMd.isNotEmpty ? p.summaryMd : '_(无 summary)_',
                extras: _summaryExtras(p)),
            _tabPrompt(),
            _tabApi(p),
            _tabFiles(p),
            SingleChildScrollView(
                padding: const EdgeInsets.all(16), child: _commentsSection()),
          ]),
        ),
      ]),
    );
  }

  Widget _header(Package p) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '${p.sender} → ${p.recipient.isNotEmpty ? p.recipient : _cfg.identity}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            chip(p.repo.branch.isNotEmpty
                ? '${p.repo.name} @ ${p.repo.branch}'
                : p.repo.name),
            kindBadge(p.kind),
            if (p.urgency == 'urgent') tag('urgent', CcColors.danger, bold: true),
            if (_status != null) tag(_status!.state, _stateColor(_status!.state)),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (widget.onOpenTerminal != null)
              FilledButton.icon(
                onPressed: _picking ? null : () => _pickup(p),
                icon: _picking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download),
                label: Text(_picking ? '接收中…' : '接收并开终端'),
              ),
            OutlinedButton.icon(
              onPressed: _ack,
              icon: const Icon(Icons.check, size: 18),
              label: const Text('标记接收'),
            ),
            if (p.sender == _cfg.identity && _status?.state == 'pending')
              OutlinedButton.icon(
                onPressed: () => _retract(p),
                icon: const Icon(Icons.undo, size: 18),
                label: const Text('撤回'),
              ),
            if (p.kind == 'bug' && _status?.state == 'pending')
              OutlinedButton.icon(
                onPressed: () => _reassign(p),
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('转交'),
              ),
          ]),
        ]),
      ),
    );
  }

  Widget _mdScroll(String md, {Widget? extras}) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          MarkdownBody(data: md, selectable: true),
          ?extras,
        ]),
      );

  Widget? _summaryExtras(Package p) {
    final parts = <Widget>[];
    if (p.prdMd.isNotEmpty) parts.add(_mdSection('PRD', p.prdMd));
    if (p.noteMd.isNotEmpty) parts.add(_mdSection('发送者备注', p.noteMd));
    return parts.isEmpty
        ? null
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: parts);
  }

  Widget _mdSection(String title, String md) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          MarkdownBody(data: md, selectable: true),
        ]),
      );

  Widget _tabPrompt() {
    if (_prompt == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
        child: Wrap(children: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _prompt!));
              _snack('已复制 Prompt');
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制 Prompt'),
          ),
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(
                  ClipboardData(text: 'cc-handoff pickup $_id --worktree'));
              _snack('已复制 pickup 命令');
            },
            icon: const Icon(Icons.terminal, size: 16),
            label: const Text('复制 pickup 命令'),
          ),
          if (widget.onSendToTerminal != null)
            TextButton.icon(
              onPressed: () {
                widget.onSendToTerminal!(_prompt!);
                _snack('已发送到终端');
              },
              icon: const Icon(Icons.keyboard_return, size: 16),
              label: const Text('发送到终端'),
            ),
        ]),
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: MarkdownBody(
              data: _prompt!.isNotEmpty ? _prompt! : '_(无 prompt)_',
              selectable: true),
        ),
      ),
    ]);
  }

  Widget _tabApi(Package p) {
    final d = p.apiDelta;
    if (d == null || d.isEmpty) return centerMsg('无 API 变更');
    return ListView(padding: const EdgeInsets.all(16), children: [
      ..._apiSection('新增', d.added, CcColors.ok),
      ..._apiSection('变更', d.changed, CcColors.warning),
      ..._apiSection('删除', d.removed, CcColors.danger),
    ]);
  }

  List<Widget> _apiSection(String title, List<ApiOp> ops, Color c) {
    if (ops.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Text(title,
            style: TextStyle(fontWeight: FontWeight.bold, color: c)),
      ),
      ...ops.map((op) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              tag(op.method, c, bold: true),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  op.summary.isNotEmpty ? '${op.path}  ·  ${op.summary}' : op.path,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ),
            ]),
          )),
      const SizedBox(height: 8),
    ];
  }

  Widget _tabFiles(Package p) {
    final children = <Widget>[];
    if (p.modulePaths.isNotEmpty) {
      children.add(_filesHeader('模块路径'));
      children.addAll(
          p.modulePaths.map((m) => _fileRow(m, Icons.folder_outlined)));
    }
    if (p.attachments.isNotEmpty) {
      children.add(_filesHeader('附件'));
      children.addAll(p.attachments.map((a) => ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.attach_file, size: 18),
            title: Text(a.name),
            subtitle: Text(_fmtBytes(a.size),
                style: const TextStyle(color: CcColors.muted, fontSize: 11)),
            trailing: IconButton(
              icon: const Icon(Icons.download, size: 20),
              onPressed: () => _downloadAttachment(a.name),
            ),
          )));
    }
    final git = p.git;
    if (git != null && git.commits.isNotEmpty) {
      children.add(_filesHeader('提交 (${git.commits.length})'));
      children.addAll(git.commits.map((c) => ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(c.subject, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(c.sha.length > 8 ? c.sha.substring(0, 8) : c.sha,
                style: const TextStyle(
                    color: CcColors.muted,
                    fontFamily: 'monospace',
                    fontSize: 11)),
          )));
    }
    if (git != null && git.changedPaths.isNotEmpty) {
      children.add(_filesHeader('变更文件 (${git.changedPaths.length})'));
      children.addAll(git.changedPaths
          .map((f) => _fileRow(f, Icons.insert_drive_file_outlined)));
    }
    if (children.isEmpty) return centerMsg('无文件 / 模块信息');
    return ListView(padding: const EdgeInsets.all(16), children: children);
  }

  Widget _filesHeader(String s) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Text(s, style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  Widget _fileRow(String s, IconData icon) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Icon(icon, size: 16, color: CcColors.muted),
          const SizedBox(width: 8),
          Expanded(
              child: Text(s,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13))),
        ]),
      );

  Widget _commentsSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('评论', style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
                onPressed: reloadComments,
                tooltip: '刷新',
                icon: const Icon(Icons.refresh, size: 18)),
          ]),
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

  String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Color _stateColor(String s) {
    switch (s) {
      case 'picked':
        return CcColors.ok;
      case 'retracted':
      case 'expired':
        return CcColors.danger;
      case 'reassigned':
        return CcColors.warning;
      default:
        return CcColors.accent;
    }
  }

}
