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
}
