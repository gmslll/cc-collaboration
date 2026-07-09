import 'package:app/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<String?> values(List<PopupMenuEntry<String>> entries) => [
    for (final e in entries)
      if (e is PopupMenuItem<String>) e.value,
  ];

  String? textOf(Widget? widget) {
    if (widget == null) return null;
    if (widget is Text) return widget.data;
    if (widget is Expanded) return textOf(widget.child);
    if (widget is Row) {
      for (final child in widget.children) {
        final text = textOf(child);
        if (text != null) return text;
      }
    }
    return null;
  }

  List<String> labels(List<PopupMenuEntry<String>> entries) => [
    for (final e in entries)
      if (e is PopupMenuItem<String>) textOf(e.child) ?? '',
  ];

  SendTarget target(int i) => (id: 'ts$i', label: 'session $i');

  test('short same-project send targets stay inline', () {
    final entries = sendMenuEntries([target(1), target(2)], const []);

    expect(values(entries), ['send:ts1', 'send:ts2']);
  });

  test('long same-project send targets collapse behind one submenu row', () {
    final same = [for (var i = 0; i < 3; i++) target(i)];
    final entries = sendMenuEntries(same, const []);

    expect(values(entries), ['send-same']);
    expect(labels(entries), ['当前项目会话 (3) ▸']);
    expect(labels(entries), isNot(contains('发送到「session 0」')));
  });

  test('other-project send targets collapse behind their own submenu row', () {
    final entries = sendMenuEntries([target(1)], [target(2), target(3)]);

    expect(values(entries), ['send:ts1', 'send-others']);
    expect(labels(entries), ['发送到「session 1」', '其他会话 (2) ▸']);
  });

  test('short peer picker targets stay selectable directly', () {
    final entries = peerPickerMenuEntries([target(1), target(2)], 'send');

    expect(values(entries), ['send:ts1', 'send:ts2']);
    expect(labels(entries), ['发送到「session 1」', '发送到「session 2」']);
  });

  test('long peer picker targets collapse into range rows', () {
    final entries = peerPickerMenuEntries([
      for (var i = 1; i <= 25; i++) target(i),
    ], 'send');

    expect(values(entries), ['send-page:0', 'send-page:12', 'send-page:24']);
    expect(labels(entries), ['会话 1-12 ▸', '会话 13-24 ▸', '会话 25 ▸']);
  });

  test('peer picker rejects invalid inline limits without looping', () {
    final entries = peerPickerMenuEntries(
      [for (var i = 1; i <= 13; i++) target(i)],
      'send',
      inlineLimit: 0,
    );

    expect(values(entries), ['send-page:0', 'send-page:12']);
  });

  test('interject targets use the same grouped peer menu shape', () {
    final same = [for (var i = 0; i < 3; i++) target(i)];
    final others = [target(4), target(5)];
    final entries = groupedPeerMenuEntries(
      same,
      others,
      prefix: 'interject',
      icon: Icons.bolt_rounded,
      label: (t) => '插话到「${t.label}」',
    );

    expect(values(entries), ['interject-same', 'interject-others']);
  });
}
