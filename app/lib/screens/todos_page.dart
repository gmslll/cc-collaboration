import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../api/todo_models.dart';
import '../local/cli.dart';
import '../local/config.dart';
import '../local/local_bus.dart';
import '../local/repo_config.dart';
import '../local/session_overview.dart';
import '../local/todo_store.dart';
import '../theme.dart';
import '../widgets.dart';
import '../widgets/markdown_lite_editor.dart';
import '../widgets/todo_attachment_thumb.dart';
import '../widgets/todo_card.dart';
import '../widgets/todo_property_controls.dart';
import 'todo_detail_view.dart';

// The desktop/wide breakpoint (matches RemoteWorkspacePage's dual-pane vs
// single-column threshold) — below this, TodosPage drops the board/list
// split entirely and switches to a full-screen mobile card stream.
const double _wideBreakpoint = 720;

// _BoardColumnDef drives both the kanban board's columns and the mobile
// card stream's collapsible groups, so they always agree on what "Backlog /
// In Progress / Done / Cancelled" means — In Progress folds assigned +
// in_progress + blocked together (TodoCard flags blocked with its own badge
// so it never fully disappears into the crowd), and dropStatus is what a
// card's status becomes when dropped into that column on the board.
typedef _BoardColumnDef = ({
  String title,
  Set<TodoStatus> statuses,
  TodoStatus dropStatus,
});

const List<_BoardColumnDef> _boardColumnDefs = [
  (
    title: 'Backlog',
    statuses: {TodoStatus.pending},
    dropStatus: TodoStatus.pending,
  ),
  (
    title: 'In Progress',
    statuses: {TodoStatus.assigned, TodoStatus.inProgress, TodoStatus.blocked},
    dropStatus: TodoStatus.inProgress,
  ),
  (title: 'Done', statuses: {TodoStatus.done}, dropStatus: TodoStatus.done),
  (
    title: 'Cancelled',
    statuses: {TodoStatus.cancelled},
    dropStatus: TodoStatus.cancelled,
  ),
];

// _LinearImportRepo is a local project whose .cc-handoff.toml configures
// [integrations.linear] team_key — the "从 Linear 导入" header button is only
// offered when at least one exists (see _TodosPageState._loadLinearRepos).
typedef _LinearImportRepo = ({String name, String path, String teamKey});

// TodosPage is the top-level 待办 destination: a filterable list (left) + the
// selected todo's detail/edit panel (right), mirroring HandoffsPage's split
// layout. All scope/status/project filtering happens in memory over
// TodoStore.all — no extra network requests fire on filter changes.
class TodosPage extends StatefulWidget {
  final RelayClient client;
  final AppConfig config;
  final Me me;
  final TodoStore store;
  final SessionOverviewStore overviewStore;
  // onOpenSession backs the detail view's "打开/恢复会话" button: switches
  // the host's top-level nav to the 工作区 tab before focusing the session
  // (mirrors main.dart's _openSessionInWorkspace, already used the same way
  // by SessionOverviewPage) — TodosPage is a nav sibling of 工作区, not
  // inside it, so opening a session here needs that extra tab switch.
  final void Function(String sid)? onOpenSession;

  const TodosPage({
    super.key,
    required this.client,
    required this.config,
    required this.me,
    required this.store,
    required this.overviewStore,
    this.onOpenSession,
  });

  @override
  State<TodosPage> createState() => _TodosPageState();
}

class _TodosPageState extends State<TodosPage> {
  String _scope = 'personal'; // personal | team | all
  final Set<TodoStatus> _statusFilter = {};
  String? _projectFilter; // project id, only meaningful when _scope == 'team'
  Todo? _selected;
  bool _boardView = true; // board is the default, Linear-flavored view
  final Set<String> _collapsedMobileGroups = {};
  final _detailKey = GlobalKey<TodoDetailViewState>();
  List<_LinearImportRepo> _linearRepos = [];
  bool _importingLinear = false;

