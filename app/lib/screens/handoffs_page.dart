import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../api/sse.dart';
import '../local/config.dart';
import '../local/prefs.dart';
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
  final bool enableEvents;
  const HandoffsPage({
    super.key,
    required this.client,
    required this.config,
    this.showTerminal = true,
    this.enableEvents = true,
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
  bool _listCollapsed = Prefs.getBool('inbox.list');
  bool _termCollapsed = Prefs.getBool('inbox.term');
  double _listWidth = Prefs.getDouble('inbox.listWidth', def: 340);
  double _termWidth = Prefs.getDouble('inbox.termWidth', def: 560);
  final _detailKey = GlobalKey<HandoffDetailViewState>();

  RelayClient get _client => widget.client;
  AppConfig get _cfg => widget.config;

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadOnline();
    if (widget.enableEvents) {
      _sse = subscribeEvents(
        _cfg.relayUrl,
        _cfg.token,
        _cfg.identity,
      ).listen(_onSse, onError: (_) {});
    }
  }

  Future<void> _loadOnline() async {
    try {
      final users = await _client.onlineUsers();
      if (mounted) {
        setState(
          () => _online = users
              .where((u) => u.online)
              .map((u) => u.identity)
              .toSet(),
        );
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
    if (!mounted) return;
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
        Notifications.show(
          '新 handoff · ${d['sender'] ?? ''}',
          (d['headline'] ?? d['repo_name'] ?? '').toString(),
        );
      case 'handoff.retracted':
        _refresh();
      case 'comment.created':
        final d = data();
        final hid = (d['handoff_id'] ?? '').toString();
        if (_selected?.id == hid) {
          _detailKey.currentState?.reloadComments();
        } else {
          Notifications.show(
            '新评论 · ${d['sender'] ?? ''}',
            (d['body'] ?? '').toString(),
          );
        }
      case 'user.online':
        final id = (data()['identity'] ?? '').toString();
        if (id.isNotEmpty) setState(() => _online.add(id));
      case 'user.offline':
        final id = (data()['identity'] ?? '').toString();
        setState(() => _online.remove(id));
      case 'log.alert':
        final d = data();
        Notifications.show(
          '日志告警 · ${d['project'] ?? ''}',
          (d['message'] ?? '').toString(),
        );
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _client.handoffs(as: _view);
      if (!mounted) return;
      setState(() {
        _inbox = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
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
    final termOpen = widget.showTerminal && terms.isNotEmpty && !_termCollapsed;
    return Row(
      children: [
        if (!_listCollapsed)
          SizedBox(width: _listWidth, child: _leftPane())
        else
          collapseRail(
            icon: Icons.chevron_right_rounded,
            tooltip: '展开列表',
            label: '收件箱',
            onExpand: () => _setListCollapsed(false),
          ),
        if (!_listCollapsed)
          resizeHandle(
            prefKey: 'inbox.listWidth',
            get: () => _listWidth,
            set: (v) => setState(() => _listWidth = v),
            min: 260,
            max: 520,
          )
        else
          const VerticalDivider(width: 1),
        Expanded(child: _buildDetail()),
        if (widget.showTerminal && terms.isNotEmpty) ...[
          if (termOpen) ...[
            // terminal is on the right: dragging left widens it (invert).
            resizeHandle(
              prefKey: 'inbox.termWidth',
              get: () => _termWidth,
              set: (v) => setState(() => _termWidth = v),
              min: 360,
              max: 920,
              invert: true,
            ),
            SizedBox(
              width: _termWidth,
              child: terminalDeck(onCollapse: () => _setTermCollapsed(true)),
            ),
          ] else ...[
            const VerticalDivider(width: 1),
            collapseRail(
              icon: Icons.chevron_left_rounded,
              tooltip: '展开终端',
              label: '终端',
              onExpand: () => _setTermCollapsed(false),
            ),
          ],
        ],
      ],
    );
  }

  void _setListCollapsed(bool v) {
    setState(() => _listCollapsed = v);
    Prefs.setBool('inbox.list', v);
  }

  void _setTermCollapsed(bool v) {
    setState(() => _termCollapsed = v);
    Prefs.setBool('inbox.term', v);
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

  Widget _leftPane() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(2, 6, 8, 0),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left_rounded, size: 18),
              tooltip: '收起列表',
              visualDensity: VisualDensity.compact,
              onPressed: () => _setListCollapsed(true),
            ),
            const SizedBox(width: 2),
            Expanded(
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
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onSelectionChanged: (s) {
                  setState(() {
                    _view = s.first;
                    _selected = null;
                  });
                  _refresh();
                },
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: TextField(
          decoration: const InputDecoration(
            hintText: '搜索 发送人 / repo / 标题',
            isDense: true,
            prefixIcon: Icon(Icons.search_rounded, size: 18),
          ),
          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
        ),
      ),
      const Divider(height: 1),
      Expanded(child: _buildList()),
      if (_online.isNotEmpty) _onlineRoster(),
    ],
  );

  Widget _onlineRoster() => Container(
    constraints: const BoxConstraints(maxHeight: 130),
    margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
    decoration: BoxDecoration(
      color: CcColors.panelHigh.withValues(alpha: 0.45),
      border: Border.all(color: CcColors.border),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(
            '在线 (${_online.length})',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: CcColors.muted,
            ),
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: _online
                .map(
                  (u) => Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 3,
                    ),
                    child: Row(
                      children: [
                        statusDot(CcColors.ok, size: 8, glow: true),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            u,
                            style: const TextStyle(
                              fontFamily: CcType.mono,
                              fontSize: 11.5,
                              color: CcColors.muted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    ),
  );

  Widget _buildList() {
    if (_loading && _inbox.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _query.isEmpty
        ? _inbox
        : _inbox
              .where(
                (it) => '${it.sender} ${it.repoName} ${it.headline}'
                    .toLowerCase()
                    .contains(_query),
              )
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
          final sel = _selected?.id == it.id;
          final urgent = it.urgency == 'urgent';
          return Material(
            color: sel
                ? CcColors.accent.withValues(alpha: 0.07)
                : Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: sel ? CcColors.accent : Colors.transparent,
                    width: 2.5,
                  ),
                ),
              ),
              child: ListTile(
                selected: sel,
                leading: statusDot(
                  urgent ? CcColors.danger : _kindColor(it.kind),
                  size: 9,
                  glow: urgent,
                ),
                title: Text(
                  it.sender,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  it.headline.isNotEmpty ? it.headline : it.repoName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: CcColors.muted),
                ),
                trailing: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      relativeTime(it.createdAt),
                      style: const TextStyle(
                        fontFamily: CcType.mono,
                        color: CcColors.subtle,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 4),
                    kindBadge(it.kind),
                  ],
                ),
                onTap: () => setState(() => _selected = it),
              ),
            ),
          );
        },
      ),
    );
  }

  Color _kindColor(String kind) {
    if (kind == 'bug') return CcColors.danger;
    if (kind == 'request') return CcColors.warning;
    return CcColors.accent;
  }
}
