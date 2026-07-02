import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../api/todo_models.dart';
import '../local/config.dart';
import '../local/local_bus.dart';
import '../local/session_overview.dart';
import '../local/todo_store.dart';
import '../theme.dart';
import '../widgets.dart';
import '../widgets/todo_attachment_thumb.dart';
import 'todo_detail_view.dart';

const _priorityLabels = {'low': '低', 'normal': '普通', 'high': '高'};
const _recurrenceLabels = {
  '': '不重复',
  'daily': '每天',
  'weekly': '每周',
  'monthly': '每月',
};

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

  const TodosPage({
    super.key,
    required this.client,
    required this.config,
    required this.me,
    required this.store,
    required this.overviewStore,
  });

  @override
  State<TodosPage> createState() => _TodosPageState();
}

class _TodosPageState extends State<TodosPage> {
  String _scope = 'personal'; // personal | team | all
  final Set<TodoStatus> _statusFilter = {};
  String? _projectFilter; // project id, only meaningful when _scope == 'team'
  Todo? _selected;
  final _detailKey = GlobalKey<TodoDetailViewState>();

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
      builder: (_) => _CreateTodoDialog(
        client: _client,
        me: _me,
        initialScope: _scope == 'team' ? 'team' : 'personal',
        initialProjectId: _scope == 'team' ? _projectFilter : null,
      ),
    );
    if (created == true) await _store.refresh();
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
    return Row(children: [
      SizedBox(width: 360, child: _leftPane()),
      const VerticalDivider(width: 1),
      Expanded(child: _rightPane()),
    ]);
  }

  Widget _leftPane() => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
          child: Row(children: [
            const Icon(Icons.checklist_rounded, size: 20, color: CcColors.accent),
            const SizedBox(width: 8),
            const Text('待办',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const Spacer(),
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
          ]),
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
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            onSelectionChanged: (s) => setState(() {
              _scope = s.first;
              if (_scope != 'team') _projectFilter = null;
            }),
          ),
        ),
        if (_scope == 'team' && _me.projects.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(children: [
              const Text('项目',
                  style: TextStyle(color: CcColors.muted, fontSize: 12.5)),
              const Spacer(),
              DropdownButton<String?>(
                value: _projectFilter,
                hint: const Text('全部项目'),
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('全部项目')),
                  ..._me.projects.map((p) => DropdownMenuItem<String?>(
                      value: p.id, child: Text(p.name))),
                ],
                onChanged: (v) => setState(() => _projectFilter = v),
              ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: TodoStatus.values
                .map((s) => FilterChip(
                      label: Text(todoStatusLabel(s)),
                      selected: _statusFilter.contains(s),
                      visualDensity: VisualDensity.compact,
                      onSelected: (sel) => setState(() {
                        if (sel) {
                          _statusFilter.add(s);
                        } else {
                          _statusFilter.remove(s);
                        }
                      }),
                    ))
                .toList(),
          ),
        ),
        const Divider(height: 12),
        Expanded(child: _buildList()),
      ]);

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
    return Container(
      decoration: BoxDecoration(
        color: sel ? CcColors.accent.withValues(alpha: 0.07) : null,
        border: Border(
            left: BorderSide(
                color: sel ? CcColors.accent : Colors.transparent, width: 2.5)),
      ),
      child: ListTile(
        selected: sel,
        leading: SizedBox(
          width: t.attachmentCount > 0 ? 60 : 12,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            statusDot(_statusColor(t.status),
                size: 9, glow: t.status == TodoStatus.inProgress),
            if (t.attachmentCount > 0) ...[
              const SizedBox(width: 6),
              _RowThumb(client: _client, todo: t),
            ],
          ]),
        ),
        title: Text(t.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Wrap(spacing: 6, runSpacing: 2, children: [
          tag(todoStatusLabel(t.status), _statusColor(t.status)),
          if (t.priority == 'high') tag('高优先级', CcColors.danger, bold: true),
          if (t.dueAt != null)
            Text('截止 ${commitDate(t.dueAt!)}',
                style: const TextStyle(color: CcColors.muted, fontSize: 11)),
        ]),
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(relativeTime(t.updatedAt),
                style: const TextStyle(
                    fontFamily: CcType.mono,
                    color: CcColors.subtle,
                    fontSize: 11)),
            const SizedBox(height: 2),
            IconButton(
              icon: const Icon(Icons.send_rounded, size: 18),
              tooltip: '一键指派',
              visualDensity: VisualDensity.compact,
              onPressed: () => _assignDialog(t),
            ),
          ],
        ),
        onTap: () => setState(() => _selected = t),
      ),
    );
  }

  Widget _rightPane() {
    final sel = _selected;
    if (sel == null) return centerMsg('从左侧选择一个待办，或点右上角 + 新建');
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Row(children: [
          Text(sel.isPersonal ? '个人待办' : '团队待办',
              style: const TextStyle(color: CcColors.muted, fontSize: 12)),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: () => _assignDialog(sel),
            icon: const Icon(Icons.send_rounded, size: 16),
            label: const Text('指派'),
          ),
        ]),
      ),
      Expanded(
        child: TodoDetailView(
          key: _detailKey,
          client: _client,
          todo: sel,
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
    ]);
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
      final images =
          full.attachments.where((a) => isImageAttachmentName(a.name));
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
        client: widget.client, todoId: widget.todo.id, attachment: att, size: 22);
  }
}

