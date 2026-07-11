import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../local/agent_transcript.dart';
import '../local/config.dart';
import '../local/identity.dart';
import '../local/local_bus.dart';
import '../local/session_overview.dart';
import '../local/skill_pack.dart';
import '../theme.dart';
import '../widgets.dart';
import '../widgets/capsule_binding_picker.dart';

// CapsulePlazaPage is the 胶囊广场: a browsable gallery of session capsules the
// caller can see — team-shared capsules plus their own 个人 (private) ones. Fed
// by GET /v1/capsules. On desktop each capsule can be 载入 into a fresh
// specialized session (① full-context snapshot / ② distilled role).
class CapsulePlazaPage extends StatefulWidget {
  final RelayClient client;
  final String identity;
  // overviewStore + config drive 载入 (spawn a session + dispatch an opening
  // message). isDesktop gates it: spawn is only wired when a WorkspacePage is
  // mounted (desktop), so mobile just browses.
  final SessionOverviewStore overviewStore;
  final AppConfig config;
  final bool isDesktop;
  const CapsulePlazaPage({
    super.key,
    required this.client,
    required this.identity,
    required this.overviewStore,
    required this.config,
    required this.isDesktop,
  });

  @override
  State<CapsulePlazaPage> createState() => _CapsulePlazaPageState();
}

bool capsuleOwnedBy(CapsuleListItem capsule, String identity) =>
    sameIdentity(capsule.owner, identity);

double capsuleReadonlyPreviewMaxHeight(
  Size screenSize, {
  double preferred = 130,
  double minHeight = 82,
  double maxFraction = 0.2,
}) {
  final height = screenSize.height;
  if (!height.isFinite || height <= 0) return preferred;
  final capped = height * maxFraction.clamp(0, 1);
  if (capped >= preferred) return preferred;
  return capped < minHeight ? minHeight : capped;
}

double capsuleLoadMenuMaxHeight(
  Size screenSize, {
  double preferred = 320,
  double minHeight = 160,
  double maxFraction = 0.46,
}) {
  final height = screenSize.height;
  if (!height.isFinite || height <= 0) return preferred;
  final capped = height * maxFraction.clamp(0, 1);
  if (capped >= preferred) return preferred;
  return capped < minHeight ? minHeight : capped;
}

Size capsuleLoadDialogSize(
  Size viewport, {
  double preferredWidth = 480,
  double preferredHeight = 720,
}) => Size(
  capsuleDialogDimension(viewport.width - 32, preferredWidth),
  capsuleDialogDimension(viewport.height - 48, preferredHeight, min: 300),
);

double capsuleDeleteDialogWidth(Size size, {double preferred = 420}) {
  final available = size.width - 32;
  if (!available.isFinite || available <= 0) return preferred;
  return available < preferred ? available : preferred;
}

double capsuleDialogDimension(
  double available,
  double preferred, {
  double min = 160,
}) {
  if (!available.isFinite || available <= 0) return preferred;
  if (available < min) return available;
  return available < preferred ? available : preferred;
}

Size capsuleEditDialogSize(
  Size viewport, {
  double preferredWidth = 460,
  double preferredHeight = 640,
}) => Size(
  capsuleDialogDimension(viewport.width - 32, preferredWidth),
  capsuleDialogDimension(viewport.height - 48, preferredHeight, min: 260),
);

enum CapsulePlazaScope { all, mine, team }

int capsuleGridColumnCount(double availableWidth) {
  if (!availableWidth.isFinite || availableWidth < 660) return 1;
  if (availableWidth < 1020) return 2;
  return 3;
}

String capsuleSummaryPreview(CapsuleListItem capsule) {
  final summary = capsule.summary.trim();
  final headline = capsule.headline.trim();
  if (summary.isEmpty || summary == headline) return '暂无补充摘要';
  final lines = summary.split('\n').map((line) => line.trim()).toList();
  if (lines.isNotEmpty && lines.first == headline) lines.removeAt(0);
  final preview = lines.where((line) => line.isNotEmpty).join(' ');
  return preview.isEmpty ? '暂无补充摘要' : preview;
}

enum _PlazaFilterKind { agent, repo, clear }

class _PlazaFilterChoice {
  final _PlazaFilterKind kind;
  final String value;

  const _PlazaFilterChoice(this.kind, [this.value = '']);
}

enum _CapsuleOwnerAction { edit, delete }

