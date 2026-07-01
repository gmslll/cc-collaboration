import 'package:app/ghostty_input.dart';
import 'package:app/ghostty_runtime.dart';
import 'package:app/ghostty_sequences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' as ghostty;
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('runtime initializes as native no-op under VM tests', () async {
    expect(await GhosttyRuntime.ensureInitialized(), isTrue);
  });

  test('typed OSC parser recognizes title commands', () {
    final command = GhosttySequenceTools.parseOsc('0;hello');

    expect(command, isNotNull);
    expect(command!.type, ghostty.OscCommandType.changeWindowTitle);
    expect(command.windowTitle, 'hello');
  });

  test('typed SGR parser recognizes bold and foreground color', () {
    final attrs = GhosttySequenceTools.parseSgr([1, 31]);

    expect(attrs.map((a) => a.tag), contains(ghostty.SgrAttributeTag.bold));
    expect(attrs.map((a) => a.tag), contains(ghostty.SgrAttributeTag.fg8));
  });

  test('key encoder maps Flutter key events through Ghostty', () {
    final encoder = GhosttyInputEncoder();
    addTearDown(encoder.dispose);

    final enter = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.enter,
      logicalKey: LogicalKeyboardKey.enter,
      timeStamp: Duration.zero,
    );
    final arrowUp = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.arrowUp,
      logicalKey: LogicalKeyboardKey.arrowUp,
      timeStamp: Duration.zero,
    );
    final repeatArrowUp = KeyRepeatEvent(
      physicalKey: PhysicalKeyboardKey.arrowUp,
      logicalKey: LogicalKeyboardKey.arrowUp,
      timeStamp: Duration.zero,
    );
    final releaseArrowUp = KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.arrowUp,
      logicalKey: LogicalKeyboardKey.arrowUp,
      timeStamp: Duration.zero,
    );

    expect(encoder.encodeKeyEvent(enter), '\r');
    expect(encoder.encodeKeyEvent(arrowUp), '\x1b[A');
    expect(encoder.encodeKeyEvent(repeatArrowUp), '\x1b[A');
    expect(encoder.encodeKeyEvent(releaseArrowUp), isEmpty);
  });

  test('mouse encoder maps xterm cell clicks through Ghostty', () {
    final encoded = encodeGhosttyMouseCell(
      x: 3,
      y: 4,
      reportMode: MouseReportMode.sgr,
      mouseMode: MouseMode.clickOnly,
      button: TerminalMouseButton.left,
      state: TerminalMouseButtonState.down,
    );

    expect(encoded, startsWith('\x1b[<'));
    expect(encoded, endsWith('M'));
  });
}
