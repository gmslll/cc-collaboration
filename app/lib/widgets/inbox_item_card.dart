import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme.dart';
import '../widgets.dart';

// InboxItemCard is a compact work-package row for the workspace's queue sidebar —
// same visual register as TodoCard (top row + two-line title + tag row +
// footer) but built off ListItem's fields (repoName/sender/recipient/
// urgency/state/kind) instead of Todo's (priority/assigneeIdentity/recurrence).
class InboxItemCard extends StatelessWidget {
  final ListItem item;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  const InboxItemCard({
    super.key,
    required this.item,
    this.onTap,
    this.padding = const EdgeInsets.all(10),
  });

  Color _kindColor(String kind) {
    if (kind == 'bug') return CcColors.danger;
    if (kind == 'request') return CcColors.warning;
    return CcColors.accent;
  }

  @override
  Widget build(BuildContext context) {
    final urgent = item.urgency == 'urgent';
    final hasRoute = item.sender.isNotEmpty && item.recipient.isNotEmpty;
    return HoverLift(
      onTap: onTap,
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              statusDot(
                urgent ? CcColors.danger : _kindColor(item.kind),
                size: 9,
                glow: urgent,
              ),
              const Spacer(),
              kindBadge(item.kind),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            item.headline.isNotEmpty ? item.headline : item.id,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          if (item.repoName.isNotEmpty || hasRoute) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (item.repoName.isNotEmpty)
                  _miniTag(Icons.source_rounded, item.repoName, CcColors.muted),
                if (hasRoute)
                  _miniTag(
                    Icons.swap_horiz_rounded,
                    '${item.sender} → ${item.recipient}',
                    CcColors.accentBright,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Text(
            '创建于 ${relativeTime(item.createdAt)}',
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
