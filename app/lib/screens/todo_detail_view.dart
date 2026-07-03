import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api/relay_client.dart';
import '../api/todo_models.dart';
import '../local/config.dart';
import '../local/path_utils.dart';
import '../local/session_overview.dart';
import '../theme.dart';
import '../widgets.dart';
import '../widgets/markdown_lite_editor.dart';
import '../widgets/todo_attachment_thumb.dart';
import '../widgets/todo_body_view.dart';
import '../widgets/todo_property_controls.dart';

// TodoDetailView is the reusable 待办详情/编辑面板. Linear-flavored editing
// model: title/body autosave on blur (+ a debounce while typing the body)
// instead of a standalone Save button, and status/priority/recurrence/due-
// date are click-to-edit pills (PriorityControl etc.) rather than a
// permanent row of DropdownButtons. [todo] may come from a list response (no
// `attachments` populated — the relay omits it there to dodge an N+1 join),
// so this view re-fetches the full Todo via GET /v1/todos/{id} on mount to
// backfill attachments, the same way HandoffDetailView loads its Package on
// mount.
class TodoDetailView extends StatefulWidget {
  final RelayClient client;
  final Todo todo;
  // onChanged fires after any successful edit (title/body/status/priority/
  // recurrence/due date) with the server's updated Todo — the host (TodosPage)
  // uses this to keep its list row / selection in sync without waiting on SSE.
  final void Function(Todo updated)? onChanged;
  final VoidCallback? onDeleted;
  // overviewStore/config back the "打开/恢复会话" affordance in the assignee
  // row: overviewStore.cards tells "still a live bus session" apart from
  // "gone, respawn from the saved resume trio" (Todo.assigneeAgentSessionId/
  // assigneeWorkdir/assigneeAgentKind), and config.workspaces is what a
  // saved workdir gets reverse-matched against to resolve which
  // workspace/project to respawn in. Both optional — a host with no local
  // session bus (there isn't one today) just doesn't get the button.
  final SessionOverviewStore? overviewStore;
  final AppConfig? config;
  // onOpenSession additionally switches the host's own top-level nav to the
  // 工作区 tab before focusing the session (mirrors main.dart's
  // _openSessionInWorkspace, used by SessionOverviewPage) — pass this when
  // TodoDetailView is hosted OUTSIDE WorkspacePage (e.g. TodosPage, a nav
  // sibling); omit it when already inside WorkspacePage (the 待办 sidebar),
  // where overviewStore.requestOpen alone is enough since there's no tab to
  // switch away from.
  final void Function(String sid)? onOpenSession;

  const TodoDetailView({
    super.key,
    required this.client,
    required this.todo,
    this.onChanged,
    this.onDeleted,
    this.overviewStore,
    this.config,
    this.onOpenSession,
  });

  @override
  State<TodoDetailView> createState() => TodoDetailViewState();
}

class TodoDetailViewState extends State<TodoDetailView> {
  late Todo _current = widget.todo;
  late final TextEditingController _titleCtl =
      TextEditingController(text: widget.todo.title);
  late final MarkdownLiteController _bodyCtl =
      MarkdownLiteController(text: widget.todo.bodyMd);
  late final FocusNode _titleFocus = FocusNode()..addListener(_onTitleFocusChange);
  late final FocusNode _bodyFocus = FocusNode()..addListener(_onBodyFocusChange);
  final _commentCtl = TextEditingController();
  Timer? _bodyDebounce;
  List<TodoComment> _comments = const [];
  bool _loadingAttachments = true;
  bool _textDirty = false;
  bool _saving = false;
  bool _uploading = false;
  // Body starts in read-only display mode (TodoBodyView, images inlined);
  // clicking it swaps to the live MarkdownLiteEditor for editing, and losing
  // focus swaps back — same split as the plan's "编辑态/展示态" design so
  // body_md itself never has to represent "is this being edited" state.
  bool _bodyEditing = false;
  bool _resumingSession = false;

  RelayClient get _client => widget.client;
  String get _id => widget.todo.id;

  @override
  void initState() {
    super.initState();
    _loadFull();
    reloadComments();
  }

