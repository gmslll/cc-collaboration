import 'dart:io';

import 'package:app/widgets/todo_property_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// GroupControl is the "输入即创建" (type-to-create) 分组 picker — there's no
// dedicated "create a group" endpoint (see pkg/todoschema.Todo.GroupName's
// field docs), so the important behavior to lock in here is: picking an
// existing name and typing a brand-new one both funnel through the same
// onSelect callback, and the clear icon bypasses the picker entirely.
void main() {
  const longGroupName = '团队协作跨项目超长分组名称-用于验证任务详情属性控件不会撑开布局';

  Widget harness({
    String? groupName,
    List<String> existingGroups = const [],
    required ValueChanged<String> onSelect,
    VoidCallback? onClear,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: GroupControl(
          groupName: groupName,
          existingGroups: existingGroups,
          onSelect: onSelect,
          onClear: onClear,
        ),
      ),
    );
  }

  testWidgets('shows 未分组 when ungrouped', (tester) async {
    await tester.pumpWidget(harness(groupName: null, onSelect: (_) {}));
    expect(find.text('未分组'), findsOneWidget);
  });

  testWidgets('shows the current group name when set', (tester) async {
    await tester.pumpWidget(harness(groupName: '我的日常', onSelect: (_) {}));
    expect(find.text('我的日常'), findsOneWidget);
  });

  testWidgets('current and picker group labels are width constrained', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(groupName: longGroupName, onSelect: (_) {}),
    );

    final currentLabel = tester.widget<Text>(find.text(longGroupName));
    expect(currentLabel.maxLines, 1);
    expect(currentLabel.overflow, TextOverflow.ellipsis);

    await tester.pumpWidget(
      harness(
        groupName: null,
        existingGroups: const [longGroupName],
        onSelect: (_) {},
      ),
    );
    await tester.tap(find.text('未分组'));
    await tester.pumpAndSettle();

    final pickerLabel = tester.widget<Text>(find.text(longGroupName));
    expect(pickerLabel.maxLines, 1);
    expect(pickerLabel.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  test('group picker list height is responsive', () {
    expect(groupPickerListMaxHeight(const Size(1024, 720)), 180);
    expect(
      groupPickerListMaxHeight(const Size(320, 420)),
      closeTo(142.8, 0.001),
    );
    expect(groupPickerListMaxHeight(const Size(320, 240)), 96);
  });

  test('group picker avoids fixed list height', () {
    final source = File(
      'lib/widgets/todo_property_controls.dart',
    ).readAsStringSync();
    final picker = source.substring(source.indexOf('class _GroupPickerDialog'));

    expect(picker, contains('groupPickerListMaxHeight'));
    expect(picker, isNot(contains('BoxConstraints(maxHeight: 180)')));
  });

  testWidgets('picking an existing group from the list calls onSelect', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      harness(
        groupName: null,
        existingGroups: const ['我的日常', 'xxx项目'],
        onSelect: (v) => selected = v,
      ),
    );

    await tester.tap(find.text('未分组'));
    await tester.pumpAndSettle();

    // Both existing groups are offered.
    expect(find.text('我的日常'), findsOneWidget);
    expect(find.text('xxx项目'), findsOneWidget);

    await tester.tap(find.text('xxx项目'));
    await tester.pumpAndSettle();

    expect(selected, 'xxx项目');
  });

  testWidgets('typing a new name and confirming creates it', (tester) async {
    String? selected;
    await tester.pumpWidget(
      harness(
        groupName: null,
        existingGroups: const ['我的日常'],
        onSelect: (v) => selected = v,
      ),
    );

    await tester.tap(find.text('未分组'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '新项目');
    await tester.pump();

    expect(find.text('将创建新分组 "新项目"'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(selected, '新项目');
  });

  testWidgets('tapping the clear icon calls onClear without picking', (
    tester,
  ) async {
    var cleared = false;
    String? selected;
    await tester.pumpWidget(
      harness(
        groupName: 'temp',
        onSelect: (v) => selected = v,
        onClear: () => cleared = true,
      ),
    );

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();

    expect(cleared, isTrue);
    expect(selected, isNull);
  });
}