class _CapsulePlazaPageState extends State<CapsulePlazaPage> {
  List<CapsuleListItem>? _items;
  String? _error;
  bool _loading = false;
  int _loadGeneration = 0;
  final _searchController = TextEditingController();
  CapsulePlazaScope _scope = CapsulePlazaScope.all;
  String? _agentFilter;
  String? _repoFilter;
  final Set<String> _deletingIds = {};
  Map<String, String> _organizationNames = const {};
  Map<String, String> _relayProjectNames = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant CapsulePlazaPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_plazaContextChanged(oldWidget)) {
      _loadGeneration++;
      _searchController.clear();
      setState(() {
        _items = null;
        _error = null;
        _loading = true;
        _scope = CapsulePlazaScope.all;
        _agentFilter = null;
        _repoFilter = null;
        _deletingIds.clear();
        _organizationNames = const {};
        _relayProjectNames = const {};
      });
      _load();
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    final client = widget.client;
    final identity = widget.identity;
    final relayUrl = widget.config.relayUrl;
    final token = widget.config.token;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final itemsFuture = client.capsules();
      final orgsFuture = client.organizations().catchError(
        (_) => <Organization>[],
      );
      final projectsFuture = client.projects().catchError((_) => <Project>[]);
      final items = await itemsFuture;
      final orgs = await orgsFuture;
      final projects = await projectsFuture;
      if (!_isCurrentLoad(generation, client, identity, relayUrl, token)) {
        return;
      }
      setState(() {
        _items = items;
        _organizationNames = {for (final org in orgs) org.id: org.name};
        _relayProjectNames = {
          for (final project in projects) project.id: project.name,
        };
        _loading = false;
      });
    } catch (e) {
      if (!_isCurrentLoad(generation, client, identity, relayUrl, token)) {
        return;
      }
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  bool _plazaContextChanged(CapsulePlazaPage oldWidget) =>
      oldWidget.client != widget.client ||
      oldWidget.identity != widget.identity ||
      oldWidget.config.relayUrl != widget.config.relayUrl ||
      oldWidget.config.token != widget.config.token;

  bool _isCurrentLoad(
    int generation,
    RelayClient client,
    String identity,
    String relayUrl,
    String token,
  ) =>
      mounted &&
      generation == _loadGeneration &&
      identical(client, widget.client) &&
      widget.identity == identity &&
      widget.config.relayUrl == relayUrl &&
      widget.config.token == token;

  bool _isCurrentPlazaContext(
    RelayClient client,
    String identity,
    String relayUrl,
    String token,
  ) =>
      mounted &&
      identical(client, widget.client) &&
      widget.identity == identity &&
      widget.config.relayUrl == relayUrl &&
      widget.config.token == token;

  @override
  Widget build(BuildContext context) {
    final visibleCount = _items == null ? null : _filteredItems().length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 11, 12, 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: CcColors.border)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.inventory_2_outlined,
                size: 19,
                color: CcColors.accent,
              ),
              const SizedBox(width: 9),
              const Text(
                '胶囊广场',
                style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 9),
              if (visibleCount != null)
                Tooltip(
                  message: '当前筛选结果',
                  child: Container(
                    key: const ValueKey('capsule-result-count'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: CcColors.panelHigh,
                      borderRadius: BorderRadius.circular(CcRadius.sm),
                    ),
                    child: Text(
                      '$visibleCount 个',
                      style: CcType.code(size: 11.5, color: CcColors.muted),
                    ),
                  ),
                ),
              if (_loading && _items != null) ...[
                const SizedBox(width: 9),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              ],
              const Spacer(),
              IconButton(
                tooltip: '刷新胶囊',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                onPressed: _loading ? null : _load,
              ),
            ],
          ),
        ),
        _toolbar(),
        Expanded(child: _body()),
      ],
    );
  }

  List<CapsuleListItem> _filteredItems() {
    final query = _searchController.text.trim().toLowerCase();
    return (_items ?? const <CapsuleListItem>[]).where((capsule) {
      final mine = capsuleOwnedBy(capsule, widget.identity);
      if (_scope == CapsulePlazaScope.mine && !mine) return false;
      if (_scope == CapsulePlazaScope.team && capsule.visibility != 'public') {
        return false;
      }
      if (_agentFilter != null && capsule.sourceAgent != _agentFilter) {
        return false;
      }
      if (_repoFilter != null && capsule.repoName != _repoFilter) return false;
      if (query.isEmpty) return true;
      final searchable = <String>[
        capsule.headline,
        capsule.summary,
        capsule.owner,
        capsule.sourceAgent,
        capsule.repoName,
        capsule.visibility == 'public' ? '团队共享' : '个人',
        if (capsule.hasTranscript) '会话记录',
        if (capsule.hasPersona) '角色说明',
        if (capsule.skillPackCount > 0) '技能包',
      ].join(' ').toLowerCase();
      return searchable.contains(query);
    }).toList();
  }

  Widget _toolbar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      color: CcColors.toolbar.withValues(alpha: 0.45),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final search = Row(
            children: [
              Expanded(child: _searchField()),
              const SizedBox(width: 8),
              _filterMenu(),
            ],
          );
          final scopes = _scopeSegments();
          if (constraints.maxWidth < 700) {
            return Column(
              children: [search, const SizedBox(height: 8), scopes],
            );
          }
          return Row(
            children: [
              Expanded(child: search),
              const SizedBox(width: 12),
              SizedBox(width: 310, child: scopes),
            ],
          );
        },
      ),
    );
  }

  Widget _searchField() => SizedBox(
    height: 36,
    child: TextField(
      key: const ValueKey('capsule-search'),
      controller: _searchController,
      onChanged: (_) => setState(() {}),
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: '搜索标题、作者或项目',
        isDense: true,
        prefixIcon: const Icon(Icons.search_rounded, size: 17),
        prefixIconConstraints: const BoxConstraints.tightFor(
          width: 36,
          height: 36,
        ),
        suffixIcon: _searchController.text.isEmpty
            ? null
            : IconButton(
                tooltip: '清空搜索',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  _searchController.clear();
                  setState(() {});
                },
                icon: const Icon(Icons.close_rounded, size: 16),
              ),
        suffixIconConstraints: const BoxConstraints.tightFor(
          width: 36,
          height: 36,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
      ),
    ),
  );

  Widget _scopeSegments() => SizedBox(
    height: 36,
    child: SegmentedButton<CapsulePlazaScope>(
      key: const ValueKey('capsule-visibility-filter'),
      expandedInsets: EdgeInsets.zero,
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12.5)),
      ),
      segments: const [
        ButtonSegment(value: CapsulePlazaScope.all, label: Text('全部')),
        ButtonSegment(value: CapsulePlazaScope.mine, label: Text('我的')),
        ButtonSegment(value: CapsulePlazaScope.team, label: Text('团队共享')),
      ],
      selected: {_scope},
      onSelectionChanged: (selection) =>
          setState(() => _scope = selection.first),
    ),
  );

  Widget _filterMenu() {
    final agents =
        (_items ?? const <CapsuleListItem>[])
            .map((capsule) => capsule.sourceAgent)
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final repos =
        (_items ?? const <CapsuleListItem>[])
            .map((capsule) => capsule.repoName)
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final activeCount =
        (_agentFilter == null ? 0 : 1) + (_repoFilter == null ? 0 : 1);
    return SizedBox(
      width: 36,
      height: 36,
      child: PopupMenuButton<_PlazaFilterChoice>(
        key: const ValueKey('capsule-source-repo-filter'),
        tooltip: '筛选来源和项目',
        padding: EdgeInsets.zero,
        onSelected: (choice) {
          setState(() {
            switch (choice.kind) {
              case _PlazaFilterKind.agent:
                _agentFilter = choice.value.isEmpty ? null : choice.value;
              case _PlazaFilterKind.repo:
                _repoFilter = choice.value.isEmpty ? null : choice.value;
              case _PlazaFilterKind.clear:
                _agentFilter = null;
                _repoFilter = null;
            }
          });
        },
        itemBuilder: (_) => [
          const PopupMenuItem(
            enabled: false,
            height: 28,
            child: Text('来源工具', style: TextStyle(fontSize: 11)),
          ),
          CheckedPopupMenuItem(
            key: const ValueKey('capsule-agent-all'),
            value: const _PlazaFilterChoice(_PlazaFilterKind.agent),
            checked: _agentFilter == null,
            child: const Text('全部来源'),
          ),
          for (final agent in agents)
            CheckedPopupMenuItem(
              key: ValueKey('capsule-agent-$agent'),
              value: _PlazaFilterChoice(_PlazaFilterKind.agent, agent),
              checked: _agentFilter == agent,
              child: Text(_agentName(agent)),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            enabled: false,
            height: 28,
            child: Text('项目 / Repo', style: TextStyle(fontSize: 11)),
          ),
          CheckedPopupMenuItem(
            key: const ValueKey('capsule-repo-all'),
            value: const _PlazaFilterChoice(_PlazaFilterKind.repo),
            checked: _repoFilter == null,
            child: const Text('全部项目'),
          ),
          for (final repo in repos)
            CheckedPopupMenuItem(
              key: ValueKey('capsule-repo-$repo'),
              value: _PlazaFilterChoice(_PlazaFilterKind.repo, repo),
              checked: _repoFilter == repo,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Text(repo, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          if (activeCount > 0) ...[
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: _PlazaFilterChoice(_PlazaFilterKind.clear),
              child: Text('清除来源与项目筛选'),
            ),
          ],
        ],
        icon: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(
              Icons.tune_rounded,
              size: 18,
              color: activeCount == 0 ? CcColors.muted : CcColors.accentBright,
            ),
            if (activeCount > 0)
              Positioned(
                right: -7,
                top: -7,
                child: Container(
                  width: 14,
                  height: 14,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: CcColors.accent,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$activeCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 8.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _agentName(String agent) => switch (agent.toLowerCase()) {
    'codex' => 'Codex',
    'claude' => 'Claude',
    _ => agent,
  };

  Widget _body() => asyncBody(
    loading: _loading && _items == null,
    error: _error,
    onRetry: _load,
    child: () {
      final items = _items ?? const <CapsuleListItem>[];
      if (items.isEmpty) {
        return _emptyState(
          icon: Icons.inventory_2_outlined,
          title: '还没有胶囊',
          detail: '在会话总览中创建胶囊后，它会出现在这里。',
        );
      }
      final filtered = _filteredItems();
      if (filtered.isEmpty) {
        return _emptyState(
          icon: Icons.search_off_rounded,
          title: '没有匹配的胶囊',
          detail: '换一个关键词或调整筛选条件。',
          onClear: _clearFilters,
        );
      }
      return RefreshIndicator(
        onRefresh: _load,
        child: LayoutBuilder(
          builder: (context, constraints) => GridView.builder(
            key: const ValueKey('capsule-grid'),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
            physics: const AlwaysScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: capsuleGridColumnCount(constraints.maxWidth - 28),
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              mainAxisExtent: 280,
            ),
            itemCount: filtered.length,
            itemBuilder: (_, i) => _capsuleCard(filtered[i]),
          ),
        ),
      );
    },
  );

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _scope = CapsulePlazaScope.all;
      _agentFilter = null;
      _repoFilter = null;
    });
  }

  Widget _emptyState({
    required IconData icon,
    required String title,
    required String detail,
    VoidCallback? onClear,
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: CcColors.subtle),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(color: CcColors.subtle, fontSize: 12.5),
          ),
          if (onClear != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.filter_alt_off_rounded, size: 15),
              label: const Text('清除筛选'),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _capsuleCard(CapsuleListItem c) {
    final mine = capsuleOwnedBy(c, widget.identity);
    final isPublic = c.visibility == 'public';
    final title = c.headline.trim().isNotEmpty
        ? c.headline.trim()
        : c.repoName.isNotEmpty
        ? '${c.repoName} 会话胶囊'
        : '未命名胶囊';
    final bindingLabel = c.projectId.isNotEmpty
        ? '项目 ${_relayProjectNames[c.projectId] ?? (c.repoName.isEmpty ? c.projectId : c.repoName)}'
        : c.orgId.isNotEmpty
        ? '团队 ${_organizationNames[c.orgId] ?? c.orgId}'
        : '环境 未绑定';
    return Container(
      key: ValueKey('capsule-card-${c.id}'),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: CcColors.panel,
        borderRadius: BorderRadius.circular(CcRadius.md),
        border: Border.all(color: CcColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              tag(
                isPublic ? '团队共享' : '个人',
                isPublic ? CcColors.accent : CcColors.muted,
              ),
              const Spacer(),
              if (mine)
                PopupMenuButton<_CapsuleOwnerAction>(
                  key: ValueKey('capsule-actions-${c.id}'),
                  tooltip: '更多操作',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 132),
                  onSelected: (action) {
                    switch (action) {
                      case _CapsuleOwnerAction.edit:
                        _editCapsule(c);
                      case _CapsuleOwnerAction.delete:
                        _deleteCapsule(c);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      key: ValueKey('capsule-action-edit-${c.id}'),
                      value: _CapsuleOwnerAction.edit,
                      child: const ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.edit_outlined, size: 17),
                        title: Text('编辑'),
                      ),
                    ),
                    PopupMenuItem(
                      key: ValueKey('capsule-action-delete-${c.id}'),
                      value: _CapsuleOwnerAction.delete,
                      enabled: !_deletingIds.contains(c.id),
                      child: const ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.delete_outline_rounded,
                          size: 17,
                          color: CcColors.danger,
                        ),
                        title: Text(
                          '删除',
                          style: TextStyle(color: CcColors.danger),
                        ),
                      ),
                    ),
                  ],
                  icon: const Icon(Icons.more_horiz_rounded, size: 19),
                )
              else
                const SizedBox(height: 32),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            title,
            key: ValueKey('capsule-title-${c.id}'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              height: 1.3,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            capsuleSummaryPreview(c),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: CcColors.muted,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _metaItem(
                  Icons.person_outline_rounded,
                  '作者 ${c.owner.isEmpty ? "未知" : c.owner}',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _metaItem(
                  c.sourceAgent == 'codex'
                      ? Icons.terminal_rounded
                      : Icons.smart_toy_outlined,
                  '来源 ${_agentName(c.sourceAgent)}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: _metaItem(
                  c.projectId.isNotEmpty
                      ? Icons.folder_outlined
                      : c.orgId.isNotEmpty
                      ? Icons.groups_outlined
                      : Icons.link_off_rounded,
                  bindingLabel,
                ),
              ),
              const SizedBox(width: 10),
              _metaItem(
                Icons.schedule_rounded,
                '更新 ${relativeTime(c.updatedAt)}',
                tooltip: '更新于 ${commitDate(c.updatedAt.toLocal())}',
              ),
            ],
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (_, constraints) =>
                      _payloadBadges(c, compact: constraints.maxWidth < 170),
                ),
              ),
              if (widget.isDesktop && (c.hasTranscript || c.hasPersona)) ...[
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: ValueKey('capsule-load-${c.id}'),
                  onPressed: () => _loadCapsule(c),
                  icon: const Icon(Icons.input_rounded, size: 15),
                  label: const Text('载入'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    minimumSize: const Size(0, 32),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _metaItem(IconData icon, String label, {String? tooltip}) => Tooltip(
    message: tooltip ?? label,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: CcColors.subtle),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CcType.code(size: 10.5, color: CcColors.subtle),
          ),
        ),
      ],
    ),
  );

  Widget _payloadBadges(CapsuleListItem c, {required bool compact}) {
    final badges = <Widget>[
      if (c.hasTranscript)
        _payloadBadge(
          Icons.forum_outlined,
          compact ? null : '会话记录',
          '包含可续接的会话记录',
        ),
      if (c.hasPersona)
        _payloadBadge(
          Icons.badge_outlined,
          compact ? null : '角色说明',
          '包含蒸馏后的角色说明',
        ),
      if (c.skillPackCount > 0)
        _payloadBadge(
          Icons.extension_outlined,
          compact ? null : '技能包 ${c.skillPackCount}',
          '包含 ${c.skillPackCount} 个技能包',
        ),
    ];
    if (badges.isEmpty) {
      return Text(
        '仅元数据',
        style: CcType.code(size: 10.5, color: CcColors.subtle),
      );
    }
    return Wrap(spacing: 5, runSpacing: 4, children: badges);
  }

  Widget _payloadBadge(IconData icon, String? label, String tooltip) => Tooltip(
    message: tooltip,
    child: Container(
      height: 24,
      padding: EdgeInsets.symmetric(horizontal: label == null ? 5 : 7),
      decoration: BoxDecoration(
        color: CcColors.bg.withValues(alpha: 0.32),
        border: Border.all(color: CcColors.border),
        borderRadius: BorderRadius.circular(CcRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: CcColors.muted),
          if (label != null) ...[
            const SizedBox(width: 4),
            Text(label, style: CcType.code(size: 9.5, color: CcColors.muted)),
          ],
        ],
      ),
    ),
  );

  bool _containsCurrentCapsule(CapsuleListItem capsule) =>
      _items?.any((item) => item.id == capsule.id) ?? false;

  Future<void> _deleteCapsule(CapsuleListItem c) async {
    if (!capsuleOwnedBy(c, widget.identity) || !_containsCurrentCapsule(c)) {
      return;
    }
    if (_deletingIds.contains(c.id)) return;
    final client = widget.client;
    final identity = widget.identity;
    final relayUrl = widget.config.relayUrl;
    final token = widget.config.token;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: const Text(
            '删除胶囊?',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: SizedBox(
            width: capsuleDeleteDialogWidth(size),
            child: SingleChildScrollView(
              child: Text(
                '「${c.headline.isEmpty ? c.id : c.headline}」将从广场移除,不可恢复。',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    if (!mounted) return;
    if (!_isCurrentPlazaContext(client, identity, relayUrl, token)) return;
    if (!capsuleOwnedBy(c, identity) || !_containsCurrentCapsule(c)) return;
    if (_deletingIds.contains(c.id)) return;
    setState(() => _deletingIds.add(c.id));
    try {
      await client.deleteCapsule(c.id);
      if (!mounted) return;
      if (!_isCurrentPlazaContext(client, identity, relayUrl, token)) return;
      snack(context, '胶囊已删除');
      _load();
    } catch (e) {
      if (!mounted) return;
      if (!_isCurrentPlazaContext(client, identity, relayUrl, token)) return;
      snack(context, '删除失败: ${errorText(e)}');
    } finally {
      if (mounted && _deletingIds.contains(c.id)) {
        setState(() => _deletingIds.remove(c.id));
      }
    }
  }

  Future<void> _editCapsule(CapsuleListItem c) async {
    if (!capsuleOwnedBy(c, widget.identity) || !_containsCurrentCapsule(c)) {
      return;
    }
    final client = widget.client;
    final identity = widget.identity;
    final relayUrl = widget.config.relayUrl;
    final token = widget.config.token;
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _CapsuleEditDialog(
        client: client,
        capsule: c,
        isCurrentContext: () =>
            _isCurrentPlazaContext(client, identity, relayUrl, token),
      ),
    );
    if (!mounted) return;
    if (!_isCurrentPlazaContext(client, identity, relayUrl, token)) return;
    if (changed == true) _load();
  }

  Future<void> _loadCapsule(CapsuleListItem c) {
    if (!_containsCurrentCapsule(c)) return Future.value();
    final client = widget.client;
    final identity = widget.identity;
    final relayUrl = widget.config.relayUrl;
    final token = widget.config.token;
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CapsuleLoadDialog(
        client: client,
        overviewStore: widget.overviewStore,
        config: widget.config,
        capsule: c,
        isCurrentContext: () =>
            _isCurrentPlazaContext(client, identity, relayUrl, token),
      ),
    );
  }
}

// _crossMachineNote is appended to a loaded capsule's opening prompt. A capsule
// usually comes from another machine, so absolute paths / local scripts / skill
// locations baked into its context may not exist here — tell the session to
// resolve tools by name in the local env instead of assuming paths, and not to
// burn turns re-scanning the whole disk when something isn't where it expected.
const _crossMachineNote =
    '\n\n⚠️ 注意:此上下文可能来自**另一台机器**——里面提到的绝对路径 / 本地脚本 / 技能位置,'
    '在本机可能不存在或位置不同。遇到时**按名字与用途在本机环境(技能、当前仓库、PATH)里找**'
    '对应的技能/脚本/工具,不要假设路径一致;找不到时先在当前仓库定位,别反复全盘搜索。';

// _CapsuleLoadDialog spins up a fresh specialized session from a plaza capsule:
// the receiver picks a form (② distilled role / ① full-context snapshot), a
// target tool (claude/codex — cross-tool works because ① rides as a text seed),
// and a target workspace/project. On confirm it fetches the payload, spawns the
// session, and dispatches an opening message (the ready-gate auto-runs it).
class _CapsuleLoadDialog extends StatefulWidget {
  final RelayClient client;
  final SessionOverviewStore overviewStore;
  final AppConfig config;
  final CapsuleListItem capsule;
  final bool Function() isCurrentContext;
  const _CapsuleLoadDialog({
    required this.client,
    required this.overviewStore,
    required this.config,
    required this.capsule,
    required this.isCurrentContext,
  });

  @override
  State<_CapsuleLoadDialog> createState() => _CapsuleLoadDialogState();
}

class _CapsuleLoadDialogState extends State<_CapsuleLoadDialog> {
  late String _form; // 'role' (②) | 'snapshot' (①)
  late String _tool; // claude | codex
  String? _workspace;
  String? _project;
  final _branchCtl = TextEditingController();
  final _environmentWorkspaceCtl = TextEditingController();
  final _environmentParentCtl = TextEditingController();
  bool _submitting = false;
  Package? _pkg; // fetched once on open, reused by _extractSkillPacks at load
  List<String>? _bundledSkills; // null = still loading
  List<CapsuleEnvironmentTarget> _boundTargets = const [];
  CapsuleEnvironmentTarget? _explicitTarget;
  ProjectDetail? _environmentProject;
  Set<String> _environmentRepoNames = const {};
  bool _environmentChecking = true;
  String? _environmentError;

  @override
  void initState() {
    super.initState();
    // Prefer ② role when available (self-contained); else ① snapshot.
    _form = widget.capsule.hasPersona ? 'role' : 'snapshot';
    // Default target tool = the capsule's source tool (native side).
    _tool = widget.capsule.sourceAgent == 'codex' ? 'codex' : 'claude';
    final ws = widget.config.workspaces;
    if (ws.isNotEmpty) {
      _workspace = ws.first.name;
      _project = ws.first.projects.isEmpty
          ? null
          : ws.first.projects.first.name;
    }
    _loadPackage();
    _resolveBoundEnvironment();
  }

  // _loadPackage fetches the capsule package once: it drives the bundled-skill
  // display now and is reused by _extractSkillPacks at load time (no 2nd get).
  Future<void> _loadPackage() async {
    try {
      final pkg = await widget.client.get(widget.capsule.id);
      if (!mounted || !widget.isCurrentContext()) return;
      setState(() {
        _pkg = pkg;
        _bundledSkills = skillPackNames(pkg.attachments);
      });
    } catch (_) {
      if (mounted && widget.isCurrentContext()) {
        setState(() => _bundledSkills = const []);
      }
    }
  }

  @override
  void dispose() {
    _branchCtl.dispose();
    _environmentWorkspaceCtl.dispose();
    _environmentParentCtl.dispose();
    super.dispose();
  }

  List<ProjectCfg> get _projects => projectsOf(widget.config, _workspace);

  ProjectCfg? get _selectedProject {
    final m = _projects.where((p) => p.name == _project);
    return m.isEmpty ? null : m.first;
  }

  bool get _explicitTargetSelected =>
      _explicitTarget != null &&
      _explicitTarget!.workspace == _workspace &&
      _explicitTarget!.project == _project;

  String? get _projectPath => _explicitTargetSelected
      ? _explicitTarget!.workdir
      : _selectedProject?.path;

  String? get _targetWorkspace => _workspace;

  String? get _targetProject => _project;

  String? get _targetProjectId => _explicitTargetSelected
      ? _explicitTarget!.projectId
      : _selectedProject?.projectId;

  List<String> get _workspaceNames {
    final names = [
      for (final workspace in widget.config.workspaces) workspace.name,
    ];
    final explicit = _explicitTarget?.workspace;
    if (explicit != null && !names.contains(explicit)) names.add(explicit);
    return names;
  }

  List<String> get _projectNames {
    final names = [for (final project in _projects) project.name];
    final explicit = _explicitTarget;
    if (explicit != null &&
        explicit.workspace == _workspace &&
        !names.contains(explicit.project)) {
      names.add(explicit.project);
    }
    return names;
  }

  String _defaultEnvironmentParent() {
    var root = widget.config.workspaceRoot.trim();
    if (root.isEmpty) root = '~/cc-handoff-workspaces';
    final home = Platform.environment['HOME'] ?? '';
    if (root == '~' && home.isNotEmpty) return home;
    if (root.startsWith('~/') && home.isNotEmpty) {
      return '$home${root.substring(1)}';
    }
    return root;
  }

  String _safeEnvironmentWorkspaceName(String value) {
    var result = value.trim().replaceAll(
      RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]+'),
      '-',
    );
    result = result.replaceAll(RegExp(r'[- ]{2,}'), '-');
    result = result.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
    return result.isEmpty ? 'team-project' : result;
  }

  CapsuleEnvironmentTarget? _preferredTarget(
    List<CapsuleEnvironmentTarget> targets,
  ) {
    if (targets.isEmpty) return null;
    final repoName = widget.capsule.repoName.trim();
    if (repoName.isNotEmpty) {
      for (final target in targets) {
        if (target.project == repoName) return target;
      }
      return null;
    }
    return targets.first;
  }

  void _selectBoundTarget(CapsuleEnvironmentTarget target) {
    _explicitTarget = target;
    _workspace = target.workspace;
    _project = target.project;
  }

  Future<void> _resolveBoundEnvironment() async {
    final projectID = widget.capsule.projectId.trim();
    if (projectID.isEmpty) {
      if (mounted) setState(() => _environmentChecking = false);
      return;
    }
    final local = widget.overviewStore.resolveCapsuleEnvironment(projectID);
    final localPreferred = _preferredTarget(local);
    if (localPreferred != null) {
      if (!mounted) return;
      setState(() {
        _boundTargets = local;
        _selectBoundTarget(localPreferred);
        _environmentChecking = false;
      });
      return;
    }
    try {
      final detail = await widget.client.project(projectID);
      if (!mounted || !widget.isCurrentContext()) return;
      final cloneable = detail.cloneableRepos;
      final sourceRepo = widget.capsule.repoName.trim();
      final sourceAvailable =
          sourceRepo.isEmpty ||
          cloneable.any((repo) => repo.repoName == sourceRepo);
      setState(() {
        _environmentProject = cloneable.isNotEmpty && sourceAvailable
            ? detail
            : null;
        _environmentRepoNames = sourceRepo.isEmpty
            ? {for (final repo in cloneable) repo.repoName}
            : sourceAvailable
            ? {sourceRepo}
            : const {};
        _environmentWorkspaceCtl.text = _safeEnvironmentWorkspaceName(
          detail.project.name,
        );
        _environmentParentCtl.text = _defaultEnvironmentParent();
        _environmentChecking = false;
        if (cloneable.isEmpty) {
          _environmentError = '项目尚未绑定可拉取的 GitHub 仓库，可改用下方现有本地项目';
        } else if (!sourceAvailable) {
          _environmentError = '胶囊来源仓库 $sourceRepo 已从项目解绑，请选择下方匹配的本地项目';
        }
      });
    } catch (e) {
      if (!mounted || !widget.isCurrentContext()) return;
      setState(() {
        _environmentChecking = false;
        _environmentError = '无法读取绑定项目：${errorText(e)}';
      });
    }
  }

  Future<bool> _prepareEnvironmentIfNeeded() async {
    if (widget.capsule.projectId.trim().isEmpty ||
        _boundTargets.isNotEmpty ||
        _environmentProject == null ||
        _environmentProject!.cloneableRepos.isEmpty) {
      return true;
    }
    final workspaceName = _environmentWorkspaceCtl.text.trim();
    final parent = _environmentParentCtl.text.trim();
    if (workspaceName.isEmpty ||
        parent.isEmpty ||
        _environmentRepoNames.isEmpty) {
      _fail('请选择要载入的仓库和本地位置');
      return false;
    }
    final repos = [
      for (final repo in _environmentProject!.cloneableRepos)
        if (_environmentRepoNames.contains(repo.repoName))
          CapsuleEnvironmentRepo(repo.repoName, repo.cloneUrl),
    ];
    final (result, error) = await widget.overviewStore
        .prepareCapsuleEnvironment(
          CapsuleEnvironmentRequest(
            projectId: widget.capsule.projectId,
            workspaceName: workspaceName,
            parentDirectory: parent,
            repos: repos,
          ),
        );
    if (!mounted || _closeIfStaleContext()) return false;
    if (result == null || result.targets.isEmpty) {
      _fail('载入项目环境失败：${error ?? "未知错误"}');
      return false;
    }
    final preferred = _preferredTarget(result.targets);
    if (preferred == null) {
      final sourceRepo = widget.capsule.repoName.trim();
      _fail(
        '来源仓库 $sourceRepo 未成功载入，已停止恢复会话'
        '${result.errors.isEmpty ? "" : "：${result.errors.join("；")}"}',
      );
      return false;
    }
    setState(() {
      _boundTargets = result.targets;
      _selectBoundTarget(preferred);
      _environmentError = result.errors.isEmpty
          ? null
          : '部分仓库未载入：${result.errors.join("；")}';
    });
    return true;
  }

  // _wouldNativeResume is true for ① when the target tool matches the source:
  // the raw transcript can be imported locally and byte-exact `--resume`d.
  bool get _wouldNativeResume =>
      _form == 'snapshot' && _tool == widget.capsule.sourceAgent;

  void _fail(String msg) {
    if (mounted) setState(() => _submitting = false);
    snack(context, msg);
  }

  bool _closeIfStaleContext() {
    if (widget.isCurrentContext()) return false;
    Navigator.of(context).pop();
    return true;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (_environmentChecking) {
      snack(context, '正在检查绑定项目环境');
      return;
    }
    if (_closeIfStaleContext()) return;
    setState(() => _submitting = true);
    try {
      if (!await _prepareEnvironmentIfNeeded()) return;
      final ws = _targetWorkspace, proj = _targetProject;
      final projPath = _projectPath;
      if (ws == null || proj == null || projPath == null) {
        _fail('请选择目标工作区 / 项目');
        return;
      }
      // Place any bundled skill packs into the local skills dir first, so the
      // session (resumed or seeded) can use them immediately.
      final skills = await _extractSkillPacks();
      if (!mounted) return;
      if (_closeIfStaleContext()) return;

      // ① same-tool: import the raw log locally → native `--resume` (highest
      // fidelity). Falls through to the seed path if it can't be set up.
      if (_wouldNativeResume) {
        final resumeId = await _importForResume(projPath);
        if (!mounted) return;
        if (_closeIfStaleContext()) return;
        if (resumeId != null) {
          final (sid, err) = await widget.overviewStore.spawn(
            workspace: ws,
            project: proj,
            kind: _tool,
            projectId: _targetProjectId,
            resumeAgentSessionId: resumeId,
            workdir: projPath,
          );
          if (!mounted) return;
          if (_closeIfStaleContext()) return;
          if (sid == null) {
            _fail('起会话失败: ${err ?? "未知错误"}');
            return;
          }
          Navigator.of(context).pop();
          snack(context, '已原样恢复(--resume)新会话到工作区');
          return;
        }
      }

      // Seed path: ② role, ① cross-tool, or native import unavailable.
      final prompt = await _buildOpeningPrompt(skills);
      if (!mounted) return;
      if (_closeIfStaleContext()) return;
      if (prompt == null) {
        _fail('拉取胶囊内容失败');
        return;
      }
      final branch = _branchCtl.text.trim();
      final (sid, err) = await widget.overviewStore.spawn(
        workspace: ws,
        project: proj,
        kind: _tool,
        projectId: _targetProjectId,
        newWorktreeBranch: branch.isEmpty ? null : branch,
      );
      if (!mounted) return;
      if (_closeIfStaleContext()) return;
      if (sid == null) {
        _fail('起会话失败: ${err ?? "未知错误"}');
        return;
      }
      // Dispatch immediately after spawn, like 待办指派→新建会话. The live
      // WorkspacePage owns the TerminalSession and deliverLocalMessage will see
      // the fresh session as !ready, then queue through wakeAndDeliver until the
      // boot-ready watch flushes it. Waiting on the overview card's workdir is
      // only a metadata poll; it can move this first prompt out of the protected
      // queue path and back into a paste-vs-boot timing window.
      String? dispErr;
      try {
        dispErr = widget.overviewStore.dispatch(
          LocalMsg('', sid, prompt, true),
        );
      } catch (e) {
        dispErr = errorText(e);
      }
      if (dispErr != null) {
        _fail('会话已起,但投递开场失败: $dispErr');
        return;
      }
      Navigator.of(context).pop();
      snack(context, '已载入胶囊,新会话开跑');
    } catch (e) {
      if (!mounted) return;
      if (_closeIfStaleContext()) return;
      _fail('载入失败: ${errorText(e)}');
    }
  }

  // _importForResume downloads transcript.jsonl and writes it into the local
  // agent store, returning the id to `--resume`, or null to fall back to seed.
  Future<String?> _importForResume(String projPath) async {
    // claude needs the origin id as the local filename — skip the (multi-MB)
    // download when we don't have it and let the caller fall back to seed.
    if (_tool != 'codex' && widget.capsule.originSessionId.isEmpty) return null;
    final bytes = await _fetchBytes('transcript.jsonl');
    if (bytes == null) return null;
    return importCapsuleTranscriptForResume(
      agentKind: _tool,
      bytes: bytes,
      workdir: projPath,
      originId: widget.capsule.originSessionId,
      now: DateTime.now(),
    );
  }

  Future<List<int>?> _fetchBytes(String name) async {
    try {
      final pkg = _pkg ?? await widget.client.get(widget.capsule.id);
      if (!widget.isCurrentContext()) return null;
      _pkg ??= pkg;
      Attachment? metadata;
      for (final attachment in pkg.attachments) {
        if (attachment.name == name) {
          metadata = attachment;
          break;
        }
      }
      if (metadata == null) return null;
      return await widget.client.attachment(
        widget.capsule.id,
        name,
        expectedSha256: metadata.sha256,
        expectedSize: metadata.size,
      );
    } catch (_) {
      return null;
    }
  }

  // _buildOpeningPrompt fetches the chosen form's payload and wraps it into the
  // new session's first turn. Returns null if the payload can't be fetched.
  Future<String?> _buildOpeningPrompt(List<String> skills) async {
    final c = widget.capsule;
    final skillsNote = skills.isEmpty
        ? ''
        : '\n\n胶囊自带的技能已落到本机 `${skillsDirLabel(_tool)}/`:${skills.join('、')} —— 需要时直接用 `/<名字>` 调用,不用再去别处找。';
    if (_form == 'role') {
      final body = await _fetchText('persona.md');
      if (body == null) return null;
      return '你现在是一个「专职会话」。下面是你的角色定义(来自胶囊 ${c.id}),'
          '请把它作为工作准则严格遵守,不要复述它。读完后用一两句话说明你将专注做什么,然后待命。\n\n'
          '---\n$body\n---$_crossMachineNote$skillsNote';
    }
    // ① snapshot: prefer the compact seed, else the full neutral transcript.
    // Try seed.md directly (returns null when absent) rather than a get(c.id)
    // round-trip just to enumerate attachment names.
    final body =
        await _fetchText('seed.md') ?? await _fetchText('transcript.txt');
    if (body == null) return null;
    return '下面是另一个会话冻结下来的上下文(来自胶囊 ${c.id},源工具 ${c.sourceAgent})。'
        '请把它当作你自己的前情:先读完,用一两句话复述「目标 / 已完成 / 当前进度 / 待办」,'
        '确认理解后无缝接着干。\n\n---\n$body\n---$_crossMachineNote$skillsNote';
  }

  // _extractSkillPacks downloads the capsule's bundled skill packs (attachments
  // ending in .skillpack.zip) and unzips each into the LOADED tool's skills dir
  // (Claude ~/.claude/skills, Codex ~/.codex/skills) — SKILL.md is the shared
  // open standard, so the same pack works in either. Returns the installed
  // skill names (for the opening prompt), so the session has them even on a
  // machine that never installed the skill.
  Future<List<String>> _extractSkillPacks() async {
    final pkg = _pkg ?? await widget.client.get(widget.capsule.id);
    final names = <String>[];
    for (final a in pkg.attachments) {
      if (!isCapsuleSkillPack(a.name)) continue;
      final bytes = await _fetchBytes(a.name);
      if (bytes == null) continue;
      final name = await installSkillPack(bytes, a.name, tool: _tool);
      if (name != null) names.add(name);
    }
    return names;
  }

  Future<String?> _fetchText(String name) async {
    final bytes = await _fetchBytes(name);
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  List<DropdownMenuItem<String>> _stringItems(Iterable<String> values) => [
    for (final value in values)
      DropdownMenuItem(
        value: value,
        child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
  ];

  Future<void> _pickEnvironmentParent() async {
    final value = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择团队项目 workspace 的父目录',
    );
    if (!mounted || value == null || value.trim().isEmpty) return;
    _environmentParentCtl.text = value.trim();
    setState(() {});
  }

  Widget _environmentPanel() {
    final projectID = widget.capsule.projectId.trim();
    final sourceRepo = widget.capsule.repoName.trim();
    if (projectID.isEmpty) return const SizedBox.shrink();
    if (_environmentChecking) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Row(
          key: ValueKey('capsule-environment-checking'),
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('检查绑定项目环境…', style: TextStyle(fontSize: 12)),
          ],
        ),
      );
    }
    if (_boundTargets.isNotEmpty) {
      final selected = _explicitTarget ?? _preferredTarget(_boundTargets)!;
      return Container(
        key: const ValueKey('capsule-environment-ready'),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: CcColors.ok.withValues(alpha: 0.55)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.check_circle_outline_rounded,
                  size: 17,
                  color: CcColors.ok,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '项目环境已就绪 · ${selected.workspace} / ${selected.project}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            if (_boundTargets.length > 1) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: const ValueKey('capsule-environment-target'),
                initialValue: selected.workdir,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '本地仓库',
                  isDense: true,
                ),
                items: [
                  for (final target in _boundTargets)
                    DropdownMenuItem(
                      value: target.workdir,
                      child: Text(
                        '${target.workspace} / ${target.project}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _submitting
                    ? null
                    : (workdir) {
                        if (workdir == null) return;
                        setState(() {
                          _selectBoundTarget(
                            _boundTargets.firstWhere(
                              (target) => target.workdir == workdir,
                            ),
                          );
                        });
                      },
              ),
            ],
            if (_environmentError != null) ...[
              const SizedBox(height: 6),
              Text(
                _environmentError!,
                style: const TextStyle(color: CcColors.warning, fontSize: 11.5),
              ),
            ],
          ],
        ),
      );
    }
    final detail = _environmentProject;
    return Container(
      key: const ValueKey('capsule-environment-missing'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: CcColors.warning.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(
                Icons.cloud_download_outlined,
                size: 17,
                color: CcColors.warning,
              ),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  '本机没有该项目环境，将先拉取再恢复会话',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (detail != null && detail.cloneableRepos.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final repo in detail.cloneableRepos)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _environmentRepoNames.contains(repo.repoName),
                title: Text(
                  repo.repoName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 11.5),
                ),
                onChanged: _submitting || repo.repoName == sourceRepo
                    ? null
                    : (selected) => setState(() {
                        final next = Set<String>.from(_environmentRepoNames);
                        selected == true
                            ? next.add(repo.repoName)
                            : next.remove(repo.repoName);
                        _environmentRepoNames = next;
                      }),
              ),
            const SizedBox(height: 6),
            TextField(
              key: const ValueKey('capsule-environment-workspace'),
              controller: _environmentWorkspaceCtl,
              enabled: !_submitting,
              decoration: const InputDecoration(
                labelText: '本地 workspace 名称',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('capsule-environment-parent'),
              controller: _environmentParentCtl,
              readOnly: true,
              enabled: !_submitting,
              decoration: InputDecoration(
                labelText: '父目录',
                isDense: true,
                suffixIcon: IconButton(
                  tooltip: '选择目录',
                  onPressed: _submitting ? null : _pickEnvironmentParent,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                ),
              ),
            ),
          ],
          if (_environmentError != null) ...[
            const SizedBox(height: 8),
            Text(
              _environmentError!,
              style: const TextStyle(color: CcColors.warning, fontSize: 11.5),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      PopScope(canPop: !_submitting, child: _buildDialog(context));

  Widget _buildDialog(BuildContext context) {
    final c = widget.capsule;
    final screenSize = MediaQuery.sizeOf(context);
    final dialogSize = capsuleLoadDialogSize(screenSize);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogSize.width,
          maxHeight: dialogSize.height,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.download_rounded,
                      size: 20,
                      color: CcColors.accent,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '载入胶囊',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '关闭',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  c.headline.isEmpty ? '(无说明)' : c.headline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.code(size: 12, color: CcColors.subtle),
                ),
                if (_bundledSkills != null && _bundledSkills!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _sectionLabel('自带技能'),
                  _skillWrap(_bundledSkills!),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '起会话时自动装到本机 ${skillsDirLabel(_tool)}/',
                      style: CcType.code(size: 11, color: CcColors.subtle),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                _sectionLabel('形态'),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'role',
                      enabled: c.hasPersona,
                      label: const Text('② 蒸馏角色'),
                    ),
                    ButtonSegment(
                      value: 'snapshot',
                      enabled: c.hasTranscript,
                      label: const Text('① 完整快照'),
                    ),
                  ],
                  selected: {_form},
                  onSelectionChanged: _submitting
                      ? null
                      : (s) => setState(() => _form = s.first),
                ),
                if (_form == 'snapshot')
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _wouldNativeResume
                          ? '同工具:拉原始日志到本地,原样 --resume(项目根,忽略 worktree 分支)'
                          : '跨工具:以中性转录作上下文 seed 起新会话',
                      style: CcType.code(size: 11, color: CcColors.subtle),
                    ),
                  ),
                const SizedBox(height: 12),
                _sectionLabel('目标工具'),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'claude', label: Text('Claude')),
                    ButtonSegment(value: 'codex', label: Text('Codex')),
                  ],
                  selected: {_tool},
                  onSelectionChanged: _submitting
                      ? null
                      : (s) => setState(() => _tool = s.first),
                ),
                const SizedBox(height: 12),
                _sectionLabel('关联环境'),
                _environmentPanel(),
                const SizedBox(height: 12),
                _sectionLabel('目标位置'),
                DropdownButton<String>(
                  isExpanded: true,
                  menuMaxHeight: capsuleLoadMenuMaxHeight(screenSize),
                  hint: const Text('workspace'),
                  value: _workspace,
                  items: _stringItems(_workspaceNames),
                  onChanged: _submitting
                      ? null
                      : (v) => setState(() {
                          if (_explicitTarget?.workspace != v) {
                            _explicitTarget = null;
                          }
                          _workspace = v;
                          final projects = _projectNames;
                          _project = projects.isEmpty ? null : projects.first;
                        }),
                ),
                const SizedBox(height: 8),
                DropdownButton<String>(
                  isExpanded: true,
                  menuMaxHeight: capsuleLoadMenuMaxHeight(screenSize),
                  hint: const Text('project'),
                  value: _project,
                  items: _stringItems(_projectNames),
                  onChanged: _submitting
                      ? null
                      : (v) => setState(() {
                          if (_explicitTarget?.project != v) {
                            _explicitTarget = null;
                          }
                          _project = v;
                        }),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _branchCtl,
                  enabled: !_submitting,
                  decoration: const InputDecoration(
                    labelText: '新建 worktree 分支名(可选)',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _submitting ? null : _submit,
                      icon: _submitting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.rocket_launch_rounded, size: 16),
                      label: Text(
                        _environmentProject != null &&
                                _environmentProject!
                                    .cloneableRepos
                                    .isNotEmpty &&
                                _boundTargets.isEmpty
                            ? '载入环境并起会话'
                            : '起会话',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// bundledSkillNames lists the skill names a capsule carries (its
// .skillpack.zip attachments) — for display in the load / edit dialogs so both
// sides can see what rides along. Best-effort: [] on any fetch error.
Future<List<String>> bundledSkillNames(RelayClient client, String id) async {
  try {
    final pkg = await client.get(id);
    return skillPackNames(pkg.attachments);
  } catch (_) {
    return const [];
  }
}

// fetchCapsuleText downloads one capsule attachment and utf8-decodes it, or
// null if absent/unfetchable — shared by the load / edit dialogs.
Future<String?> fetchCapsuleText(
  RelayClient client,
  String id,
  String name,
) async {
  try {
    final b = await client.attachment(id, name);
    return utf8.decode(b, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

// _skillChip is the shared little pill used to show a bundled skill name.
Widget _skillChip(String name) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
  decoration: BoxDecoration(
    border: Border.all(color: CcColors.accent, width: 1),
    borderRadius: BorderRadius.circular(6),
  ),
  child: Text('/$name', style: CcType.code(size: 11.5, color: CcColors.accent)),
);

// _skillWrap lays out bundled-skill chips (shared by the load / edit dialogs).
Widget _skillWrap(List<String> names) => Wrap(
  spacing: 6,
  runSpacing: 6,
  children: [for (final s in names) _skillChip(s)],
);

// _sectionLabel is the shared bold section header used across the dialogs.
Widget _sectionLabel(String s) => Padding(
  padding: const EdgeInsets.only(bottom: 4),
  child: Text(s, style: const TextStyle(fontWeight: FontWeight.w600)),
);

// _CapsuleEditDialog lets an owner edit their plaza capsule's visibility and
// description (summary), and view its distilled content (persona / seed) plus
// the skills it bundles. Persona/seed content editing is a separate step.
class _CapsuleEditDialog extends StatefulWidget {
  final RelayClient client;
  final CapsuleListItem capsule;
  final bool Function() isCurrentContext;
  const _CapsuleEditDialog({
    required this.client,
    required this.capsule,
    required this.isCurrentContext,
  });

  @override
  State<_CapsuleEditDialog> createState() => _CapsuleEditDialogState();
}

class _CapsuleEditDialogState extends State<_CapsuleEditDialog> {
  late bool _public;
  late final TextEditingController _summary;
  bool _saving = false;
  List<String>? _skills; // null until the content fetch completes (loading)
  String _persona = '';
  String _seed = '';
  CapsuleBindingCatalog? _bindingCatalog;
  late CapsuleBinding _binding;
  String? _bindingError;

  @override
  void initState() {
    super.initState();
    _public = widget.capsule.visibility == 'public';
    _binding = CapsuleBinding(
      orgId: widget.capsule.orgId,
      projectId: widget.capsule.projectId,
    );
    _summary = TextEditingController(text: widget.capsule.headline);
    _load();
  }

  Future<void> _load() async {
    // Kick all three fetches off before awaiting so they run concurrently.
    final id = widget.capsule.id;
    final skillsF = bundledSkillNames(widget.client, id);
    final personaF = fetchCapsuleText(widget.client, id, 'persona.md');
    final seedF = fetchCapsuleText(widget.client, id, 'seed.md');
    final bindingsF = _loadBindings();
    final skills = await skillsF;
    final persona = await personaF;
    final seed = await seedF;
    final bindings = await bindingsF;
    if (!mounted || !widget.isCurrentContext()) return;
    setState(() {
      _skills = skills;
      _persona = persona ?? '';
      _seed = seed ?? '';
      _bindingCatalog = bindings.$1;
      _bindingError = bindings.$2;
      if (_binding.orgId.isEmpty && _binding.projectId.isNotEmpty) {
        for (final project in bindings.$1?.projects ?? const []) {
          if (project.id == _binding.projectId) {
            _binding = CapsuleBinding(
              orgId: project.orgId,
              projectId: project.id,
            );
            break;
          }
        }
      }
    });
  }

  Future<(CapsuleBindingCatalog?, String?)> _loadBindings() async {
    try {
      final values = await Future.wait<Object>([
        widget.client.organizations(),
        widget.client.projects(),
      ]);
      final orgs = values[0] as List<Organization>;
      final projects = values[1] as List<Project>;
      return (
        CapsuleBindingCatalog(
          teams: [for (final org in orgs) CapsuleBindingTeam(org.id, org.name)],
          projects: [
            for (final project in projects)
              CapsuleBindingProject(project.id, project.orgId, project.name),
          ],
        ),
        null,
      );
    } catch (e) {
      return (null, errorText(e));
    }
  }

  // _readonlyBox renders a labeled, scrollable, selectable preview of capsule
  // content (persona / seed). Content editing is a separate step.
  Widget _readonlyBox(String label, String text) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _sectionLabel(label),
      Container(
        width: double.infinity,
        constraints: BoxConstraints(
          maxHeight: capsuleReadonlyPreviewMaxHeight(
            MediaQuery.sizeOf(context),
          ),
        ),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: CcColors.subtle),
          borderRadius: BorderRadius.circular(6),
        ),
        child: SingleChildScrollView(
          child: SelectableText(
            text.trim().isEmpty ? '(空)' : text.trim(),
            style: const TextStyle(fontSize: 11.5, height: 1.4),
          ),
        ),
      ),
    ],
  );

  @override
  void dispose() {
    _summary.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final initialBinding = CapsuleBinding(
      orgId: widget.capsule.orgId,
      projectId: widget.capsule.projectId,
    );
    final scopeChanged =
        _public != (widget.capsule.visibility == 'public') ||
        _binding.orgId != initialBinding.orgId ||
        _binding.projectId != initialBinding.projectId;
    if (_public && _binding.orgId.trim().isEmpty && scopeChanged) {
      snack(context, '团队共享胶囊必须选择一个团队');
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.client.patchCapsule(
        widget.capsule.id,
        visibility: scopeChanged ? (_public ? 'public' : 'private') : null,
        summary: _summary.text.trim(),
        orgId: scopeChanged ? _binding.orgId : null,
        projectId: scopeChanged ? _binding.projectId : null,
      );
      if (!mounted || !widget.isCurrentContext()) return;
      Navigator.of(context).pop(true);
      snack(context, '已保存');
    } catch (e) {
      if (!mounted || !widget.isCurrentContext()) return;
      setState(() => _saving = false);
      snack(context, '保存失败: ${errorText(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dialogSize = capsuleEditDialogSize(MediaQuery.sizeOf(context));
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        width: dialogSize.width,
        height: dialogSize.height,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.edit_rounded,
                            size: 20,
                            color: CcColors.accent,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '编辑胶囊',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: '关闭',
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () => Navigator.of(context).pop(false),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('capsule-edit-summary'),
                        controller: _summary,
                        decoration: const InputDecoration(
                          labelText: '说明',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 14),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: false,
                            label: Text('个人'),
                            icon: Icon(Icons.lock_outline_rounded, size: 16),
                          ),
                          ButtonSegment(
                            value: true,
                            label: Text('团队'),
                            icon: Icon(Icons.public_rounded, size: 16),
                          ),
                        ],
                        selected: {_public},
                        onSelectionChanged: (s) =>
                            setState(() => _public = s.first),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _public ? '同团队成员能在广场看到' : '只有你自己能在广场看到',
                        style: CcType.code(size: 11.5, color: CcColors.subtle),
                      ),
                      const SizedBox(height: 12),
                      CapsuleBindingPicker(
                        catalog: _bindingCatalog,
                        binding: _binding,
                        enabled: !_saving,
                        error: _bindingError,
                        onChanged: (binding) =>
                            setState(() => _binding = binding),
                      ),
                      const SizedBox(height: 14),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      if (_skills == null)
                        const Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('读取胶囊内容…', style: TextStyle(fontSize: 12)),
                          ],
                        )
                      else ...[
                        _sectionLabel('自带技能'),
                        if (_skills!.isEmpty)
                          Text(
                            '(无)',
                            style: CcType.code(
                              size: 11.5,
                              color: CcColors.subtle,
                            ),
                          )
                        else
                          _skillWrap(_skills!),
                        const SizedBox(height: 12),
                        _readonlyBox('专职角色 (persona)', _persona),
                        const SizedBox(height: 12),
                        _readonlyBox('上下文摘要 (seed)', _seed),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded, size: 16),
                    label: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
