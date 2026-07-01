import 'package:app/terminal_snapshot_formatter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('plain formatter trims trailing blank terminal rows', () {
    final terminal = Terminal(maxLines: 100);
    terminal.resize(10, 4, 10, 20);
    terminal.write('one\r\ntwo');

    final text = XtermSnapshotFormatter(terminal).plain();

    expect(text, 'one\ntwo');
  });

  test('plain formatter includes the last terminal column', () {
    final terminal = Terminal(maxLines: 100);
    terminal.resize(5, 2, 10, 20);
    terminal.write('abcde');

    final text = XtermSnapshotFormatter(terminal).plain();

    expect(text, 'abcde');
  });

  test('ansi formatter emits SGR and resets once', () {
    final terminal = Terminal(maxLines: 100);
    terminal.resize(10, 3, 10, 20);
    final style = CursorStyle(
      foreground: CellColor.named | 1,
      background: CellColor.normal,
    )..setBold();
    terminal.buffer.lines[0]
      ..setCell(0, 'R'.codeUnitAt(0), 1, style)
      ..setCell(1, 'E'.codeUnitAt(0), 1, style)
      ..setCell(2, 'D'.codeUnitAt(0), 1, style);

    final ansi = XtermSnapshotFormatter(terminal).ansi();

    expect(ansi, startsWith('\x1b[0;1;31;49mRED'));
    expect(ansi, endsWith('\x1b[0m'));
  });

  test('ansi tail formats the last non-blank rows only', () {
    final terminal = Terminal(maxLines: 100);
    terminal.resize(10, 4, 10, 20);
    terminal.write('one\r\ntwo\r\nthree');

    final ansi = XtermSnapshotFormatter(terminal).ansiTail(2);

    expect(ansi, contains('two\r\n'));
    expect(ansi, contains('three'));
    expect(ansi, isNot(contains('one')));
  });

  test('range formatter keeps wrapped rows joined', () {
    final terminal = Terminal(maxLines: 100);
    terminal.resize(5, 3, 10, 20);
    terminal.write('abcde');
    terminal.write('fgh');

    final text = XtermSnapshotFormatter(terminal).plain();
    final ansi = XtermSnapshotFormatter(terminal).ansi();

    expect(text, 'abcdefgh');
    expect(ansi, contains('abcdefgh'));
    expect(ansi, isNot(contains('abcde\r\nfgh')));
  });

  test('explicit selection range formats only requested cells', () {
    final terminal = Terminal(maxLines: 100);
    terminal.resize(12, 3, 10, 20);
    terminal.write('alpha\r\nbeta\r\ngamma');
    final range = BufferRangeLine(
      const CellOffset(1, 1),
      const CellOffset(3, 1),
    );

    final plain = XtermSnapshotFormatter(
      terminal,
    ).plain(range: range, trimTrailingBlankLines: false);
    final ansi = XtermSnapshotFormatter(terminal).ansi(range: range);

    expect(plain, 'et');
    expect(ansi, contains('et'));
    expect(ansi, isNot(contains('b')));
  });

  test('block selection range formats each selected row slice', () {
    final terminal = Terminal(maxLines: 100);
    terminal.resize(12, 3, 10, 20);
    terminal.write('abcde\r\nABCDE');
    final range = BufferRangeBlock(
      const CellOffset(1, 0),
      const CellOffset(4, 1),
    );

    final plain = XtermSnapshotFormatter(
      terminal,
    ).plain(range: range, trimTrailingBlankLines: false);

    expect(plain, 'bcd\nBCD');
  });
}
