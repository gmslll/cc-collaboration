import 'package:app/ghostty_shadow.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats plain and VT snapshots from mirrored output', () {
    final shadow = GhosttyShadowTerminal.create(cols: 20, rows: 5);
    expect(shadow, isNotNull);
    addTearDown(shadow!.dispose);

    shadow.writeString('one\r\n');
    shadow.writeString('\x1b[31mtwo\x1b[0m\r\n');
    shadow.writeString('three');

    expect(shadow.plainText(), contains('one'));
    expect(shadow.plainText(), contains('two'));
    expect(shadow.vtText(), contains('\x1b['));
    expect(shadow.htmlText(), contains('two'));
    expect(shadow.vtTail(1), contains('three'));
    expect(shadow.vtTailSelection(1), contains('three'));
  });

  test('plain formatter includes scrollback history', () {
    final shadow = GhosttyShadowTerminal.create(cols: 20, rows: 2);
    expect(shadow, isNotNull);
    addTearDown(shadow!.dispose);

    shadow.writeString('one\r\ntwo\r\nthree\r\n');

    expect(shadow.plainText(), contains('one'));
    expect(shadow.plainText(), contains('three'));
  });

  test('VT tail selection formats the requested terminal rows', () {
    final shadow = GhosttyShadowTerminal.create(cols: 20, rows: 2);
    expect(shadow, isNotNull);
    addTearDown(shadow!.dispose);

    shadow.writeString('\x1b[31mone\x1b[0m\r\n');
    shadow.writeString('two\r\n');
    shadow.writeString('\x1b[32mthree\x1b[0m\r\n');

    final tail = shadow.vtTailSelection(1);
    expect(tail, contains('three'));
    expect(tail, contains('\x1b['));
    expect(tail, isNot(contains('one')));
  });

  test('explicit VT selection formats the requested coordinates', () {
    final shadow = GhosttyShadowTerminal.create(cols: 20, rows: 3);
    expect(shadow, isNotNull);
    addTearDown(shadow!.dispose);

    shadow.writeString('\x1b[31mred\x1b[0m\r\n');
    shadow.writeString('\x1b[32mgreen\x1b[0m\r\n');
    shadow.writeString('plain\r\n');

    final vt = shadow.vtSelection(
      startRow: 1,
      startCol: 0,
      endRow: 1,
      endCol: 19,
    );
    final plain = shadow.plainSelection(
      startRow: 1,
      startCol: 0,
      endRow: 1,
      endCol: 19,
    );

    expect(vt, contains('green'));
    expect(vt, contains('\x1b['));
    expect(vt, isNot(contains('red')));
    expect(plain, contains('green'));
    expect(plain, isNot(contains('\x1b[')));
  });

  test('HTML formatter and digest are available from mirrored output', () {
    final shadow = GhosttyShadowTerminal.create(cols: 20, rows: 3);
    expect(shadow, isNotNull);
    addTearDown(shadow!.dispose);

    shadow.writeString('\x1b[31mred\x1b[0m\r\nplain');

    final html = shadow.htmlSelection(
      startRow: 0,
      startCol: 0,
      endRow: 1,
      endCol: 19,
    );
    final digest = shadow.digest(sampleRows: 2);

    expect(html, contains('red'));
    expect(digest, isNotNull);
    expect(digest!.cols, 20);
    expect(digest.tailLength, greaterThan(0));
  });
}
