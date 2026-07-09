import 'package:flutter/material.dart';

import '../local/git.dart';
import '../theme.dart';
import '../widgets.dart';

class HistoryCommitTile extends StatelessWidget {
  final GitCommit commit;
  final bool selected;
  final bool disabled;
  final VoidCallback? onTap;

  const HistoryCommitTile({
    super.key,
    required this.commit,
    required this.selected,
    this.disabled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final age = commit.date.millisecondsSinceEpoch == 0
        ? ''
        : relativeTime(commit.date);
    final ref = commit.refs.replaceAll('HEAD -> ', '').split(',').first.trim();

    return Material(
      color: selected
          ? CcColors.accent.withValues(alpha: 0.10)
          : Colors.transparent,
      child: ListTile(
        dense: true,
        selected: selected,
        leading: Icon(
          Icons.commit_rounded,
          size: 17,
          color: selected ? CcColors.accentBright : CcColors.muted,
        ),
        title: Text(
          commit.subject,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            [
              commit.shortHash,
              commit.author,
              if (age.isNotEmpty) age,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CcType.code(size: 11, color: CcColors.subtle),
          ),
        ),
        trailing: ref.isEmpty
            ? null
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 86),
                child: tag(ref, CcColors.accent),
              ),
        onTap: disabled ? null : onTap,
      ),
    );
  }
}