  RelayClient get _client => widget.client;
  AppConfig get _cfg => widget.config;
  Me get _me => widget.me;
  TodoStore get _store => widget.store;
  SessionOverviewStore get _overview => widget.overviewStore;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    // onComment fires on todo.comment_created — reload the detail view's
    // comment list if that's the todo currently open (TodoStore itself
    // doesn't model comments, it just flags which todo needs a reload).
    _store.onComment = _onComment;
    _loadLinearRepos();
  }

  // _loadLinearRepos scans every locally-tracked project (across all
  // workspaces) for one whose .cc-handoff.toml sets [integrations.linear]
  // team_key — see repo_config_page.dart for the same RepoConfig.load
  // read path. Best-effort: a project with no/unreadable .cc-handoff.toml
  // is silently skipped rather than failing the whole scan.
  Future<void> _loadLinearRepos() async {
    final found = <_LinearImportRepo>[];
    for (final entry in _cfg.repos.entries) {
      try {
        final c = await RepoConfig.load(entry.value);
        final key = c.teamKey.trim();
        if (key.isNotEmpty) {
          found.add((name: entry.key, path: entry.value, teamKey: key));
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _linearRepos = found);
  }

  // _importFromLinear shells `cc-handoff todo import-linear` (Cli.
  // todoImportLinear) in whichever local repo's team_key applies, scoped to
  // the currently-selected team project filter (personal todos when no
  // project is selected). See internal/linear/import.go for the server-side
  // upsert-by-source_ref logic this triggers.
  Future<void> _importFromLinear() async {
    if (_importingLinear) return;
    final repo =
        _linearRepos.length == 1 ? _linearRepos.first : await _pickLinearRepo();
    if (repo == null) return;
    setState(() => _importingLinear = true);
    try {
      final out = await Cli.todoImportLinear(
        repoPath: repo.path,
        teamKey: repo.teamKey,
        projectId: _projectFilter,
      );
      if (mounted) snack(context, out.isNotEmpty ? out : '已从 Linear 导入');
      await _store.refresh();
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _importingLinear = false);
    }
  }

  Future<_LinearImportRepo?> _pickLinearRepo() {
    return showDialog<_LinearImportRepo>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('从哪个项目的 Linear team 导入？'),
        children: _linearRepos
            .map((r) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, r),
                  child: Text('${r.name} (${r.teamKey})'),
                ))
            .toList(),
      ),
    );
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    if (identical(_store.onComment, _onComment)) _store.onComment = null;
    super.dispose();
  }

  void _onComment(String todoId) {
    if (_selected?.id == todoId) _detailKey.currentState?.reloadComments();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    setState(() {
      final sel = _selected;
      if (sel != null) {
        final match = _store.all.where((t) => t.id == sel.id);
        _selected = match.isEmpty ? null : match.first;
      }
    });
  }

  List<Todo> get _filtered {
    final items = _store.all.where((t) {
      if (_scope == 'personal' && !t.isPersonal) return false;
      if (_scope == 'team' && t.isPersonal) return false;
      if (_scope == 'team' &&
          _projectFilter != null &&
          t.projectId != _projectFilter) {
        return false;
      }
      if (_statusFilter.isNotEmpty && !_statusFilter.contains(t.status)) {
        return false;
      }
      return true;
    }).toList();
    items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return items;
  }

  // _projectName resolves a team todo's project id to its display name for
  // TodoCard's tag row — TodoCard itself stays decoupled from Me so it's
  // reusable from contexts (e.g. a future workspace sidebar) that don't
  // necessarily have the full Me/projects list in scope.
  String? _projectName(Todo t) {
    if (t.projectId == null) return null;
    for (final p in _me.projects) {
      if (p.id == t.projectId) return p.name;
    }
    return null;
  }

  Color _statusColor(TodoStatus s) => switch (s) {
    TodoStatus.done => CcColors.ok,
    TodoStatus.cancelled => CcColors.subtle,
    TodoStatus.blocked => CcColors.danger,
    TodoStatus.inProgress => CcColors.accent,
    TodoStatus.assigned => CcColors.warning,
    TodoStatus.pending => CcColors.muted,
  };

  Future<void> _createDialog() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _QuickCreateDialog(
        client: _client,
        me: _me,
        initialScope: _scope == 'team' ? 'team' : 'personal',
        initialProjectId: _scope == 'team' ? _projectFilter : null,
      ),
    );
    if (created == true) await _store.refresh();
  }

  // _dropStatus is the board's drag-to-change-status action. The relay
  // broadcasts the update over SSE, which TodoStore already listens to, so
  // there's no local optimistic-update bookkeeping to do here beyond
  // surfacing a failure.
  Future<void> _dropStatus(Todo t, TodoStatus status) async {
    if (t.status == status) return;
    try {
      await _client.setTodoStatus(t.id, status);
    } catch (e) {
      if (mounted) snack(context, '更新状态失败: ${errorText(e)}');
    }
  }

  Future<void> _assignDialog(Todo t) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _AssignTodoDialog(
        todo: t,
        client: _client,
        overviewStore: _overview,
        config: _cfg,
      ),
    );
    if (changed == true) await _store.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= _wideBreakpoint;
    if (!wide) return _mobileBody();

    final contentPane = Column(
      children: [
        _filterHeader(wide: true),
        Expanded(child: _boardView ? _boardPane() : _buildList()),
      ],
    );

    if (_boardView) {
      return Row(
        children: [
          Expanded(child: contentPane),
          if (_selected != null) ...[
            const VerticalDivider(width: 1),
            SizedBox(width: 380, child: _rightPane()),
          ],
        ],
      );
    }
    return Row(
      children: [
        SizedBox(width: 360, child: contentPane),
        const VerticalDivider(width: 1),
        Expanded(child: _rightPane()),
      ],
    );
  }

  // _filterHeader is the title/scope/project/status filter chrome shared by
  // the board view, the list view, and the mobile card stream — only the
  // board/list toggle button is conditional (there's no board on a phone).
  Widget _filterHeader({required bool wide}) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
        child: Row(
          children: [
            const Icon(
              Icons.checklist_rounded,
              size: 20,
              color: CcColors.accent,
            ),
            const SizedBox(width: 8),
            const Text(
              '待办',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            if (wide)
              IconButton(
                icon: Icon(
                  _boardView
                      ? Icons.view_list_rounded
                      : Icons.view_kanban_rounded,
                  size: 18,
                ),
                tooltip: _boardView ? '切换到列表视图' : '切换到看板视图',
                onPressed: () => setState(() => _boardView = !_boardView),
              ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 18),
              tooltip: '刷新',
              onPressed: _store.refresh,
            ),
            IconButton(
              icon: const Icon(Icons.add_rounded),
              tooltip: '新建待办',
              onPressed: _createDialog,
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'personal', label: Text('个人')),
            ButtonSegment(value: 'team', label: Text('团队')),
            ButtonSegment(value: 'all', label: Text('全部')),
          ],
          selected: {_scope},
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onSelectionChanged: (s) => setState(() {
            _scope = s.first;
            if (_scope != 'team') _projectFilter = null;
          }),
        ),
      ),
      if (_scope == 'team' && _me.projects.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              const Text(
                '项目',
                style: TextStyle(color: CcColors.muted, fontSize: 12.5),
              ),
              const Spacer(),
              DropdownButton<String?>(
                value: _projectFilter,
                hint: const Text('全部项目'),
                underline: const SizedBox(),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('全部项目'),
                  ),
                  ..._me.projects.map(
                    (p) => DropdownMenuItem<String?>(
                      value: p.id,
                      child: Text(p.name),
                    ),
                  ),
                ],
                onChanged: (v) => setState(() => _projectFilter = v),
              ),
            ],
          ),
        ),
      if (_scope == 'team' && _linearRepos.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _importingLinear ? null : _importFromLinear,
              icon: _importingLinear
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync_alt_rounded, size: 16),
              label: const Text('从 Linear 导入'),
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
        child: scrollableBar(
          scrolling: [
            for (final s in TodoStatus.values)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _statusChip(s),
              ),
          ],
        ),
      ),
      const Divider(height: 12),
    ],
  );

  Widget _statusChip(TodoStatus s) {
    final selected = _statusFilter.contains(s);
    final color = _statusColor(s);
    return InkWell(
      borderRadius: BorderRadius.circular(CcRadius.pill),
      onTap: () => setState(() {
        if (selected) {
          _statusFilter.remove(s);
        } else {
          _statusFilter.add(s);
        }
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.14) : Colors.transparent,
          border: Border.all(
            color: selected ? color.withValues(alpha: 0.5) : CcColors.border,
          ),
          borderRadius: BorderRadius.circular(CcRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            statusDot(color, size: 6),
            const SizedBox(width: 5),
            Text(
              todoStatusLabel(s),
              style: TextStyle(
                fontSize: 11.5,
                color: selected ? CcColors.text : CcColors.muted,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() => asyncBody(
    loading: _store.loading && _store.all.isEmpty,
    error: _store.error,
    onRetry: _store.refresh,
    child: () {
      final items = _filtered;
      if (items.isEmpty) {
        return centerMsg(_store.all.isEmpty ? '暂无待办，点右上角 + 新建' : '无匹配');
      }
      return RefreshIndicator(
        onRefresh: _store.refresh,
        child: ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, i) => _row(items[i]),
        ),
      );
    },
  );

  Widget _row(Todo t) {
    final sel = _selected?.id == t.id;
    final color = _statusColor(t.status);
    final overdue =
        t.dueAt != null &&
        t.dueAt!.isBefore(DateTime.now()) &&
        t.status != TodoStatus.done &&
        t.status != TodoStatus.cancelled;
    return Material(
      color: sel ? CcColors.accent.withValues(alpha: 0.07) : Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _selected = t),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: sel ? CcColors.accent : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              Tooltip(
                message: todoStatusLabel(t.status),
                child: statusDot(
                  color,
                  size: 8,
                  glow: t.status == TodoStatus.inProgress,
                ),
              ),
              const SizedBox(width: 10),
              if (t.attachmentCount > 0) ...[
                _RowThumb(client: _client, todo: t),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              priorityBars(t.priority, maxHeight: 10),
              if (t.dueAt != null) ...[
                const SizedBox(width: 10),
                Text(
                  commitDate(t.dueAt!),
                  style: TextStyle(
                    fontFamily: CcType.mono,
                    fontSize: 10.5,
                    color: overdue ? CcColors.danger : CcColors.subtle,
                  ),
                ),
              ],
              const SizedBox(width: 10),
              SizedBox(
                width: 30,
                child: Text(
                  relativeTime(t.updatedAt),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontFamily: CcType.mono,
                    color: CcColors.subtle,
                    fontSize: 10.5,
                  ),
                ),
              ),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  icon: const Icon(Icons.send_rounded, size: 15),
                  tooltip: '一键指派',
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _assignDialog(t),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rightPane() {
    final sel = _selected;
    if (sel == null) return centerMsg('从左侧选择一个待办，或点右上角 + 新建');
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: [
              Text(
                sel.isPersonal ? '个人待办' : '团队待办',
                style: const TextStyle(color: CcColors.muted, fontSize: 12),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: () => _assignDialog(sel),
                icon: const Icon(Icons.send_rounded, size: 16),
                label: const Text('指派'),
              ),
              // The board view only shows this panel when something's selected
              // (columns reflow to use the freed width otherwise), so it needs
              // its own way to deselect — list view just shows the placeholder
              // message again, which is harmless.
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: '关闭',
                onPressed: () => setState(() => _selected = null),
              ),
            ],
          ),
        ),
        Expanded(
          child: TodoDetailView(
            key: _detailKey,
            client: _client,
            todo: sel,
            overviewStore: _overview,
            config: _cfg,
            onOpenSession: widget.onOpenSession,
            onChanged: (updated) {
              if (mounted) setState(() => _selected = updated);
            },
            onDeleted: () {
              if (!mounted) return;
              setState(() => _selected = null);
              _store.refresh();
            },
          ),
        ),
      ],
    );
  }

  // --- board view --------------------------------------------------------

  // _boardPane is the Linear-style kanban board: fixed-width columns laid
  // out in a horizontally-scrolling row (the reference layout doesn't flex
  // column width to the viewport), each a DragTarget<Todo> that maps a drop
  // to its dropStatus via _dropStatus.
  Widget _boardPane() {
    final items = _filtered;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final def in _boardColumnDefs)
              _boardColumn(
                def,
                items.where((t) => def.statuses.contains(t.status)).toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _boardColumn(_BoardColumnDef def, List<Todo> items) => Container(
    width: 272,
    margin: const EdgeInsets.only(right: 10),
    decoration: BoxDecoration(
      color: CcColors.panel.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(CcRadius.md),
      border: Border.all(color: CcColors.border),
    ),
    child: Column(
      children: [
        _columnHeader(def.title, items.length, _createDialog),
        Expanded(
          child: DragTarget<Todo>(
            onWillAcceptWithDetails: (details) =>
                details.data.status != def.dropStatus,
            onAcceptWithDetails: (details) =>
                _dropStatus(details.data, def.dropStatus),
            builder: (context, candidate, rejected) {
              final highlight = candidate.isNotEmpty;
              return Container(
                decoration: BoxDecoration(
                  color: highlight
                      ? CcColors.accent.withValues(alpha: 0.07)
                      : null,
                  borderRadius: BorderRadius.circular(CcRadius.md),
                ),
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: items.isEmpty
                    ? Center(
                        child: Text(
                          '无',
                          style: TextStyle(
                            color: CcColors.subtle.withValues(alpha: 0.7),
                            fontSize: 12,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => _draggableCard(items[i]),
                      ),
              );
            },
          ),
        ),
      ],
    ),
  );

  Widget _columnHeader(String title, int count, VoidCallback onAdd) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 10, 4, 8),
    child: Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: CcColors.muted,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: CcColors.panelHigh,
            borderRadius: BorderRadius.circular(CcRadius.pill),
          ),
          child: Text(
            '$count',
            style: const TextStyle(
              fontSize: 11,
              color: CcColors.subtle,
              fontFamily: CcType.mono,
            ),
          ),
        ),
        const Spacer(),
        SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            icon: const Icon(Icons.add_rounded, size: 16),
            tooltip: '新建待办',
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onPressed: onAdd,
          ),
        ),
      ],
    ),
  );

  Widget _draggableCard(Todo t) {
    final card = TodoCard(
      todo: t,
      projectName: _projectName(t),
      onTap: () => setState(() => _selected = t),
    );
    return Draggable<Todo>(
      data: t,
      feedback: Opacity(
        opacity: 0.85,
        child: SizedBox(
          width: 252,
          child: Material(color: Colors.transparent, child: card),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: card),
      child: card,
    );
  }

  // --- mobile view ---------------------------------------------------------

  // _mobileBody drops the board/split-pane layout entirely for a single
  // scrolling column of cards, grouped under the same status buckets as the
  // board's columns (so the group headings read the same either way), with
  // tapping a card pushing a full-screen detail route instead of opening a
  // side panel there's no room for.
  Widget _mobileBody() => Column(
    children: [
      _filterHeader(wide: false),
      Expanded(child: _mobileList()),
    ],
  );

  Widget _mobileList() => asyncBody(
    loading: _store.loading && _store.all.isEmpty,
    error: _store.error,
    onRetry: _store.refresh,
    child: () {
      final items = _filtered;
      if (items.isEmpty) {
        return centerMsg(_store.all.isEmpty ? '暂无待办，点右上角 + 新建' : '无匹配');
      }
      final width = MediaQuery.of(context).size.width;
      final cols = width >= 480 ? 2 : 1;
      final groups = [
        for (final def in _boardColumnDefs)
          (
            def.title,
            items.where((t) => def.statuses.contains(t.status)).toList(),
          ),
      ].where((g) => g.$2.isNotEmpty).toList();
      return RefreshIndicator(
        onRefresh: _store.refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
          children: [
            for (final g in groups) _mobileGroup(g.$1, g.$2, cols, width),
          ],
        ),
      );
    },
  );

  Widget _mobileGroup(
    String title,
    List<Todo> items,
    int cols,
    double totalWidth,
  ) {
    final collapsed = _collapsedMobileGroups.contains(title);
    final cardW = (totalWidth - 12 * 2 - (cols - 1) * 10) / cols;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (collapsed) {
              _collapsedMobileGroups.remove(title);
            } else {
              _collapsedMobileGroups.add(title);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: const Icon(
                    Icons.expand_more_rounded,
                    size: 18,
                    color: CcColors.muted,
                  ),
                ),
                const SizedBox(width: 2),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: CcColors.muted,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: CcColors.panelHigh,
                    borderRadius: BorderRadius.circular(CcRadius.pill),
                  ),
                  child: Text(
                    '${items.length}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: CcColors.subtle,
                      fontFamily: CcType.mono,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!collapsed)
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final t in items)
                SizedBox(
                  width: cardW,
                  child: TodoCard(
                    todo: t,
                    projectName: _projectName(t),
                    onTap: () => _openMobileDetail(t),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 4),
      ],
    );
  }

  void _openMobileDetail(Todo t) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: const Text('待办详情'),
            actions: [
              IconButton(
                icon: const Icon(Icons.send_rounded),
                tooltip: '指派',
                onPressed: () => _assignDialog(t),
              ),
            ],
          ),
          body: TodoDetailView(
            client: _client,
            todo: t,
            overviewStore: _overview,
            config: _cfg,
            onOpenSession: widget.onOpenSession,
            onDeleted: () {
              if (Navigator.of(context).canPop()) Navigator.of(context).pop();
              _store.refresh();
            },
          ),
        ),
      ),
    );
  }
}

