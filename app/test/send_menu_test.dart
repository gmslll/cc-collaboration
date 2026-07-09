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
    if (widget is Tooltip) return textOf(widget.child);
    if (widget is Row) {
      for (final child in widget.children) {
        final text = textOf(child);
        if (text != null) return text;
      }
    }
    return null;
  }

  Text? textWidgetOf(Widget? widget) {
    if (widget == null) return null;
    if (widget is Text) return widget;
    if (widget is Expanded) return textWidgetOf(widget.child);
    if (widget is Tooltip) return textWidgetOf(widget.child);
    if (widget is Row) {
      for (final child in widget.children) {
        final text = textWidgetOf(child);
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

  test('menu item labels clamp instead of stretching long menus', () {
    final label = '发送到「${'very-long-session-name-' * 8}」';
    final item = ccMenuItem(
      value: 'send:long',
      icon: Icons.send_rounded,
      label: label,
    );
    final text = textWidgetOf(item.child);

    expect(text?.maxLines, 1);
    expect(text?.overflow, TextOverflow.ellipsis);
  });

  test('menu item labels keep full text in a tooltip', () {
    const label = '发送到「remote teammate with a very long session label」';
    final item = ccMenuItem(
      value: 'send:long',
      icon: Icons.send_rounded,
      label: label,
    );
    final tooltip = (item.child as Row).children
        .whereType<Expanded>()
        .single
        .child;

    expect(tooltip, isA<Tooltip>());
    expect((tooltip as Tooltip).message, label);
  });

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

  test('grouped send menu rejects invalid inline limits', () {
    final entries = sendMenuEntries(
      [target(1), target(2)],
      const [],
      inlineLimit: 0,
    );

    expect(values(entries), ['send:ts1', 'send:ts2']);
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

  test('project file action menu collapses secondary actions', () {
    final entries = fileActionMenuEntries(
      isDir: false,
      includeVersionControl: true,
    );

    expect(values(entries), [
      'open',
      'newFile',
      'newDir',
      fileMenuEdit,
      fileMenuLocate,
      fileMenuVersion,
      'refresh',
    ]);
    expect(labels(entries), [
      'Open',
      'New File',
      'New Directory',
      'Edit Actions ▸',
      'Locate / Open ▸',
      'Version Control ▸',
      'Reload from Disk',
    ]);
  });

  test('worktree file action menu omits project-only version group', () {
    final entries = fileActionMenuEntries(
      isDir: true,
      includeVersionControl: false,
    );

    expect(values(entries), [
      'open',
      'newFile',
      'newDir',
      fileMenuEdit,
      fileMenuLocate,
      'refresh',
    ]);
    expect(labels(entries), isNot(contains('Version Control ▸')));
  });

  test('file edit submenu disables root-destructive actions', () {
    final entries = fileActionSubmenuEntries(
      fileMenuEdit,
      atRoot: true,
      includeProjectReveal: true,
    );

    expect(values(entries), [null, null, 'copy', null, 'paste']);
  });

  test('file locate submenu only shows project reveal for project files', () {
    final projectEntries = fileActionSubmenuEntries(
      fileMenuLocate,
      atRoot: false,
      includeProjectReveal: true,
    );
    final worktreeEntries = fileActionSubmenuEntries(
      fileMenuLocate,
      atRoot: false,
      includeProjectReveal: false,
    );

    expect(values(projectEntries), contains('revealProject'));
    expect(values(worktreeEntries), isNot(contains('revealProject')));
  });

  test('file locate submenu can omit terminal actions', () {
    final entries = fileActionSubmenuEntries(
      fileMenuLocate,
      atRoot: false,
      includeProjectReveal: false,
      includeTerminal: false,
    );

    expect(values(entries), ['copyPath', 'revealSystem', 'openExternal']);
  });
}