// _CreateTodoDialog collects title/body/scope/priority/recurrence/due-date +
// optional attachments, creates the todo, then uploads each attachment in
// turn (attachments need the todo's id, so they can only go up after
// creation succeeds).
class _CreateTodoDialog extends StatefulWidget {
  final RelayClient client;
  final Me me;
  final String initialScope;
  final String? initialProjectId;

  const _CreateTodoDialog({
    required this.client,
    required this.me,
    this.initialScope = 'personal',
    this.initialProjectId,
  });

  @override
  State<_CreateTodoDialog> createState() => _CreateTodoDialogState();
}

class _CreateTodoDialogState extends State<_CreateTodoDialog> {
  final _titleCtl = TextEditingController();
  final _bodyCtl = TextEditingController();
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
    if (_scope == 'team' && _projectId == null && widget.me.projects.isNotEmpty) {
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
    final res =
        await FilePicker.platform.pickFiles(allowMultiple: true, withData: true);
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
    setState(() => _dueAt =
        DateTime(date.year, date.month, date.day, time.hour, time.minute));
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
    return AlertDialog(
      title: const Text('新建待办'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _titleCtl,
                autofocus: true,
                decoration: const InputDecoration(labelText: '标题'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _bodyCtl,
                minLines: 2,
                maxLines: 6,
                decoration:
                    const InputDecoration(labelText: '正文（可选，支持 Markdown）'),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: [
                  const ButtonSegment(value: 'personal', label: Text('个人')),
                  if (widget.me.projects.isNotEmpty)
                    const ButtonSegment(value: 'team', label: Text('团队')),
                ],
                selected: {_scope},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() {
                  _scope = s.first;
                  if (_scope == 'team' &&
                      _projectId == null &&
                      widget.me.projects.isNotEmpty) {
                    _projectId = widget.me.projects.first.id;
                  }
                }),
              ),
              if (_scope == 'team') ...[
                const SizedBox(height: 10),
                DropdownButton<String>(
                  isExpanded: true,
                  hint: const Text('选择项目'),
                  value: _projectId,
                  items: widget.me.projects
                      .map((p) =>
                          DropdownMenuItem(value: p.id, child: Text(p.name)))
                      .toList(),
                  onChanged: (v) => setState(() => _projectId = v),
                ),
              ],
              const SizedBox(height: 6),
              Row(children: [
                const Text('优先级',
                    style: TextStyle(color: CcColors.muted, fontSize: 13)),
                const Spacer(),
                DropdownButton<String>(
                  value: _priority,
                  items: _priorityLabels.entries
                      .map((e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (v) => setState(() => _priority = v ?? 'normal'),
                ),
              ]),
              Row(children: [
                const Text('周期',
                    style: TextStyle(color: CcColors.muted, fontSize: 13)),
                const Spacer(),
                DropdownButton<String>(
                  value: _recurrence,
                  items: _recurrenceLabels.entries
                      .map((e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (v) => setState(() => _recurrence = v ?? ''),
                ),
              ]),
              Row(children: [
                const Text('截止日期',
                    style: TextStyle(color: CcColors.muted, fontSize: 13)),
                const Spacer(),
                TextButton(
                  onPressed: _pickDueDate,
                  child: Text(_dueAt == null ? '设置' : commitDate(_dueAt!)),
                ),
                if (_dueAt != null)
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 16),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _dueAt = null),
                  ),
              ]),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _pickFiles,
                  icon: const Icon(Icons.attach_file_rounded, size: 16),
                  label: Text(_files.isEmpty ? '添加附件' : '已选 ${_files.length} 个文件'),
                ),
              ),
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
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('创建'),
        ),
      ],
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

  // _syncAssignVisibility is best-effort: local dispatch already delivered the
  // task, so a relay failure here only means other project members won't see
  // the assignee yet — never worth blocking or erroring the dialog over. Sets
  // all three assignee fields (identity + session id + session label) per
  // RelayClient.assignTodo's "assign to a specific local session" contract.
  Future<void> _syncAssignVisibility(String sessionId, String label) async {
    try {
      await widget.client.assignTodo(widget.todo.id,
          assigneeIdentity: widget.config.identity,
          assigneeSessionId: sessionId,
          assigneeSessionLabel: label);
    } catch (_) {}
  }

  Future<void> _assignToExisting() async {
    final sid = _targetSid;
    if (sid == null) return;
    setState(() => _submitting = true);
    final err =
        widget.overviewStore.dispatch(LocalMsg('', sid, _taskText, true));
    if (err != null) {
      if (mounted) {
        setState(() => _submitting = false);
        snack(context, '投递失败: $err');
      }
      return;
    }
    await _syncAssignVisibility(sid, _findCard(sid)?.label ?? '');
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
    final dispatchErr =
        widget.overviewStore.dispatch(LocalMsg('', sid, _taskText, true));
    if (dispatchErr != null && mounted) {
      snack(context, '会话已创建，但投递失败: $dispatchErr');
    }
    await _syncAssignVisibility(sid, proj);
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
              onPressed: () => Navigator.pop(context), child: const Text('关闭')),
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
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('指派并开始'),
        ),
      ],
    );
  }

  Widget _existingForm() => DropdownButton<String>(
        isExpanded: true,
        value: _targetSid,
        items: _cards
            .map((c) => DropdownMenuItem(
                value: c.sid,
                child: Text('${c.label} (${c.workspace}/${c.project})',
                    overflow: TextOverflow.ellipsis)))
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
                labelText: '新建 worktree 分支名（可选）', isDense: true),
          ),
        ],
      );
}
