import 'package:xterm/xterm.dart';

// WheelMouseHandler fixes mouse-wheel / touch scrolling in full-screen TUIs.
//
// Full-screen agents (claude/codex) run in the alternate screen buffer, which
// has no scrollback: xterm routes wheel/drag scroll through mouseInput → this
// handler. xterm 4.0.0's default handler is doubly broken for the wheel:
// (1) in basic click-tracking mode it drops wheel events entirely, and (2) it
// encodes the wheel button as 64+4 / 64+5 (= 68 / 69) instead of the standard
// transposed X11 codes 64 / 65. Either way the TUI never sees a scroll (it
// scrolls fine in real terminals, which send 64 / 65). This handler reports the
// wheel with the correct codes whenever the app declares a scroll-reporting
// mouse mode, and defers all non-wheel events (clicks/drag/move) to the package
// default.
//
// Shared by the desktop terminal (TerminalSession) and the phone's remote
// terminal (RemoteClient) so both scroll identically.
class WheelMouseHandler implements TerminalMouseHandler {
  const WheelMouseHandler();

  @override
  String? call(TerminalMouseEvent e) {
    // Map the wheel buttons to their transposed X11 codes; everything else
    // (clicks, drag, move) falls to the package default. This single switch
    // both filters to wheel events and yields the code.
    final code = switch (e.button) {
      TerminalMouseButton.wheelUp => 64,
      TerminalMouseButton.wheelDown => 65,
      TerminalMouseButton.wheelLeft => 66,
      TerminalMouseButton.wheelRight => 67,
      _ => null,
    };
    if (code == null) return defaultMouseHandler(e);
    // Only send wheel codes when the app actually reports scroll
    // (upDownScroll/Drag/Move). For none/clickOnly, return null so the
    // TerminalView's simulateScroll fallback sends arrow keys instead — the
    // same behavior as real terminals.
    if (!e.state.mouseMode.reportScroll) return null;
    // Only the wheel "press" is reported; releases are not.
    if (e.buttonState != TerminalMouseButtonState.down) return null;
    return encodeWheel(code, e.position.x + 1, e.position.y + 1, e.state.mouseReportMode);
  }
}

// encodeWheel formats a single wheel report (button code 64/65/66/67 at 1-based
// cell x,y) in the encoding the app requested. Single source of truth shared by
// WheelMouseHandler (desktop/phone wheel events) and terminalWheel (phone's
// synthetic swipe / scroll buttons).
String encodeWheel(int code, int x, int y, MouseReportMode mode) =>
    switch (mode) {
      MouseReportMode.sgr => '\x1b[<$code;$x;${y}M',
      MouseReportMode.urxvt => '\x1b[${32 + code};$x;${y}M',
      MouseReportMode.normal || MouseReportMode.utf =>
        '\x1b[M${String.fromCharCode(32 + code)}'
            '${String.fromCharCode(32 + x)}${String.fromCharCode(32 + y)}',
    };

// terminalWheel builds the report for one synthetic scroll step (up=earlier).
// The phone has no real wheel, so swipe gestures and the on-screen ▲▼ buttons
// call this to drive a full-screen TUI (claude/codex) the same way a Mac wheel
// would. Returns null when the app isn't in a scroll-reporting mouse mode
// (e.g. a plain shell with native scrollback) — callers then leave scrolling to
// the TerminalView's own touch handling. Coordinates are the viewport centre,
// where these TUIs scroll regardless of x/y.
String? terminalWheel(Terminal term, {required bool up}) {
  if (!term.mouseMode.reportScroll) return null;
  final x = term.viewWidth > 1 ? term.viewWidth ~/ 2 : 1;
  final y = term.viewHeight > 1 ? term.viewHeight ~/ 2 : 1;
  return encodeWheel(up ? 64 : 65, x, y, term.mouseReportMode);
}
