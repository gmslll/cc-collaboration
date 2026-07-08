import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../local/session_overview.dart';
import '../terminal_theme.dart';
import '../theme.dart';

// SessionSnapshotView renders one coloured live-screen [ScreenSnapshot] as a real
// xterm view sized to the SOURCE terminal's width — NOT reflowed to this widget's
// (narrower) width. A throwaway Terminal is resized to the source cols×rows and
// the whole grid is scaled to fit via FittedBox, so box art / separators / the
// agent's input prompt stay aligned instead of shattering when re-wrapped (see
// the "Absolute-positioned TUI chrome flattens" trap in terminal_pane.dart /
// terminal_snapshot_formatter.dart). The parent owns fetching + poll timing and
// just feeds the latest snapshot; identical records (structural equality) don't
// repaint. Shared by the desktop overview popup and the phone/remote popup.
class SessionSnapshotView extends StatefulWidget {
  final ScreenSnapshot? snapshot;
  // Fixed outer box height (280 desktop / 220 phone). Width fills the parent.
  final double height;
  final double fontSize;
  const SessionSnapshotView({
    super.key,
    required this.snapshot,
    required this.height,
    this.fontSize = 12,
  });

  @override
  State<SessionSnapshotView> createState() => _SessionSnapshotViewState();
}

class _SessionSnapshotViewState extends State<SessionSnapshotView> {
  // Independent of the source session's Terminal so it never fights it for PTY
  // size; small buffer = cheap rewrites. Resized per-snapshot to the source
  // geometry so content lands at its native width (no reflow).
  final Terminal _term = ccTerminal(maxLines: 200);

  // One style for both the cell measurement and the rendered TerminalView so
  // the SizedBox we hand FittedBox can't diverge from what's painted.
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
  }

  // Source geometry — one source of truth for both the terminal resize and the
  // SizedBox sizing. Falls back to xterm's 80×24 default when the snapshot is
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
  }

  @override
  Widget build(BuildContext context) {
    // calcCharSize is the exact measurement the renderer uses to size its own
    // cell grid, so the SizedBox matches the painted width to the pixel — no
    // reflow, no clipping, no slack fudge.
    final cell = calcCharSize(_style, MediaQuery.textScalerOf(context));
    final (cols, rows) = _geometry();
    return Container(
      height: widget.height,
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ccTerminalTheme.background,
        borderRadius: BorderRadius.circular(CcRadius.sm),
        border: Border.all(color: CcColors.border),
      ),
      padding: const EdgeInsets.all(8),
      child: FittedBox(
        fit: BoxFit.scaleDown, // shrink wide screens to fit; never upscale
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: cols * cell.width,
          height: rows * cell.height,
          child: TerminalView(
            _term,
            theme: ccTerminalTheme,
            textStyle: _style,
            padding: EdgeInsets.zero,
            autoResize: false, // keep _term at the source width; don't reflow
            readOnly: true,
          ),
        ),
      ),
    );
  }
}
