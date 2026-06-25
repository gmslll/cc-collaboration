import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../theme.dart';

// MarkdownView is a scrollable, dark-themed rendered Markdown pane — the
// "preview" side of a .md file in the editor. Reuses flutter_markdown (already
// used in handoff_detail_view) with a stylesheet tuned for the cockpit theme.
class MarkdownView extends StatelessWidget {
  final String data;
  const MarkdownView({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: CcColors.bg,
      child: Markdown(
        data: data,
        selectable: true,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        styleSheet: _sheet(context),
      ),
    );
  }

  MarkdownStyleSheet _sheet(BuildContext context) =>
      MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: const TextStyle(color: CcColors.text, fontSize: 14, height: 1.55),
        listBullet: const TextStyle(color: CcColors.text, fontSize: 14),
        h1: const TextStyle(
          color: CcColors.text,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
        h2: const TextStyle(
          color: CcColors.text,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
        h3: const TextStyle(
          color: CcColors.text,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        a: const TextStyle(color: CcColors.accentBright),
        code: const TextStyle(
          fontFamily: CcType.mono,
          fontSize: 12.5,
          color: CcColors.accentBright,
          backgroundColor: CcColors.panelHigh,
        ),
        codeblockPadding: const EdgeInsets.all(12),
        codeblockDecoration: BoxDecoration(
          color: CcColors.panel,
          borderRadius: BorderRadius.circular(CcRadius.sm),
          border: Border.all(color: CcColors.border),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12),
        blockquoteDecoration: const BoxDecoration(
          border: Border(left: BorderSide(color: CcColors.accent, width: 3)),
        ),
        horizontalRuleDecoration: const BoxDecoration(
          border: Border(top: BorderSide(color: CcColors.border)),
        ),
        tableBorder: TableBorder.all(color: CcColors.border),
        tableHead: const TextStyle(
          color: CcColors.text,
          fontWeight: FontWeight.w700,
        ),
        tableBody: const TextStyle(color: CcColors.text, fontSize: 13.5),
      );
}
