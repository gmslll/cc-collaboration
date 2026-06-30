import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('ctrl punctuation keys encode as C0 controls', () {
    final term = Terminal();
    final output = StringBuffer();
    term.onOutput = output.write;

    term.keyInput(TerminalKey.bracketLeft, ctrl: true);
    term.keyInput(TerminalKey.backslash, ctrl: true);
    term.keyInput(TerminalKey.bracketRight, ctrl: true);
    term.keyInput(TerminalKey.digit6, ctrl: true);
    term.keyInput(TerminalKey.minus, ctrl: true);

    expect(output.toString(), '\x1b\x1c\x1d\x1e\x1f');
  });

  test('normal mouse reporting uses one-based coordinates exactly once', () {
    final term = Terminal();
    final output = StringBuffer();
    term
      ..onOutput = output.write
      ..setMouseMode(MouseMode.upDownScroll)
      ..setMouseReportMode(MouseReportMode.normal);

    final handled = term.mouseInput(
      TerminalMouseButton.left,
      TerminalMouseButtonState.down,
      const CellOffset(0, 0),
    );

    expect(handled, isTrue);
    expect(output.toString(), '\x1b[M !!');
  });

  test('utf mouse reporting uses one-based coordinates exactly once', () {
    final term = Terminal();
    final output = StringBuffer();
    term
      ..onOutput = output.write
      ..setMouseMode(MouseMode.upDownScroll)
      ..setMouseReportMode(MouseReportMode.utf);

    final handled = term.mouseInput(
      TerminalMouseButton.left,
      TerminalMouseButtonState.down,
      const CellOffset(2, 3),
    );

    expect(handled, isTrue);
    expect(output.toString(), '\x1b[M #\$');
  });
}
