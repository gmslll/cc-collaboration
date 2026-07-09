import 'package:flutter/material.dart';

import '../api/todo_models.dart';
import '../local/config.dart';
import '../theme.dart';
import '../widgets.dart';

// Linear-flavored field controls for the todo detail/create panels: each is
// a compact, borderless pill that shows its current value and opens a small
// popup menu on tap — "click the field to edit it" instead of a permanent
// row of DropdownButtons. Centralised here so the detail view and the quick-
// create panel render priority/status/recurrence identically.

const priorityLabels = {'low': '低', 'normal': '普通', 'high': '高'};
const recurrenceLabels = {
  '': '不重复',
  'daily': '每天',
  'weekly': '每周',
  'monthly': '每月',
};

Color priorityColor(String p) => switch (p) {
  'high' => CcColors.danger,
  'low' => CcColors.subtle,
  _ => CcColors.muted,
};

// todoStatusColor is the single source of truth for status dot/pill colors —
// shared by the board (todos_page.dart), the detail view's StatusControl
// pill (todo_detail_view.dart), and StatusControl's own dropdown here, so
// the 8-status palette only needs to be picked once. Triage's warning amber
// signals "needs a decision"; backlog/todo/canceled stay in the neutral
// gray family (dormant/default/receded) while in_progress/in_review/done
// each get their own hue so the pipeline stages read apart on the board;
// duplicate gets a distinct violet since it isn't really a pipeline stage at
// all, just a terminal "merged into another issue" marker.
Color todoStatusColor(TodoStatus s) => switch (s) {
  TodoStatus.triage => CcColors.warning,
  TodoStatus.backlog => CcColors.borderSoft,
  TodoStatus.todo => CcColors.muted,
  TodoStatus.inProgress => CcColors.accent,
  TodoStatus.inReview => CcColors.info,
  TodoStatus.done => CcColors.ok,
  TodoStatus.canceled => CcColors.subtle,
  TodoStatus.duplicate => CcColors.violet,
};

// priorityBars is Linear's priority glyph: 3 bars of increasing height,
// filled up to the level (low=1, normal=2, high=3) in the level's color.
Widget priorityBars(
  String priority, {
  double maxHeight = 11,
  double barWidth = 3,
}) {
  final filled = switch (priority) {
    'low' => 1,
    'high' => 3,
    _ => 2,
  };
  final color = priorityColor(priority);
  final heights = [maxHeight * 0.42, maxHeight * 0.7, maxHeight];
  return Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      for (var i = 0; i < 3; i++) ...[
        if (i > 0) const SizedBox(width: 2),
        Container(
          width: barWidth,
          height: heights[i],
          decoration: BoxDecoration(
            color: i < filled ? color : CcColors.border,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ],
    ],
  );
}

// _pillTap wraps [child] as a hoverable, tappable pill (transparent until
// hovered/pressed) — the shared shell every property control renders inside.
Widget _pillTap({
  required GlobalKey key,
  required VoidCallback onTap,
  required Widget child,
}) => Material(
  key: key,
  color: Colors.transparent,
  child: InkWell(
    borderRadius: BorderRadius.circular(CcRadius.sm),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: child,
    ),
  ),
);

Future<T?> _openBelow<T>(
  BuildContext context,
  GlobalKey key,
  List<PopupMenuEntry<T>> items,
) {
  final box = key.currentContext!.findRenderObject() as RenderBox;
  final pos = box.localToGlobal(Offset(0, box.size.height + 4));
  return showMenu<T>(
    context: context,
    position: menuPosAt(context, pos),
    items: items,
  );
}

PopupMenuItem<T> _checkableRow<T>({
  required T value,
  required bool selected,
  required Widget leading,
  required String label,
}) => PopupMenuItem<T>(
  value: value,
  height: 32,
  child: Row(
    children: [
      leading,
      const SizedBox(width: 8),
      Expanded(
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      if (selected) ...[
        const SizedBox(width: 8),
        const Icon(Icons.check_rounded, size: 14, color: CcColors.accentBright),
      ],
    ],
  ),
);

class PriorityControl extends StatefulWidget {
  final String priority;
  final ValueChanged<String> onChanged;
  final bool showLabel;
  const PriorityControl({
    super.key,
    required this.priority,
    required this.onChanged,
    this.showLabel = true,
  });

  @override
  State<PriorityControl> createState() => _PriorityControlState();
}

class _PriorityControlState extends State<PriorityControl> {
  final _key = GlobalKey();

  Future<void> _open() async {
    final v = await _openBelow<String>(context, _key, [
      for (final p in const ['high', 'normal', 'low'])
        _checkableRow<String>(
          value: p,
          selected: p == widget.priority,
          leading: priorityBars(p),
          label: priorityLabels[p]!,
        ),
    ]);
    if (!mounted) return;
    if (v != null) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) => _pillTap(
    key: _key,
    onTap: _open,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        priorityBars(widget.priority),
        if (widget.showLabel) ...[
          const SizedBox(width: 6),
          Text(
            priorityLabels[widget.priority] ?? '普通',
            style: const TextStyle(fontSize: 12.5, color: CcColors.muted),
          ),
        ],
      ],
    ),
  );
}