  @override
  void didUpdateWidget(TodoDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.todo.id != widget.todo.id) {
      if (_textDirty) {
        // Flush the OLD todo's edits before switching away — best-effort,
        // decoupled from this widget's _saving/_textDirty (which now track
        // the newly-selected todo).
        final oldId = oldWidget.todo.id;
        final oldTitle = _titleCtl.text.trim();
        final oldBody = _bodyCtl.text;
        _client
            .updateTodo(oldId, title: oldTitle, bodyMd: oldBody)
            .catchError((_) => oldWidget.todo);
      }
      _bodyDebounce?.cancel();
      setState(() {
        _current = widget.todo;
        _titleCtl.text = widget.todo.title;
        _bodyCtl.text = widget.todo.bodyMd;
        _textDirty = false;
        _bodyEditing = false;
        _comments = const [];
        _loadingAttachments = true;
      });
      _loadFull();
      reloadComments();
    } else if (!_textDirty && oldWidget.todo.updatedAt != widget.todo.updatedAt) {
      // An external update (SSE-driven store upsert) landed while this todo is
      // open — re-fetch rather than hand-merge fields, since GET-by-id is the
      // only source of truth for `attachments`.
      _loadFull();
    }
  }

  @override
  void dispose() {
    // Flush a pending debounced edit before the controllers go away — e.g.
    // the todo got deleted/filtered out from under this view (SSE) while
    // mid-edit. Best-effort like the didUpdateWidget switch-away flush: the
    // widget is gone by the time this could fail, so there's nowhere left to
    // surface an error.
    if (_textDirty) {
      _client
          .updateTodo(_id, title: _titleCtl.text.trim(), bodyMd: _bodyCtl.text)
          .catchError((_) => _current);
    }
    _bodyDebounce?.cancel();
    _titleCtl.dispose();
    _bodyCtl.dispose();
    _titleFocus.dispose();
    _bodyFocus.dispose();
    _commentCtl.dispose();
    super.dispose();
  }

  Future<void> _loadFull() async {
    try {
      final t = await _client.todo(_id);
      if (!mounted) return;
      setState(() {
        _current = t;
        _loadingAttachments = false;
        if (!_textDirty) {
          _titleCtl.text = t.title;
          _bodyCtl.text = t.bodyMd;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingAttachments = false);
      snack(context, '加载待办详情失败: ${errorText(e)}');
    }
  }

  // reloadComments is public so the host can force a refresh when
  // TodoStore.onComment fires for this todo's id (a todo.comment_created SSE
  // event) — the store itself doesn't model comments, it just tells the host
  // which todo needs its comment list reloaded.
  Future<void> reloadComments() async {
    try {
      final cs = await _client.todoComments(_id);
      if (mounted) setState(() => _comments = cs);
    } catch (_) {}
  }

  void _markTextDirty() {
    if (_textDirty) return;
    setState(() => _textDirty = true);
  }

  void _onTitleFocusChange() {
    if (!_titleFocus.hasFocus && _textDirty) _saveTextEdits();
  }

  void _onBodyFocusChange() {
    if (_bodyFocus.hasFocus) return;
    if (_textDirty) {
      _bodyDebounce?.cancel();
      _saveTextEdits();
    }
    if (mounted) setState(() => _bodyEditing = false);
  }

  void _onBodyChanged(String _) {
    _markTextDirty();
    _bodyDebounce?.cancel();
    _bodyDebounce = Timer(const Duration(milliseconds: 700), () {
      if (_textDirty && mounted) _saveTextEdits();
    });
  }

  void _applyUpdated(Todo t) {
    if (!mounted) return;
    // PATCH/status-update responses always carry an empty `attachments`
    // (relay skips that join outside GET-by-id) — if nothing attachment-wise
    // actually changed server-side (count is unchanged), keep the
    // already-loaded list instead of blanking out inline images that
    // TodoBodyView needs sha256 metadata for.
    final merged = t.attachments.isEmpty && t.attachmentCount == _current.attachmentCount
        ? t.copyWith(attachments: _current.attachments)
        : t;
    setState(() => _current = merged);
    widget.onChanged?.call(merged);
  }

  Future<void> _saveTextEdits() async {
    _bodyDebounce?.cancel();
    setState(() => _saving = true);
    final sentTitle = _titleCtl.text.trim();
    final sentBody = _bodyCtl.text;
    try {
      final updated = await _client.updateTodo(_id, title: sentTitle, bodyMd: sentBody);
      if (!mounted) return;
      // If the field(s) changed again while this request was in flight, the
      // just-saved snapshot is already stale — keep _textDirty set (and
      // re-arm the debounce) instead of clearing it, so those newer
      // keystrokes aren't silently dropped.
      final stale = _titleCtl.text.trim() != sentTitle || _bodyCtl.text != sentBody;
      setState(() {
        _saving = false;
        _textDirty = stale;
      });
      if (stale) {
        _bodyDebounce = Timer(const Duration(milliseconds: 700), () {
          if (_textDirty && mounted) _saveTextEdits();
        });
      }
      _applyUpdated(updated);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      snack(context, '保存失败: ${errorText(e)}');
    }
  }

  Future<void> _setStatus(TodoStatus s) async {
    try {
      final updated = await _client.setTodoStatus(_id, s);
      _applyUpdated(updated);
    } catch (e) {
      if (mounted) snack(context, '更新状态失败: ${errorText(e)}');
    }
  }

  Future<void> _patch({
    String? priority,
    String? recurrence,
    DateTime? dueAt,
    bool clearDueAt = false,
    String? workspaceName,
    String? repoName,
  }) async {
    try {
      final updated = await _client.updateTodo(
        _id,
        priority: priority,
        recurrence: recurrence,
        dueAt: dueAt,
        clearDueAt: clearDueAt,
        workspaceName: workspaceName,
        repoName: repoName,
      );
      _applyUpdated(updated);
    } catch (e) {
      if (mounted) snack(context, '更新失败: ${errorText(e)}');
    }
  }

  // _bindRepo/_clearRepo back the WorkspaceRepoControl pill — workspaceName/
  // repoName are always set (or cleared) together so the binding never ends
  // up half-pointing at a workspace with no repo (see the field docs on
  // pkg/todoschema.Todo).
  Future<void> _bindRepo(String workspaceName, String repoName) =>
      _patch(workspaceName: workspaceName, repoName: repoName);

  Future<void> _clearRepo() => _patch(workspaceName: '', repoName: '');

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final current = _current.dueAt ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: current.isBefore(DateTime(now.year - 1)) ? now : current,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null || !mounted) return;
    await _patch(
      dueAt: DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
  }

  // _assigneeLabel prefers the human-readable session label over the bare
  // identity — matches TodoCard's tooltip convention of always showing
  // something a person recognizes, not a raw identity string.
  String? get _assigneeLabel {
    final t = _current;
    if ((t.assigneeSessionLabel ?? '').isNotEmpty) return t.assigneeSessionLabel;
    return t.assigneeIdentity;
  }

  bool get _hasSessionBinding =>
      (_current.assigneeSessionId ?? '').isNotEmpty ||
      (_current.assigneeAgentSessionId ?? '').isNotEmpty;

  // _openOrResumeSession backs the assignee row's "打开/恢复会话" button:
  // jump straight to the bus session if it's still alive, else respawn from
  // the permanent resume trio (reverse-matching assigneeWorkdir against the
  // live config to find which workspace/project to launch in — the same
  // project/worktree match _isSessionWorkdir uses in workspace_page.dart).
  Future<void> _openOrResumeSession() async {
    final overview = widget.overviewStore;
    final cfg = widget.config;
    if (overview == null || cfg == null) return;
    final t = _current;

    final busSid = t.assigneeSessionId;
    if ((busSid ?? '').isNotEmpty &&
        overview.cards.any((c) => c.sid == busSid)) {
      _openSession(busSid!);
      return;
    }

    final resumeId = t.assigneeAgentSessionId;
    if ((resumeId ?? '').isEmpty) {
      snack(context, '会话已关闭，且没有可恢复的记录');
      return;
    }

    final workdir = t.assigneeWorkdir ?? '';
    String? wsName, projName;
    for (final ws in cfg.workspaces) {
      for (final p in ws.projects) {
        if (pathIsProjectWorkdir(workdir, p.path)) {
          wsName = ws.name;
          projName = p.name;
        }
        if (wsName != null) break;
      }
      if (wsName != null) break;
    }
    if (wsName == null || projName == null) {
      snack(context, '找不到对应工作区，无法恢复');
      return;
    }

    setState(() => _resumingSession = true);
    final (sid, err) = await overview.spawn(
      workspace: wsName,
      project: projName,
      kind: (t.assigneeAgentKind ?? '').isNotEmpty ? t.assigneeAgentKind! : 'claude',
      resumeAgentSessionId: resumeId,
      // Pass the exact saved dir through (not just the project it resolved
      // to) so a session that ran inside a worktree respawns there instead
      // of silently falling back to the project root — see
      // _spawnForDispatch/_spawnManagedSession in workspace_page.dart.
      workdir: workdir,
    );
    if (!mounted) return;
    setState(() => _resumingSession = false);
    if (sid == null) {
      snack(context, '恢复会话失败: ${err ?? "未知错误"}');
      return;
    }
    _openSession(sid);
  }

  void _openSession(String sid) {
    if (widget.onOpenSession != null) {
      widget.onOpenSession!(sid);
    } else {
      widget.overviewStore?.requestOpen(sid);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除待办'),
        content: const Text('确定删除这条待办吗？此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _client.deleteTodo(_id);
      widget.onDeleted?.call();
    } catch (e) {
      if (mounted) snack(context, '删除失败: ${errorText(e)}');
    }
  }

  Future<void> _postComment() async {
    final body = _commentCtl.text.trim();
    if (body.isEmpty) return;
    try {
      await _client.postTodoComment(_id, body);
      _commentCtl.clear();
      await reloadComments();
    } catch (e) {
      if (mounted) snack(context, '评论失败: ${errorText(e)}');
    }
  }

  Future<void> _pickAndUploadAttachments() async {
    final res =
        await FilePicker.platform.pickFiles(allowMultiple: true, withData: true);
    if (res == null || res.files.isEmpty || !mounted) return;
    setState(() => _uploading = true);
    for (final f in res.files) {
      try {
        Uint8List? bytes = f.bytes;
        bytes ??= f.path != null ? await File(f.path!).readAsBytes() : null;
        if (bytes == null) continue;
        await _client.uploadTodoAttachment(_id, f.name, bytes);
      } catch (e) {
        if (mounted) snack(context, '上传 ${f.name} 失败: ${errorText(e)}');
      }
    }
    if (!mounted) return;
    setState(() => _uploading = false);
    await _loadFull();
  }

  Color _statusColor(TodoStatus s) => switch (s) {
        TodoStatus.done => CcColors.ok,
        TodoStatus.cancelled => CcColors.subtle,
        TodoStatus.blocked => CcColors.danger,
        TodoStatus.inProgress => CcColors.accent,
        TodoStatus.assigned => CcColors.warning,
        TodoStatus.pending => CcColors.muted,
      };

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          flex: 2,
          child: SingleChildScrollView(child: _header()),
        ),
        TabBar(tabs: [
          Tab(text: '评论 (${_comments.length})'),
          Tab(text: '附件 (${_current.attachmentCount})'),
        ]),
        Expanded(
          flex: 3,
          child: TabBarView(children: [
            _commentsTab(),
            SingleChildScrollView(
                padding: const EdgeInsets.all(16), child: _attachmentsTab()),
          ]),
        ),
      ]),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                controller: _titleCtl,
                focusNode: _titleFocus,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w700, color: CcColors.text),
                decoration: const InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: '标题',
                ),
                onChanged: (_) => _markTextDirty(),
                onSubmitted: (_) => _saveTextEdits(),
              ),
            ),
            if (_saving)
              const Padding(
                padding: EdgeInsets.only(left: 8, top: 4),
                child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 19),
              tooltip: '删除待办',
              visualDensity: VisualDensity.compact,
              onPressed: _delete,
            ),
          ]),
          const SizedBox(height: 10),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusControl(
                status: _current.status,
                colorOf: _statusColor,
                onChanged: _setStatus,
              ),
              _dot(),
              PriorityControl(
                priority: priorityLabels.containsKey(_current.priority)
                    ? _current.priority
                    : 'normal',
                onChanged: (v) => _patch(priority: v),
              ),
              _dot(),
              RecurrenceControl(
                recurrence: recurrenceLabels.containsKey(_current.recurrence)
                    ? _current.recurrence
                    : '',
                onChanged: (v) => _patch(recurrence: v),
              ),
              _dot(),
              DueDatePill(
                dueAt: _current.dueAt,
                onTap: _pickDueDate,
                onClear: () => _patch(clearDueAt: true),
              ),
              _dot(),
              WorkspaceRepoControl(
                workspaceName: _current.workspaceName,
                repoName: _current.repoName,
                workspaces: widget.config?.workspaces ?? const [],
                onBind: _bindRepo,
                onClear: _clearRepo,
              ),
            ],
          ),
          if ((_current.assigneeIdentity ?? '').isNotEmpty ||
              _hasSessionBinding) ...[
            const SizedBox(height: 8),
            _assigneeRow(),
          ],
          const SizedBox(height: 4),
          const Divider(height: 20),
          _body(),
        ]),
      );

  // _assigneeRow shows who a todo is assigned to plus, when there's a
  // session binding to try, the "打开/恢复会话" button — jumps to the live
  // bus session if it's still around, else respawns from the permanent
  // resume trio (see _openOrResumeSession).
  Widget _assigneeRow() => Row(
        children: [
          const Icon(Icons.person_outline_rounded, size: 14, color: CcColors.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '指派给 ${_assigneeLabel ?? "未知"}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: CcColors.muted),
            ),
          ),
          if (_hasSessionBinding &&
              widget.overviewStore != null &&
              widget.config != null)
            TextButton.icon(
              onPressed: _resumingSession ? null : _openOrResumeSession,
              icon: _resumingSession
                  ? const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_circle_outline_rounded, size: 15),
              label: const Text('打开/恢复会话', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
            ),
        ],
      );

  // AnimatedSize softens the height jump between the two states — inherent
  // whenever the body has an inline image, since the editor collapses it
  // back down to one line of `![](name)` text while focused (documented
  // editor/display split, not a bug: keeping body_md a literal markdown
  // string means there's no shared layout between "image" and "image
  // reference text" to animate between, only the container size).
  Widget _body() => AnimatedSize(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        alignment: Alignment.topLeft,
        child: _bodyEditing
            ? MarkdownLiteEditor(
                controller: _bodyCtl,
                focusNode: _bodyFocus,
                client: _client,
                todoId: _id,
                hintText: '添加描述…支持 # 标题 / - 列表 / **加粗**',
                onChanged: _onBodyChanged,
                autofocus: true,
                minLines: 4,
                maxLines: 14,
              )
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _bodyEditing = true),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 88),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: TodoBodyView(
                      client: _client,
                      todoId: _id,
                      bodyMd: _bodyCtl.text,
                      attachments: _current.attachments,
                    ),
                  ),
                ),
              ),
      );

  Widget _dot() => Container(
        width: 3,
        height: 3,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration:
            const BoxDecoration(color: CcColors.border, shape: BoxShape.circle),
      );

  Widget _commentsTab() => Column(children: [
        Expanded(
          child: _comments.isEmpty
              ? centerMsg('暂无评论')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                  itemCount: _comments.length,
                  itemBuilder: (_, i) {
                    final c = _comments[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Text(c.authorIdentity,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 12.5)),
                            const SizedBox(width: 8),
                            Text(relativeTime(c.createdAt),
                                style: const TextStyle(
                                    color: CcColors.subtle, fontSize: 11)),
                          ]),
                          const SizedBox(height: 3),
                          SelectableText(c.body,
                              style: const TextStyle(fontSize: 13.5, height: 1.45)),
                        ],
                      ),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(children: [
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
                onPressed: _postComment,
                icon: const Icon(Icons.send_rounded, size: 20)),
          ]),
        ),
      ]);

  Widget _attachmentsTab() {
    final atts = _current.attachments;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('附件',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: _uploading ? null : _pickAndUploadAttachments,
          icon: _uploading
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.add_rounded, size: 16),
          label: Text(_uploading ? '上传中…' : '添加附件'),
        ),
      ]),
      const SizedBox(height: 12),
      if (atts.isEmpty && _loadingAttachments && _current.attachmentCount > 0)
        const Center(
            child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(strokeWidth: 2)))
      else if (atts.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('暂无附件', style: TextStyle(color: CcColors.muted)),
        )
      else
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: atts.map((a) => _attachmentTile(a)).toList(),
        ),
    ]);
  }

  Widget _attachmentTile(TodoAttachment a) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TodoAttachmentThumb(client: _client, todoId: _id, attachment: a, size: 72),
          const SizedBox(height: 4),
          SizedBox(
            width: 80,
            child: Text(
              a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      );
}
