import 'package:app/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<String?> values(List<PopupMenuEntry<String>> entries) => [
    for (final e in entries)
      if (e is PopupMenuItem<String>) e.value,
  ];

  SendTarget target(int i) => (id: 'ts$i', label: 'session $i');

  test('short same-project send targets stay inline', () {
    final entries = sendMenuEntries([
      target(1),
      target(2),
      target(3),
    ], const []);

    expect(values(entries), ['send:ts1', 'send:ts2', 'send:ts3']);
  });

  test('long same-project send targets collapse behind one submenu row', () {
    final same = [for (var i = 0; i < 4; i++) target(i)];
    final entries = sendMenuEntries(same, const []);

    expect(values(entries), ['send-same']);
  });

  test('other-project send targets collapse behind their own submenu row', () {
    final entries = sendMenuEntries([target(1)], [target(2), target(3)]);

    expect(values(entries), ['send:ts1', 'send-others']);
  });
}