class StatusControl extends StatefulWidget {
  final TodoStatus status;
  final Color Function(TodoStatus) colorOf;
  final ValueChanged<TodoStatus> onChanged;
  const StatusControl({
    super.key,
    required this.status,
    required this.colorOf,
    required this.onChanged,
  });

  @override
  State<StatusControl> createState() => _StatusControlState();
}

class _StatusControlState extends State<StatusControl> {
  final _key = GlobalKey();

  Future<void> _open() async {
    final v = await _openBelow<TodoStatus>(context, _key, [
      for (final s in TodoStatus.values)
        _checkableRow<TodoStatus>(
          value: s,
          selected: s == widget.status,
          leading: statusDot(widget.colorOf(s), size: 8),
          label: todoStatusLabel(s),
        ),
    ]);
    if (!mounted) return;
    if (v != null) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.colorOf(widget.status);
    return _pillTap(
      key: _key,
      onTap: _open,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          statusDot(
            color,
            size: 8,
            glow: widget.status == TodoStatus.inProgress,
          ),
          const SizedBox(width: 6),
          Text(
            todoStatusLabel(widget.status),
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class RecurrenceControl extends StatefulWidget {
  final String recurrence;
  final ValueChanged<String> onChanged;
  const RecurrenceControl({
    super.key,
    required this.recurrence,
    required this.onChanged,
  });

  @override
  State<RecurrenceControl> createState() => _RecurrenceControlState();
}

class _RecurrenceControlState extends State<RecurrenceControl> {
  final _key = GlobalKey();

  Future<void> _open() async {
    final v = await _openBelow<String>(context, _key, [
      for (final e in recurrenceLabels.entries)
        _checkableRow<String>(
          value: e.key,
          selected: e.key == widget.recurrence,
          leading: const Icon(
            Icons.repeat_rounded,
            size: 14,
            color: CcColors.muted,
          ),
          label: e.value,
        ),
    ]);
    if (!mounted) return;
    if (v != null) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.recurrence.isNotEmpty;
    return _pillTap(
      key: _key,
      onTap: _open,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.repeat_rounded,
            size: 14,
            color: active ? CcColors.accentBright : CcColors.subtle,
          ),
          const SizedBox(width: 6),
          Text(
            recurrenceLabels[widget.recurrence] ?? '不重复',
            style: TextStyle(
              fontSize: 12.5,
              color: active ? CcColors.text : CcColors.subtle,
            ),
          ),
        ],
      ),
    );
  }
}

class DueDatePill extends StatelessWidget {
  final DateTime? dueAt;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  const DueDatePill({
    super.key,
    required this.dueAt,
    required this.onTap,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final due = dueAt;
    final has = due != null;
    final overdue = has && due.isBefore(DateTime.now());
    final color = !has
        ? CcColors.subtle
        : (overdue ? CcColors.danger : CcColors.muted);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(CcRadius.sm),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.calendar_today_rounded, size: 13, color: color),
              const SizedBox(width: 6),
              Text(
                has ? commitDate(due) : '截止日期',
                style: TextStyle(
                  fontSize: 12.5,
                  color: color,
                  fontWeight: has ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              if (has && onClear != null) ...[
                const SizedBox(width: 2),
                InkWell(
                  onTap: onClear,
                  borderRadius: BorderRadius.circular(10),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(
                      Icons.close_rounded,
                      size: 12,
                      color: CcColors.subtle,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// WorkspaceRepoControl is the optional "绑定库" pill: click opens a
// workspace picker, then (immediately, anchored at the same spot) a repo
// picker scoped to that workspace — a two-step menu rather than a nested
// submenu widget, same trick RecurrenceControl's siblings use for a single
// flat list. Both workspaceName/repoName null (or empty) means "unbound".
class WorkspaceRepoControl extends StatefulWidget {
  final String? workspaceName;
  final String? repoName;
  final List<WorkspaceCfg> workspaces;
  final void Function(String workspaceName, String repoName) onBind;
  final VoidCallback onClear;
  const WorkspaceRepoControl({
    super.key,
    required this.workspaceName,
    required this.repoName,
    required this.workspaces,
    required this.onBind,
    required this.onClear,
  });

  @override
  State<WorkspaceRepoControl> createState() => _WorkspaceRepoControlState();
}

class _WorkspaceRepoControlState extends State<WorkspaceRepoControl> {
  final _key = GlobalKey();

  Future<void> _open() async {
    if (widget.workspaces.isEmpty) return;
    final ws = await _openBelow<WorkspaceCfg>(context, _key, [
      for (final w in widget.workspaces)
        _checkableRow<WorkspaceCfg>(
          value: w,
          selected: w.name == widget.workspaceName,
          leading: const Icon(
            Icons.dns_rounded,
            size: 14,
            color: CcColors.muted,
          ),
          label: w.name,
        ),
    ]);
    if (ws == null || !mounted) return;
    if (ws.projects.isEmpty) {
      snack(context, '${ws.name} 下没有已配置的库');
      return;
    }
    final repo = await _openBelow<ProjectCfg>(context, _key, [
      for (final p in ws.projects)
        _checkableRow<ProjectCfg>(
          value: p,
          selected:
              ws.name == widget.workspaceName && p.name == widget.repoName,
          leading: const Icon(
            Icons.source_rounded,
            size: 14,
            color: CcColors.muted,
          ),
          label: p.name,
        ),
    ]);
    if (repo == null) return;
    if (!mounted) return;
    widget.onBind(ws.name, repo.name);
  }

  @override
  Widget build(BuildContext context) {
    final bound =
        (widget.workspaceName ?? '').isNotEmpty &&
        (widget.repoName ?? '').isNotEmpty;
    return _pillTap(
      key: _key,
      onTap: _open,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.dns_rounded,
            size: 14,
            color: bound ? CcColors.accentBright : CcColors.subtle,
          ),
          const SizedBox(width: 6),
          Text(
            bound ? '${widget.workspaceName} / ${widget.repoName}' : '未绑定库',
            style: TextStyle(
              fontSize: 12.5,
              color: bound ? CcColors.text : CcColors.subtle,
            ),
          ),
          if (bound) ...[
            const SizedBox(width: 2),
            InkWell(
              onTap: widget.onClear,
              borderRadius: BorderRadius.circular(10),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(
                  Icons.close_rounded,
                  size: 12,
                  color: CcColors.subtle,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// GroupControl is the 分组 pill: a single-level "输入即创建" picker — unlike
// WorkspaceRepoControl's two-step workspace-then-repo menu, a group is just
// one flat name, so tapping opens one dialog with a text field (type a new
// name or filter the existing list) plus the matching existing groups below
// it. There's no separate "create group" action: submitting a name that
// doesn't exist yet simply assigns it, and it "exists" from then on because
// some todo points at it (see pkg/todoschema.Todo.GroupName).
class GroupControl extends StatefulWidget {
  final String? groupName;
  final List<String> existingGroups;
  final ValueChanged<String> onSelect;
  final VoidCallback? onClear;
  const GroupControl({
    super.key,
    required this.groupName,
    required this.existingGroups,
    required this.onSelect,
    this.onClear,
  });

  @override
  State<GroupControl> createState() => _GroupControlState();
}

double groupPickerListMaxHeight(
  Size screenSize, {
  double preferred = 180,
  double minHeight = 96,
  double maxFraction = 0.34,
}) {
  final height = screenSize.height;
  if (!height.isFinite || height <= 0) return preferred;
  final capped = height * maxFraction.clamp(0, 1);
  if (capped >= preferred) return preferred;
  return capped < minHeight ? minHeight : capped;
}

class _GroupControlState extends State<GroupControl> {
  final _key = GlobalKey();

  Future<void> _open() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _GroupPickerDialog(
        current: widget.groupName,
        existing: widget.existingGroups,
      ),
    );
    if (!mounted) return;
    if (result != null && result.isNotEmpty) widget.onSelect(result);
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.groupName ?? '';
    final has = name.isNotEmpty;
    return _pillTap(
      key: _key,
      onTap: _open,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_outlined,
            size: 14,
            color: has ? CcColors.accentBright : CcColors.subtle,
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              has ? name : '未分组',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: has ? CcColors.text : CcColors.subtle,
              ),
            ),
          ),
          if (has && widget.onClear != null) ...[
            const SizedBox(width: 2),
            InkWell(
              onTap: widget.onClear,
              borderRadius: BorderRadius.circular(10),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(
                  Icons.close_rounded,
                  size: 12,
                  color: CcColors.subtle,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _GroupPickerDialog extends StatefulWidget {
  final String? current;
  final List<String> existing;
  const _GroupPickerDialog({required this.current, required this.existing});

  @override
  State<_GroupPickerDialog> createState() => _GroupPickerDialogState();
}

class _GroupPickerDialogState extends State<_GroupPickerDialog> {
  late final _ctl = TextEditingController(text: widget.current ?? '');

  List<String> get _filtered {
    final q = _ctl.text.trim().toLowerCase();
    final names = widget.existing.where((g) => g.isNotEmpty);
    if (q.isEmpty) return names.toList();
    return names.where((g) => g.toLowerCase().contains(q)).toList();
  }

  void _submit(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    Navigator.pop(context, trimmed);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _ctl.text.trim();
    final matches = _filtered;
    final isNewName =
        q.isNotEmpty && !matches.any((g) => g.toLowerCase() == q.toLowerCase());
    return AlertDialog(
      title: const Text('分组'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _ctl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '输入分组名，回车创建/选择',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: _submit,
            ),
            if (matches.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: groupPickerListMaxHeight(
                      MediaQuery.sizeOf(context),
                    ),
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final g in matches)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.folder_outlined, size: 16),
                          title: Text(
                            g,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.pop(context, g),
                        ),
                    ],
                  ),
                ),
              )
            else if (isNewName)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '将创建新分组 "$q"',
                  style: const TextStyle(color: CcColors.muted, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: q.isEmpty ? null : () => _submit(q),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
