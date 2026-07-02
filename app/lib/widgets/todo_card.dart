import 'package:flutter/material.dart';

import '../api/todo_models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'todo_property_controls.dart';

// TodoCard is the Linear-flavored board/list card shared by the kanban board,
// the mobile card stream, and (future) the workspace sidebar — one widget so
// all three stay visually identical. Layout mirrors the reference screenshot:
// priority glyph + assignee avatar on the top row, a two-line title, a tag
// row (recurrence / project), and a "created X ago" footer.
class TodoCard extends StatelessWidget {
  final Todo todo;
  final VoidCallback? onTap;
  // Resolved by the caller (TodosPage knows Me.projects; this widget stays
  // decoupled from RelayClient/Me so it's reusable from contexts that don't
  // have those in scope) — null for personal todos or an unresolved project.
  final String? projectName;
  final EdgeInsetsGeometry padding;

  const TodoCard({
    super.key,
    required this.todo,
    this.onTap,
    this.projectName,
    this.padding = const EdgeInsets.all(10),
  });

  @override
  Widget build(BuildContext context) {
    final blocked = todo.status == TodoStatus.blocked;
    final recurrenceLabel = todo.recurrence.isEmpty
        ? null
        : recurrenceLabels[todo.recurrence];
    return HoverLift(
      onTap: onTap,
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              priorityBars(todo.priority, maxHeight: 12),
              if (blocked) ...[
                const SizedBox(width: 6),
                const Tooltip(
                  message: '受阻',
                  child: Icon(
                    Icons.error_outline_rounded,
                    size: 14,
                    color: CcColors.danger,
                  ),
                ),
              ],
              const Spacer(),
              _AssigneeAvatar(identity: todo.assigneeIdentity),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            todo.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          if (recurrenceLabel != null ||
              projectName != null ||
              (todo.repoName ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (recurrenceLabel != null)
                  _miniTag(
                    Icons.repeat_rounded,
                    recurrenceLabel,
                    CcColors.accentBright,
                  ),
                if (projectName != null)
                  _miniTag(Icons.folder_rounded, projectName!, CcColors.muted),
                if ((todo.repoName ?? '').isNotEmpty)
                  _miniTag(Icons.source_rounded, todo.repoName!, CcColors.muted),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Text(
            '创建于 ${relativeTime(todo.createdAt)}',
            style: const TextStyle(
              fontFamily: CcType.mono,
              fontSize: 10.5,
              color: CcColors.subtle,
            ),
          ),
        ],
      ),
    );
  }
}

Widget _miniTag(IconData icon, String label, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
  decoration: BoxDecoration(
    color: color.withValues(alpha: 0.12),
    border: Border.all(color: color.withValues(alpha: 0.35)),
    borderRadius: BorderRadius.circular(CcRadius.sm),
  ),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 10.5, color: color),
      const SizedBox(width: 4),
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  ),
);

// _AssigneeAvatar shows a filled initial glyph for an assigned todo, or a
// hollow ring when nobody's picked it up yet — never invents a new color, it
// just tints the existing accent color like every other "assigned" affordance
// in this app (see StatusControl's inProgress dot).
class _AssigneeAvatar extends StatelessWidget {
  final String? identity;
  const _AssigneeAvatar({required this.identity});

  @override
  Widget build(BuildContext context) {
    const size = 20.0;
    final id = identity;
    if (id == null || id.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: CcColors.border),
        ),
      );
    }
    final initial = id.trim().isEmpty ? '?' : id.trim()[0].toUpperCase();
    return Tooltip(
      message: id,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: CcColors.accent.withValues(alpha: 0.18),
          border: Border.all(color: CcColors.accent.withValues(alpha: 0.5)),
        ),
        child: Text(
          initial,
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: CcColors.accentBright,
          ),
        ),
      ),
    );
  }
}
