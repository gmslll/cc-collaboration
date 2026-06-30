import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/render.dart';
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

  testWidgets('selection paints after outer layout offset', (tester) async {
    final term = Terminal(maxLines: 1000);
    final controller = TerminalController(
      pointerInputs: const PointerInputs.none(),
    );
    term.write('offset selectable text\r\nnext line');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.only(left: 37, top: 53),
            child: SizedBox(
              width: 500,
              height: 260,
              child: TerminalView(term, controller: controller),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final box = tester.renderObject<RenderBox>(find.byType(TerminalView));
    final origin = box.localToGlobal(Offset.zero);
    await _drag(
      tester,
      origin + const Offset(2, 6),
      origin + Offset(box.size.width - 4, 6),
    );

    expect(tester.takeException(), isNull);
    final selection = controller.selection;
    expect(selection, isNotNull);
    expect(term.buffer.getText(selection!), contains('offset selectable text'));
  });

  testWidgets('mouse drag snaps wide character tail to full cell range', (
    tester,
  ) async {
    final (:term, :controller, :render) = await _pumpWideTerminal(tester);
    final cellWidth = render.cellSize.width;
    final rowMid = render.cellSize.height / 2;
    final wideTail =
        render.getOffset(const CellOffset(1, 0)) +
        Offset(cellWidth / 2, rowMid);
    final wideTailEnd =
        render.getOffset(const CellOffset(1, 0)) +
        Offset(cellWidth * 0.75, rowMid);

    await _drag(tester, wideTail, wideTailEnd);

    final selection = controller.selection;
    expect(selection, isNotNull);
    expect(term.buffer.getText(selection!), '界');
  });

  testWidgets('backward mouse drag keeps the starting cell selected', (
    tester,
  ) async {
    final (:term, :controller, :render) = await _pumpWideTerminal(
      tester,
      text: '界a',
    );
    final cellWidth = render.cellSize.width;
    final rowMid = render.cellSize.height / 2;
    final asciiCell =
        render.getOffset(const CellOffset(2, 0)) +
        Offset(cellWidth / 2, rowMid);
    final wideTail =
        render.getOffset(const CellOffset(1, 0)) +
        Offset(cellWidth / 2, rowMid);

    await _drag(tester, asciiCell, wideTail);

    final selection = controller.selection;
    expect(selection, isNotNull);
    expect(term.buffer.getText(selection!), '界a');
  });

  testWidgets('double click word selection snaps wide character tail to head', (
    tester,
  ) async {
    final (:term, :controller, :render) = await _pumpWideTerminal(tester);
    final cellWidth = render.cellSize.width;
    final rowMid = render.cellSize.height / 2;
    final wideTail =
        render.getOffset(const CellOffset(1, 0)) +
        Offset(cellWidth / 2, rowMid);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(wideTail);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.down(wideTail);
    await gesture.up();
    await tester.pump();

    final selection = controller.selection;
    expect(selection, isNotNull);
    expect(term.buffer.getText(selection!), '界a');
  });

  testWidgets('word selection crosses adjacent wide character tails', (
    tester,
  ) async {
    final (:term, :controller, :render) = await _pumpWideTerminal(
      tester,
      text: '界世a',
    );
    final cellWidth = render.cellSize.width;
    final rowMid = render.cellSize.height / 2;
    final secondWideTail =
        render.getOffset(const CellOffset(3, 0)) +
        Offset(cellWidth / 2, rowMid);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(secondWideTail);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.down(secondWideTail);
    await gesture.up();
    await tester.pump();

    final selection = controller.selection;
    expect(selection, isNotNull);
    expect(term.buffer.getText(selection!), '界世a');
  });

  testWidgets('alt mouse drag creates block selection', (tester) async {
    final (:term, :controller, :render) = await _pumpWideTerminal(
      tester,
      text: 'abcde\r\nABCDE',
    );
    final cellWidth = render.cellSize.width;
    final rowMid = render.cellSize.height / 2;
    final start =
        render.getOffset(const CellOffset(1, 0)) +
        Offset(cellWidth / 2, rowMid);
    final end =
        render.getOffset(const CellOffset(3, 1)) +
        Offset(cellWidth / 2, rowMid);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await _drag(tester, start, end);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

    final selection = controller.selection;
    expect(selection, isA<BufferRangeBlock>());
    expect(term.buffer.getText(selection!), 'bcd\nBCD');
  });

  testWidgets('reverse alt mouse drag keeps block start cell selected', (
    tester,
  ) async {
    final (:term, :controller, :render) = await _pumpWideTerminal(
      tester,
      text: 'abcde\r\nABCDE',
    );
    final cellWidth = render.cellSize.width;
    final rowMid = render.cellSize.height / 2;
    final start =
        render.getOffset(const CellOffset(3, 1)) +
        Offset(cellWidth / 2, rowMid);
    final end =
        render.getOffset(const CellOffset(1, 0)) +
        Offset(cellWidth / 2, rowMid);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await _drag(tester, start, end);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

    final selection = controller.selection;
    expect(selection, isA<BufferRangeBlock>());
    expect(term.buffer.getText(selection!), 'bcd\nBCD');
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

Future<({Terminal term, TerminalController controller, RenderTerminal render})>
_pumpWideTerminal(WidgetTester tester, {String text = '界a'}) async {
  final term = Terminal(maxLines: 1000);
  final controller = TerminalController(
    pointerInputs: const PointerInputs.none(),
  );
  term.write(text);

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

  final render = tester.renderObject<RenderTerminal>(
    find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_TerminalView',
    ),
  );
  return (term: term, controller: controller, render: render);
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
