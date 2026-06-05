import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../api/sse.dart';
import '../local/config.dart';
import '../notifications.dart';
import '../theme.dart';
import '../widgets.dart';
import 'handoff_detail_view.dart';
import 'terminal_deck.dart';

// HandoffsPage is the inbox cockpit: list (inbox/sent/history) → 对接文档
// (HandoffDetailView) → pickup → embedded agent terminals (TerminalDeck).
// Desktop-focused; on mobile the terminal column simply isn't shown.
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

class _HandoffsPageState extends State<HandoffsPage> with TerminalHost {
  String? _error;
  bool _loading = true;
  String _view = 'recipient'; // recipient | sender | history
  String _query = '';
  List<ListItem> _inbox = const [];
  ListItem? _selected;
  StreamSubscription<SseEvent>? _sse;
  Set<String> _online = {};
  final _detailKey = GlobalKey<HandoffDetailViewState>();

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
    disposeTerms();
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
          _detailKey.currentState?.reloadComments();
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

  @override
  Widget build(BuildContext context) {
    if (_error != null && _inbox.isEmpty) {
      return centerMsg(_error!, onRetry: _refresh);
    }
    return Row(children: [
      SizedBox(width: 320, child: _leftPane()),
      const VerticalDivider(width: 1),
      Expanded(flex: 4, child: _buildDetail()),
      if (widget.showTerminal && terms.isNotEmpty) ...[
        const VerticalDivider(width: 1),
        Expanded(flex: 5, child: terminalDeck()),
      ],
    ]);
  }

  Widget _buildDetail() {
    final sel = _selected;
    if (sel == null) {
      return centerMsg('从左侧选择一个 handoff,查看对接文档');
    }
    return HandoffDetailView(
      key: _detailKey,
      client: _client,
      config: _cfg,
      item: sel,
      onOpenTerminal: widget.showTerminal ? addTerm : null,
      onSendToTerminal: sendToTerminal,
      onChanged: _refresh,
    );
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
      return centerMsg(_inbox.isEmpty ? '空' : '无匹配', onRetry: _refresh);
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
            onTap: () => setState(() => _selected = it),
          );
        },
      ),
    );
  }
}