// _RowThumb lazily fetches the full Todo (GET /v1/todos/{id}) to find its
// first image attachment for a list-row thumbnail — ListTodos deliberately
// omits `attachments` (avoids an N+1 join server-side), so this is the only
// way to know whether an attachment is an image. Only fires for rows with
// attachmentCount > 0, cached per (id, updatedAt) so it never refetches an
// unchanged todo, and only for rows a lazy ListView actually builds.
class _RowThumb extends StatefulWidget {
  final RelayClient client;
  final Todo todo;
  const _RowThumb({required this.client, required this.todo});

  @override
  State<_RowThumb> createState() => _RowThumbState();
}

class _RowThumbState extends State<_RowThumb> {
  static final Map<String, TodoAttachment?> _cache = {};
  TodoAttachment? _att;
  bool _ready = false;

  String get _cacheKey =>
      '${widget.todo.id}:${widget.todo.updatedAt.millisecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    if (_cache.containsKey(_cacheKey)) {
      _att = _cache[_cacheKey];
      _ready = true;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final full = await widget.client.todo(widget.todo.id);
      final images = full.attachments.where(
        (a) => isImageAttachmentName(a.name),
      );
      final found = images.isEmpty ? null : images.first;
      _cache[_cacheKey] = found;
      if (mounted) {
        setState(() {
          _att = found;
          _ready = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _ready = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final att = _att;
    if (!_ready || att == null) return const SizedBox(width: 22, height: 22);
    return TodoAttachmentThumb(
      client: widget.client,
      todoId: widget.todo.id,
      attachment: att,
      size: 22,
    );
  }
}

// _QuickCreateDialog is Linear's Cmd+I "quick add" panel, not a stack of
// labeled dropdowns: a focused title input, an optional description (the
// same live markdown editor as the detail view), and a compact icon row for
// priority/recurrence/due-date/attachments. Creates the todo, then uploads
// each attachment in turn (attachments need the todo's id, so they can only
// go up after creation succeeds).
class _QuickCreateDialog extends StatefulWidget {
  final RelayClient client;
  final Me me;
  final String initialScope;
  final String? initialProjectId;

  const _QuickCreateDialog({
    required this.client,
    required this.me,
    this.initialScope = 'personal',
    this.initialProjectId,
  });

  @override
  State<_QuickCreateDialog> createState() => _QuickCreateDialogState();
}

class _QuickCreateDialogState extends State<_QuickCreateDialog> {
  final _titleCtl = TextEditingController();
  final _bodyCtl = MarkdownLiteController();
  late String _scope = widget.initialScope;
  String? _projectId;
  String _priority = 'normal';
  String _recurrence = '';
  DateTime? _dueAt;
  final List<PlatformFile> _files = [];
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _projectId = widget.initialProjectId;
    if (_scope == 'team' &&
        _projectId == null &&
        widget.me.projects.isNotEmpty) {
      _projectId = widget.me.projects.first.id;
    }
  }

  @override
  void dispose() {
    _titleCtl.dispose();
    _bodyCtl.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (res == null || !mounted) return;
    setState(() => _files.addAll(res.files));
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dueAt ?? now),
    );
    if (time == null || !mounted) return;
    setState(
      () => _dueAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      ),
    );
  }

  Future<void> _submit() async {
    final title = _titleCtl.text.trim();
    if (title.isEmpty) {
      snack(context, '请输入标题');
      return;
    }
    if (_scope == 'team' && _projectId == null) {
      snack(context, '请选择项目');
      return;
    }
    setState(() => _submitting = true);
    try {
      final created = await widget.client.createTodo(
        title: title,
        bodyMd: _bodyCtl.text,
        priority: _priority,
        projectId: _scope == 'team' ? _projectId : null,
        recurrence: _recurrence,
        dueAt: _dueAt,
      );
      for (final f in _files) {
        try {
          Uint8List? bytes = f.bytes;
          bytes ??= f.path != null ? await File(f.path!).readAsBytes() : null;
          if (bytes == null) continue;
          await widget.client.uploadTodoAttachment(created.id, f.name, bytes);
        } catch (e) {
          if (mounted) snack(context, '附件 ${f.name} 上传失败: ${errorText(e)}');
        }
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      snack(context, '创建失败: ${errorText(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (widget.me.projects.isNotEmpty)
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'personal', label: Text('个人')),
                        ButtonSegment(value: 'team', label: Text('团队')),
                      ],
                      selected: {_scope},
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onSelectionChanged: (s) => setState(() {
                        _scope = s.first;
                        if (_scope == 'team' &&
                            _projectId == null &&
                            widget.me.projects.isNotEmpty) {
                          _projectId = widget.me.projects.first.id;
                        }
                      }),
                    ),
                  const Spacer(),
                  if (_scope == 'team' && widget.me.projects.isNotEmpty)
                    DropdownButton<String>(
                      isDense: true,
                      underline: const SizedBox(),
                      value: _projectId,
                      items: widget.me.projects
                          .map(
                            (p) => DropdownMenuItem(
                              value: p.id,
                              child: Text(p.name),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _projectId = v),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _titleCtl,
                autofocus: true,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: '待办标题',
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 6),
              MarkdownLiteEditor(
                controller: _bodyCtl,
                hintText: '添加描述…（可选，支持 Markdown）',
                minLines: 2,
                maxLines: 6,
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Row(
                children: [
                  PriorityControl(
                    priority: _priority,
                    onChanged: (v) => setState(() => _priority = v),
                  ),
                  const SizedBox(width: 6),
                  RecurrenceControl(
                    recurrence: _recurrence,
                    onChanged: (v) => setState(() => _recurrence = v),
                  ),
                  const SizedBox(width: 6),
                  DueDatePill(
                    dueAt: _dueAt,
                    onTap: _pickDueDate,
                    onClear: () => setState(() => _dueAt = null),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.attach_file_rounded, size: 18),
                    tooltip: _files.isEmpty
                        ? '添加附件'
                        : '已选 ${_files.length} 个文件',
                    visualDensity: VisualDensity.compact,
                    onPressed: _pickFiles,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('创建'),
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

// _AssignTodoDialog is the "一键指派" flow: dispatch to an existing local
// session, or spawn a brand-new one first (optionally in a fresh worktree
// branch) and then dispatch. Both branches deliver through
// SessionOverviewStore (the only channel a top-level sibling page has into
// WorkspacePage's live sessions), then best-effort sync assignee visibility
// to the relay so other project members see who picked it up — that sync
// never blocks or fails the "start working now" outcome.
class _AssignTodoDialog extends StatefulWidget {
  final Todo todo;
  final RelayClient client;
  final SessionOverviewStore overviewStore;
  final AppConfig config;

  const _AssignTodoDialog({
    required this.todo,
    required this.client,
    required this.overviewStore,
    required this.config,
  });

  @override
  State<_AssignTodoDialog> createState() => _AssignTodoDialogState();
}

class _AssignTodoDialogState extends State<_AssignTodoDialog> {
  String _mode = 'existing'; // existing | new
  String? _targetSid;
  String? _workspace;
  String? _project;
  String _kind = 'claude';
  final _branchCtl = TextEditingController();
  bool _submitting = false;

  List<SessionCard> get _cards => widget.overviewStore.cards;

  List<ProjectCfg> get _projectsForWorkspace {
    final matches = widget.config.workspaces.where((w) => w.name == _workspace);
    return matches.isEmpty ? const [] : matches.first.projects;
  }

  String get _taskText {
    final t = widget.todo;
    return t.bodyMd.trim().isEmpty
        ? '[待办] ${t.title}'
        : '[待办] ${t.title}\n\n${t.bodyMd}';
  }

  @override
  void initState() {
    super.initState();
    if (_cards.isNotEmpty) _targetSid = _cards.first.sid;
    if (widget.config.workspaces.isNotEmpty) {
      _workspace = widget.config.workspaces.first.name;
      final projs = _projectsForWorkspace;
      if (projs.isNotEmpty) _project = projs.first.name;
    }
  }

  @override
  void dispose() {
    _branchCtl.dispose();
    super.dispose();
  }

  SessionCard? _findCard(String sid) {
    for (final c in _cards) {
      if (c.sid == sid) return c;
    }
    return null;
  }

  // _resumeKindFor encodes a SessionCard's kind the same way
  // workspace_page.dart's _supervisorAgentForKind expects to read it back
  // ('supervisor:claude'/'supervisor:codex') — SessionCard.agentKind alone
  // is always bare ('claude'/'codex'), so without this a todo bound to a 总管
  // session would resume as a plain agent session, silently losing its
  // supervisor identity.
  String? _resumeKindFor(SessionCard? card) {
    if (card == null || card.agentKind.isEmpty) return null;
    return card.isSupervisor ? 'supervisor:${card.agentKind}' : card.agentKind;
  }

  // _syncAssignVisibility is best-effort: local dispatch already delivered the
  // task, so a relay failure here only means other project members won't see
  // the assignee yet — never worth blocking or erroring the dialog over. Sets
  // identity + session id + session label per RelayClient.assignTodo's
  // "assign to a specific local session" contract, plus — when the target
  // session's card carries them — the permanent-resume trio
  // (agentSessionId/workdir/agentKind), read straight off the just-dispatched
  // TerminalSession's SessionCard, so "打开/恢复会话" can respawn the exact
  // same conversation long after this bus session id itself goes stale.
  //
  // waitForAgentId: codex doesn't mint its transcript id synchronously like
  // claude does (--session-id up front) — it's captured asynchronously from
  // its rollout file sometime after launch (TerminalSession._maybeCaptureAgentId).
  // A brand-new codex session's card usually has no agentSessionId yet the
  // instant it's dispatched, so _assignToNew asks this to poll briefly rather
  // than permanently missing the resume trio for that todo.
  //
  // workspaceName/repoName sync the todo's optional workspace/repo binding
  // (see WorkspaceRepoControl / pkg/todoschema.Todo field docs) to match the
  // session it's being dispatched to — always overwriting, even if the todo
  // was previously bound (manually) to a different repo: once a todo has a
  // live session, "which repo is it in" should follow the session, not stay
  // pinned to whatever was picked before. This lands as a second, separate
  // PATCH rather than growing RelayClient.assignTodo's already-wide parameter
  // list further.
  Future<void> _syncAssignVisibility(
    String sessionId,
    String label, {
    required String workspaceName,
    required String repoName,
    bool waitForAgentId = false,
  }) async {
    var card = _findCard(sessionId);
    if (waitForAgentId && (card?.agentSessionId ?? '').isEmpty) {
      for (var i = 0; i < 15 && (card?.agentSessionId ?? '').isEmpty; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (!mounted) return;
        card = _findCard(sessionId);
      }
    }
    try {
      await widget.client.assignTodo(
        widget.todo.id,
        assigneeIdentity: widget.config.identity,
        assigneeSessionId: sessionId,
        assigneeSessionLabel: label,
        assigneeAgentSessionId: card?.agentSessionId,
        assigneeWorkdir: card?.workdir,
        assigneeAgentKind: _resumeKindFor(card),
      );
    } catch (_) {}
    try {
      await widget.client.updateTodo(
        widget.todo.id,
        workspaceName: workspaceName,
        repoName: repoName,
      );
    } catch (e) {
      if (mounted) snack(context, '同步工作区/库绑定失败: ${errorText(e)}');
    }
  }

  Future<void> _assignToExisting() async {
    final sid = _targetSid;
    if (sid == null) return;
    setState(() => _submitting = true);
    final err = widget.overviewStore.dispatch(
      LocalMsg('', sid, _taskText, true),
    );
    if (err != null) {
      if (mounted) {
        setState(() => _submitting = false);
        snack(context, '投递失败: $err');
      }
      return;
    }
    final card = _findCard(sid);
    await _syncAssignVisibility(
      sid,
      card?.label ?? '',
      workspaceName: card?.workspace ?? '',
      repoName: card?.project ?? '',
    );
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _assignToNew() async {
    final ws = _workspace, proj = _project;
    if (ws == null || proj == null) {
      snack(context, '请选择 workspace / project');
      return;
    }
    setState(() => _submitting = true);
    final branch = _branchCtl.text.trim();
    final (sid, err) = await widget.overviewStore.spawn(
      workspace: ws,
      project: proj,
      kind: _kind,
      newWorktreeBranch: branch.isEmpty ? null : branch,
    );
    if (sid == null) {
      if (mounted) {
        setState(() => _submitting = false);
        snack(context, '新建会话失败: ${err ?? "未知错误"}');
      }
      return;
    }
    final dispatchErr = widget.overviewStore.dispatch(
      LocalMsg('', sid, _taskText, true),
    );
    if (dispatchErr != null && mounted) {
      snack(context, '会话已创建，但投递失败: $dispatchErr');
    }
    await _syncAssignVisibility(
      sid,
      proj,
      workspaceName: ws,
      repoName: proj,
      waitForAgentId: true,
    );
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    if (_cards.isEmpty) {
      return AlertDialog(
        title: const Text('一键指派'),
        content: const Text('仅桌面版可指派到本机会话。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    }
    return AlertDialog(
      title: const Text('一键指派'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'existing', label: Text('已有会话')),
                  ButtonSegment(value: 'new', label: Text('新建会话')),
                ],
                selected: {_mode},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 12),
              if (_mode == 'existing') _existingForm() else _newForm(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting
              ? null
              : (_mode == 'existing' ? _assignToExisting : _assignToNew),
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('指派并开始'),
        ),
      ],
    );
  }

  Widget _existingForm() => DropdownButton<String>(
    isExpanded: true,
    value: _targetSid,
    items: _cards
        .map(
          (c) => DropdownMenuItem(
            value: c.sid,
            child: Text(
              '${c.label} (${c.workspace}/${c.project})',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        )
        .toList(),
    onChanged: (v) => setState(() => _targetSid = v),
  );

  Widget _newForm() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DropdownButton<String>(
        isExpanded: true,
        hint: const Text('workspace'),
        value: _workspace,
        items: widget.config.workspaces
            .map((w) => DropdownMenuItem(value: w.name, child: Text(w.name)))
            .toList(),
        onChanged: (v) => setState(() {
          _workspace = v;
          final projs = _projectsForWorkspace;
          _project = projs.isEmpty ? null : projs.first.name;
        }),
      ),
      const SizedBox(height: 8),
      DropdownButton<String>(
        isExpanded: true,
        hint: const Text('project'),
        value: _project,
        items: _projectsForWorkspace
            .map((p) => DropdownMenuItem(value: p.name, child: Text(p.name)))
            .toList(),
        onChanged: (v) => setState(() => _project = v),
      ),
      const SizedBox(height: 8),
      DropdownButton<String>(
        isExpanded: true,
        value: _kind,
        items: const [
          DropdownMenuItem(value: 'claude', child: Text('Claude')),
          DropdownMenuItem(value: 'codex', child: Text('Codex')),
          DropdownMenuItem(value: 'shell', child: Text('Shell')),
        ],
        onChanged: (v) => setState(() => _kind = v ?? 'claude'),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _branchCtl,
        decoration: const InputDecoration(
          labelText: '新建 worktree 分支名（可选）',
          isDense: true,
        ),
      ),
    ],
  );
}
