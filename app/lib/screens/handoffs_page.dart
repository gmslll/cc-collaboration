import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../api/sse.dart';
import '../local/cli.dart';
import '../local/config.dart';
import '../notifications.dart';
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
  String _view = 'recipient'; // recipient | sender | history
  String _query = '';
  List<ListItem> _inbox = const [];
  ListItem? _selected;
  Package? _pkg;
  bool _detailLoading = false;
  bool _picking = false;
  final List<TerminalSession> _terms = [];
  int _activeTerm = 0;
  List<Comment> _comments = const [];
  final _commentCtl = TextEditingController();
  StreamSubscription<SseEvent>? _sse;
  String? _prompt;
  Status? _status;
  Set<String> _online = {};

  RelayClient get _client => widget.client;
  AppConfig get _cfg => widget.config;

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadOnline();
    _sse = subscribeEvents(_cfg.relayUrl, _cfg.token, _cfg.identity)
        .listen(_onSse, onError: (_) {});
  }

  Future<void> _loadOnline() async {
    try {
      final users = await _client.onlineUsers();
      if (mounted) {
        setState(() => _online =
            users.where((u) => u.online).map((u) => u.identity).toSet());
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _sse?.cancel();
    _commentCtl.dispose();
    for (final s in _terms) {
      s.dispose();
    }
    super.dispose();
  }

  void _onSse(SseEvent ev) {
    Map<String, dynamic> data() {
      try {
        return jsonDecode(ev.data) as Map<String, dynamic>;
      } catch (_) {
        return const {};
      }
    }

    switch (ev.type) {
      case 'handoff.created':
        _refresh();
        final d = data();
        Notifications.show('新 handoff · ${d['sender'] ?? ''}',
            (d['headline'] ?? d['repo_name'] ?? '').toString());
      case 'handoff.retracted':
        _refresh();
      case 'comment.created':
        final d = data();
        final hid = (d['handoff_id'] ?? '').toString();
        if (_selected?.id == hid) {
          _loadComments(hid);
        } else {
          Notifications.show(
              '新评论 · ${d['sender'] ?? ''}', (d['body'] ?? '').toString());
        }
      case 'user.online':
        final id = (data()['identity'] ?? '').toString();
        if (id.isNotEmpty) setState(() => _online.add(id));
      case 'user.offline':
        final id = (data()['identity'] ?? '').toString();
        setState(() => _online.remove(id));
      case 'log.alert':
        final d = data();
        Notifications.show('日志告警 · ${d['project'] ?? ''}',
            (d['message'] ?? '').toString());
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
      _snack('评论失败: ${errorText(e)}');
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
      _snack('ack 失败: ${errorText(e)}');
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _client.handoffs(as: _view);
      setState(() {
        _inbox = items;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '加载失败: ${errorText(e)}';
      });
    }
  }

  Future<void> _select(ListItem it) async {
    setState(() {
      _selected = it;
      _pkg = null;
      _comments = const [];
      _prompt = null;
      _status = null;
      _detailLoading = true;
    });
    try {
      final pkg = await _client.get(it.id);
      setState(() {
        _pkg = pkg;
        _detailLoading = false;
      });
      _loadComments(it.id);
      _loadExtras(it.id);
    } catch (e) {
      setState(() {
        _detailLoading = false;
      });
      _snack(errorText(e));
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
        _terms.add(TerminalSession(r.worktreeDir, r.agentCmd));
        _activeTerm = _terms.length - 1;
        _picking = false;
      });
    } catch (e) {
      setState(() => _picking = false);
      _snack('pickup 失败: ${errorText(e)}');
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
      SizedBox(width: 320, child: _leftPane()),
      const VerticalDivider(width: 1),
      Expanded(flex: 4, child: _buildDetail()),
      if (widget.showTerminal && _terms.isNotEmpty) ...[
        const VerticalDivider(width: 1),
        Expanded(flex: 5, child: _buildTerminals()),
      ],
    ]);
  }

  Widget _leftPane() => Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'recipient', label: Text('收件箱')),
                ButtonSegment(value: 'sender', label: Text('已发')),
                ButtonSegment(value: 'history', label: Text('历史')),
              ],
              selected: {_view},
              showSelectedIcon: false,
              style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              onSelectionChanged: (s) {
                setState(() {
                  _view = s.first;
                  _selected = null;
                  _pkg = null;
                });
                _refresh();
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: TextField(
            decoration: const InputDecoration(
                hintText: '搜索 发送人 / repo / 标题',
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18)),
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildList()),
        if (_online.isNotEmpty) _onlineRoster(),
      ]);

  Widget _onlineRoster() => Container(
        constraints: const BoxConstraints(maxHeight: 130),
        decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: CcColors.border))),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Text('在线 (${_online.length})',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: CcColors.muted)),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: _online
                      .map((u) => Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 3),
                            child: Row(children: [
                              const Icon(Icons.circle, size: 8, color: CcColors.ok),
                              const SizedBox(width: 8),
                              Expanded(
                                  child: Text(u,
                                      style: const TextStyle(fontSize: 12),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis)),
                            ]),
                          ))
                      .toList(),
                ),
              ),
            ]),
      );

  Widget _buildList() {
    if (_loading && _inbox.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _query.isEmpty
        ? _inbox
        : _inbox
            .where((it) => '${it.sender} ${it.repoName} ${it.headline}'
                .toLowerCase()
                .contains(_query))
            .toList();
    if (items.isEmpty) {
      return _centerMsg(_inbox.isEmpty ? '空' : '无匹配', onRetry: _refresh);
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final it = items[i];
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

  Future<void> _loadExtras(String id) async {
    try {
      final p = await _client.prompt(id);
      if (mounted && _selected?.id == id) setState(() => _prompt = p);
    } catch (_) {}
    try {
      final s = await _client.status(id);
      if (mounted && _selected?.id == id) setState(() => _status = s);
    } catch (_) {}
  }

  Widget _buildDetail() {
    if (_selected == null) {
      return _centerMsg('从左侧选择一个 handoff,查看对接文档');
    }
    if (_detailLoading || _pkg == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final p = _pkg!;
    return DefaultTabController(
      length: 5,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _detailHeader(p),
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
                padding: const EdgeInsets.all(16), child: _buildComments()),
          ]),
        ),
      ]),
    );
  }

  Widget _detailHeader(Package p) {
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
      _refresh();
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
      _refresh();
    } catch (e) {
      _snack('转交失败: ${errorText(e)}');
    }
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
              Clipboard.setData(ClipboardData(
                  text: 'cc-handoff pickup ${_selected?.id ?? ''} --worktree'));
              _snack('已复制 pickup 命令');
            },
            icon: const Icon(Icons.terminal, size: 16),
            label: const Text('复制 pickup 命令'),
          ),
          if (_terms.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                _terms[_activeTerm].sendText(_prompt!);
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
    if (d == null || d.isEmpty) return _centerMsg('无 API 变更');
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
    if (children.isEmpty) return _centerMsg('无文件 / 模块信息');
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

  Future<void> _downloadAttachment(String name) async {
    final id = _selected?.id;
    if (id == null) return;
    try {
      final bytes = await _client.attachment(id, name);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes);
      final res = await OpenFilex.open(file.path);
      if (res.type != ResultType.done) _snack('已保存到 ${file.path}');
    } catch (e) {
      _snack('附件失败: ${errorText(e)}');
    }
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

  Widget _buildTerminals() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        color: CcColors.panel,
        height: 38,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: _terms.length,
          itemBuilder: (_, i) {
            final active = i == _activeTerm;
            return InkWell(
              onTap: () => setState(() => _activeTerm = i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  border: Border(
                      bottom: BorderSide(
                          color: active ? CcColors.accent : Colors.transparent,
                          width: 2)),
                ),
                child: Row(children: [
                  Icon(Icons.terminal,
                      size: 14,
                      color: active ? CcColors.accent : CcColors.muted),
                  const SizedBox(width: 6),
                  Text(_terms[i].title,
                      style: TextStyle(
                          fontSize: 12,
                          color: active ? CcColors.text : CcColors.muted)),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => _closeTerm(i),
                    child: const Icon(Icons.close, size: 14, color: CcColors.muted),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
      Expanded(
        child: ColoredBox(
          color: CcColors.bg,
          child: IndexedStack(
            index: _activeTerm,
            children: _terms
                .map((s) => TerminalPane(key: ValueKey(s), session: s))
                .toList(),
          ),
        ),
      ),
    ]);
  }

  void _closeTerm(int i) {
    _terms[i].dispose();
    setState(() {
      _terms.removeAt(i);
      if (_activeTerm >= _terms.length) {
        _activeTerm = _terms.isEmpty ? 0 : _terms.length - 1;
      }
    });
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
