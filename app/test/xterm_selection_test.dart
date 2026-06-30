import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('main scrollback position survives alt-buffer round trip', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    for (var i = 0; i < 80; i++) {
      term.write('line $i\r\n');
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 260,
            child: TerminalView(term, scrollController: scrollController),
          ),
        ),
      ),
    );
    await tester.pump();

    final before = scrollController.position.maxScrollExtent / 2;
    scrollController.jumpTo(before);
    await tester.pump();

    term.write('\x1b[?1049h');
    await tester.pump();
    term.write('\x1b[?1049l');
    await tester.pump();

    expect(scrollController.offset, before);
  });

  testWidgets('mouse drag can select into right-side empty space', (
    tester,
  ) async {
    final (:term, :controller, :box, :origin) = await _pumpTerminal(tester);
    final start = origin + const Offset(2, 6);
    final end = origin + Offset(box.size.width - 4, 6);

    await _drag(tester, start, end);

    final selection = controller.selection;
    expect(selection, isNotNull);
    expect(term.buffer.getText(selection!), contains('selectable text'));
  });

  testWidgets('mouse drag can select backwards from right-side empty space', (
    tester,
  ) async {
    final (:term, :controller, :box, :origin) = await _pumpTerminal(tester);
    final start = origin + Offset(box.size.width - 4, 6);
    final end = origin + const Offset(2, 6);

    await _drag(tester, start, end);

    final selection = controller.selection;
    expect(selection, isNotNull);
    expect(term.buffer.getText(selection!), contains('selectable text'));
  });

  testWidgets('mouse drag can extend below the visible terminal', (
    tester,
  ) async {
    final (:term, :controller, :box, :origin) = await _pumpTerminal(tester);
    final start = origin + const Offset(2, 6);
    final end = origin + Offset(box.size.width - 4, box.size.height + 40);

    await _drag(tester, start, end);

    final selection = controller.selection;
    expect(selection, isNotNull);
    final selected = term.buffer.getText(selection!);
    expect(selected, contains('selectable text'));
    expect(selected, contains('next line'));
  });
}

Future<
  ({Terminal term, TerminalController controller, RenderBox box, Offset origin})
>
_pumpTerminal(WidgetTester tester) async {
  final term = Terminal(maxLines: 1000);
  final controller = TerminalController(
    pointerInputs: const PointerInputs.none(),
  );
  term.write('selectable text\r\nnext line');

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 500,
          height: 260,
          child: TerminalView(term, controller: controller),
        ),
      ),
    ),
  );
  await tester.pump();

  final box = tester.renderObject<RenderBox>(find.byType(TerminalView));
  return (
    term: term,
    controller: controller,
    box: box,
    origin: box.localToGlobal(Offset.zero),
  );
}

Future<void> _drag(WidgetTester tester, Offset start, Offset end) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.down(start);
  await tester.pump();
  await gesture.moveTo(end);
  await tester.pump();
  await gesture.up();
  await tester.pump();
}
