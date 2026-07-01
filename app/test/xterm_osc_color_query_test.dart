import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('OSC 10 and 11 color queries report configured defaults', () {
    final output = StringBuffer();
    final term = Terminal(
      maxLines: 1000,
      defaultForegroundColor: 0xe6eaf2,
      defaultBackgroundColor: 0x0a0e1a,
      onOutput: output.write,
    );

    term.write('\x1b]10;?\x1b\\');
    term.write('\x1b]11;?\x1b\\');

    expect(output.toString(), contains('\x1b]10;rgb:e6e6/eaea/f2f2\x1b\\'));
    expect(output.toString(), contains('\x1b]11;rgb:0a0a/0e0e/1a1a\x1b\\'));
  });

  test(
    'OSC 10 and 11 color queries are ignored without configured defaults',
    () {
      final output = StringBuffer();
      final term = Terminal(maxLines: 1000, onOutput: output.write);

      term.write('\x1b]10;?\x1b\\');
      term.write('\x1b]11;?\x1b\\');

      expect(output.toString(), isEmpty);
    },
  );

  test('OSC 10 and 11 color queries accept BEL terminators', () {
    final output = StringBuffer();
    final term = Terminal(
      maxLines: 1000,
      defaultForegroundColor: 0xffffff,
      defaultBackgroundColor: 0x000000,
      onOutput: output.write,
    );

    term.write('\x1b]10;?\x07');
    term.write('\x1b]11;?\x07');

    expect(output.toString(), contains('\x1b]10;rgb:ffff/ffff/ffff\x1b\\'));
    expect(output.toString(), contains('\x1b]11;rgb:0000/0000/0000\x1b\\'));
  });

  test('non-query OSC 10 and 11 sequences remain private OSCs', () {
    final privateOsc = <(String, List<String>)>[];
    final term = Terminal(
      maxLines: 1000,
      defaultForegroundColor: 0xffffff,
      defaultBackgroundColor: 0x000000,
      onPrivateOSC: (code, args) => privateOsc.add((code, args)),
    );

    term.write('\x1b]10;#ffffff\x1b\\');
    term.write('\x1b]11;#000000\x1b\\');

    expect(privateOsc, hasLength(2));
    expect(privateOsc[0].$1, '10');
    expect(privateOsc[0].$2, ['#ffffff']);
    expect(privateOsc[1].$1, '11');
    expect(privateOsc[1].$2, ['#000000']);
  });
}
