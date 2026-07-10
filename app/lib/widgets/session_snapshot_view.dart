import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../local/session_overview.dart';
import '../terminal_theme.dart';
import '../theme.dart';

// SessionSnapshotView renders one coloured live-screen [ScreenSnapshot] as a real
// xterm view sized to the SOURCE terminal's width — NOT reflowed to this widget's
// width, so box art / separators / the agent's input prompt stay aligned instead
// of shattering (see the reflow trap in terminal_snapshot_formatter.dart).
//
// It renders at [fontSize] NATIVELY (crisp text, no downscaling) and keeps the
// viewport pinned to the bottom so the current prompt stays in view; content
// wider/taller than the box is clipped (vertical scroll built in). The PARENT
// owns the box size, so a resizable popup + a zoom control just change the
// surrounding SizedBox and [fontSize]. Shared by the desktop overview popup and
// the phone/remote popup.
class SessionSnapshotView extends StatefulWidget {
  final ScreenSnapshot? snapshot;
  final double fontSize;
  const SessionSnapshotView({
    super.key,
    required this.snapshot,
    this.fontSize = 12,
  });

  @override
  State<SessionSnapshotView> createState() => _SessionSnapshotViewState();
}

class _SessionSnapshotViewState extends State<SessionSnapshotView> {
  // Independent of the source session's Terminal so it never fights it for PTY
  // size; small buffer = cheap rewrites. Resized per-snapshot to the source
  // geometry so content lands at its native width (no reflow).
  final Terminal _term = ccTerminal(maxLines: 200, answerColorQueries: false);
  final ScrollController _scroll = ScrollController();

  TerminalStyle get _style =>
      TerminalStyle(fontFamily: 'JetBrainsMono', fontSize: widget.fontSize);

  @override
  void initState() {
    super.initState();
    _paint();
  }

  @override
  void didUpdateWidget(SessionSnapshotView old) {
    super.didUpdateWidget(old);
    if (widget.snapshot != old.snapshot) _paint();
    // Re-pin to the bottom after a zoom / resize rebuild too.
    _scrollToBottomSoon();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // Source geometry — falls back to xterm's 80×24 default when the snapshot is
  // absent or carries none (e.g. an older remote host that sent no cols/rows).
  (int, int) _geometry() {
    final s = widget.snapshot;
    final cols = (s == null || s.cols < 1) ? 80 : s.cols;
    final rows = (s == null || s.rows < 1) ? 24 : s.rows;
    return (cols, rows);
  }

  void _paint() {
    final s = widget.snapshot;
    if (s == null) return;
    final (cols, rows) = _geometry();
    _term.resize(cols, rows);
    _term.write('\x1b[3J\x1b[2J\x1b[H'); // clear scrollback + screen, home
    _term.write(s.ansi);
    _scrollToBottomSoon();
  }

  // Keep the most-recent rows (the prompt) in view when content is taller than
  // the box; a no-op when it all fits (maxScrollExtent == 0).
  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Fills the parent's box (a resizable popup drives its height/width). Native
    // font size — no FittedBox — so text is crisp and readable at any zoom.
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ccTerminalTheme.background,
        borderRadius: BorderRadius.circular(CcRadius.sm),
        border: Border.all(color: CcColors.border),
      ),
      padding: const EdgeInsets.all(8),
      child: TerminalView(
        _term,
        theme: ccTerminalTheme,
        textStyle: _style,
        padding: EdgeInsets.zero,
        autoResize: false, // keep _term at the source width; don't reflow
        readOnly: true,
        scrollController: _scroll,
      ),
    );
  }
}
