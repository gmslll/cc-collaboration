import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('offset-backed selection prunes when rows leave the buffer', () {
    final controller = TerminalController(
      pointerInputs: const PointerInputs.none(),
    );
    controller.setSelectionOffsets(
      const CellOffset(0, 10),
      const CellOffset(4, 10),
    );

    expect(controller.selection, isNotNull);

    controller.pruneSelectionOffsets(5);

    expect(controller.selection, isNull);
  });

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

  testWidgets('touch long press drag extends by cells past blank areas', (
    tester,
  ) async {
    final (:term, :controller, :box, :origin) = await _pumpTerminal(tester);
    final start = origin + const Offset(2, 6);
    final end = origin + Offset(box.size.width - 4, 28);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(start);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final selection = controller.selection;
    expect(selection, isNotNull);
    final selected = term.buffer.getText(selection!);
    expect(selected, contains('selectable text'));
    expect(selected, contains('next line'));
  });

  testWidgets('touch long press can start from empty cells', (tester) async {
    final (:term, :controller, :box, :origin) = await _pumpTerminal(tester);
    final start = origin + Offset(box.size.width - 4, 6);
    final end = origin + Offset(box.size.width - 4, 28);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(start);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final selection = controller.selection;
    expect(selection, isNotNull);
    expect(term.buffer.getText(selection!), contains('next line'));
  });

  testWidgets('touch long press can start near bottom empty cells', (
    tester,
  ) async {
    final (:term, :controller, :box, :origin) = await _pumpTerminal(tester);
    final start = origin + Offset(box.size.width - 4, 28);
    final end = origin + const Offset(2, 6);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(start);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final selection = controller.selection;
    expect(selection, isNotNull);
    final selected = term.buffer.getText(selection!);
    expect(selected, contains('selectable text'));
    expect(selected, contains('next line'));
  });

  testWidgets('mouse drag selection autoscrolls beyond viewport', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    final controller = TerminalController(
      pointerInputs: const PointerInputs.none(),
    );
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    for (var i = 0; i < 40; i++) {
      term.write('line $i selectable\r\n');
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 80,
            child: TerminalView(
              term,
              controller: controller,
              scrollController: scrollController,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    scrollController.jumpTo(0);
    await tester.pump();

    final box = tester.renderObject<RenderBox>(find.byType(TerminalView));
    final origin = box.localToGlobal(Offset.zero);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(origin + const Offset(2, 6));
    await tester.pump();
    await gesture.moveTo(
      origin + Offset(box.size.width - 4, box.size.height + 30),
    );
    await tester.pump(const Duration(milliseconds: 220));
    await gesture.up();
    await tester.pump();

    expect(scrollController.offset, greaterThan(0));
    final selection = controller.selection;
    expect(selection, isNotNull);
    final selected = term.buffer.getText(selection!);
    expect(selected, contains('line 0 selectable'));
    expect(selected, contains('line 4 selectable'));
  });

  testWidgets('touch long press selection autoscrolls beyond viewport', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    final controller = TerminalController(
      pointerInputs: const PointerInputs.none(),
    );
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    for (var i = 0; i < 40; i++) {
      term.write('touch line $i selectable\r\n');
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 80,
            child: TerminalView(
              term,
              controller: controller,
              scrollController: scrollController,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    scrollController.jumpTo(0);
    await tester.pump();

    final box = tester.renderObject<RenderBox>(find.byType(TerminalView));
    final origin = box.localToGlobal(Offset.zero);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(origin + const Offset(2, 6));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await gesture.moveTo(
      origin + Offset(box.size.width - 4, box.size.height + 30),
    );
    await tester.pump(const Duration(milliseconds: 220));
    await gesture.up();
    await tester.pump();

    expect(scrollController.offset, greaterThan(0));
    final selection = controller.selection;
    expect(selection, isNotNull);
    final selected = term.buffer.getText(selection!);
    expect(selected, contains('touch line 0 selectable'));
    expect(selected, contains('touch line 4 selectable'));
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

  testWidgets('triple click selects the full visual line', (tester) async {
    final (:term, :controller, :box, :origin) = await _pumpTerminal(tester);
    final pos = origin + const Offset(20, 6);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 3; i++) {
      await gesture.down(pos);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump();

    final selection = controller.selection;
    expect(selection, isNotNull);
    final selected = term.buffer.getText(selection!);
    expect(selected, contains('selectable text'));
    expect(selected, isNot(contains('next line')));
    expect(box.size.width, greaterThan(0));
  });

  testWidgets('triple click on right-side empty space selects the line', (
    tester,
  ) async {
    final (:term, :controller, :box, :origin) = await _pumpTerminal(tester);
    final pos = origin + Offset(box.size.width - 4, 6);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 3; i++) {
      await gesture.down(pos);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump();

    final selection = controller.selection;
    expect(selection, isNotNull);
    final selected = term.buffer.getText(selection!);
    expect(selected, contains('selectable text'));
    expect(selected, isNot(contains('next line')));
  });

  testWidgets('separate taps outside double-tap slop do not leak timers', (
    tester,
  ) async {
    final (:controller, :origin, :box, :term) = await _pumpTerminal(tester);
    final first = origin + const Offset(2, 6);
    final second = origin + Offset(box.size.width - 4, 6);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(first);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.down(second);
    await gesture.up();
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));

    expect(controller.selection, isNull);
    expect(term.buffer.getText(), contains('selectable text'));
  });

  testWidgets('selection autoscroll stops when mouse drag is cancelled', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    final controller = TerminalController(
      pointerInputs: const PointerInputs.none(),
    );
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    for (var i = 0; i < 40; i++) {
      term.write('cancel line $i selectable\r\n');
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 80,
            child: TerminalView(
              term,
              controller: controller,
              scrollController: scrollController,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    scrollController.jumpTo(0);
    await tester.pump();

    final box = tester.renderObject<RenderBox>(find.byType(TerminalView));
    final origin = box.localToGlobal(Offset.zero);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(origin + const Offset(2, 6));
    await tester.pump();
    await gesture.moveTo(
      origin + Offset(box.size.width - 4, box.size.height + 30),
    );
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.cancel();
    await tester.pump(const Duration(milliseconds: 120));

    expect(scrollController.offset, greaterThan(0));
    expect(controller.selection, isNotNull);
  });

  testWidgets('mouse tracking routes secondary click to terminal', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    final controller = TerminalController(
      pointerInputs: const PointerInputs.all(),
    );
    term.write('selectable text');
    term.setMouseMode(MouseMode.upDownScroll);
    final output = StringBuffer();
    var openedMenu = false;
    term.onOutput = output.write;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 260,
            child: TerminalView(
              term,
              controller: controller,
              onSecondaryTapDown: (_, _) => openedMenu = true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final box = tester.renderObject<RenderBox>(find.byType(TerminalView));
    final origin = box.localToGlobal(Offset.zero);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.down(
        origin + const Offset(20, 6),
        buttons: kSecondaryMouseButton,
      ),
    );
    await tester.sendEventToBinding(pointer.up());
    await tester.pump();

    expect(openedMenu, isFalse);
    expect(output.toString(), isNotEmpty);
    expect(controller.selection, isNull);
  });

  testWidgets('mouse tracking routes primary click down and up', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    final controller = TerminalController(
      pointerInputs: const PointerInputs.all(),
    );
    term.write('selectable text');
    term.setMouseMode(MouseMode.upDownScroll);
    term.setMouseReportMode(MouseReportMode.sgr);
    final output = StringBuffer();
    term.onOutput = output.write;

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
    final origin = box.localToGlobal(Offset.zero);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(origin + const Offset(20, 6));
    await gesture.up();
    await tester.pump();

    final text = output.toString();
    expect(text, contains('\x1b[<0;'));
    expect(text, contains('M'));
    expect(text, contains('m'));
  });

  testWidgets('shift secondary click bypasses mouse tracking to GUI menu', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    final controller = TerminalController(
      pointerInputs: const PointerInputs.all(),
    );
    term.write('selectable text');
    term.setMouseMode(MouseMode.upDownScroll);
    final output = StringBuffer();
    var openedMenu = false;
    term.onOutput = output.write;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 260,
            child: TerminalView(
              term,
              controller: controller,
              onSecondaryTapDown: (_, _) => openedMenu = true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final box = tester.renderObject<RenderBox>(find.byType(TerminalView));
    final origin = box.localToGlobal(Offset.zero);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendEventToBinding(
      pointer.down(
        origin + const Offset(20, 6),
        buttons: kSecondaryMouseButton,
      ),
    );
    await tester.sendEventToBinding(pointer.up());
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(openedMenu, isTrue);
    expect(output.toString(), isEmpty);
  });

  testWidgets('pointer input none keeps secondary click as GUI menu', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    final controller = TerminalController(
      pointerInputs: const PointerInputs.none(),
    );
    term.write('selectable text');
    term.setMouseMode(MouseMode.upDownScroll);
    final output = StringBuffer();
    var openedMenu = false;
    term.onOutput = output.write;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 260,
            child: TerminalView(
              term,
              controller: controller,
              onSecondaryTapDown: (_, _) => openedMenu = true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final box = tester.renderObject<RenderBox>(find.byType(TerminalView));
    final origin = box.localToGlobal(Offset.zero);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.down(
        origin + const Offset(20, 6),
        buttons: kSecondaryMouseButton,
      ),
    );
    await tester.sendEventToBinding(pointer.up());
    await tester.pump();

    expect(openedMenu, isTrue);
    expect(output.toString(), isEmpty);
  });

  testWidgets('mouse tracking routes tertiary click as middle button', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    final controller = TerminalController(
      pointerInputs: const PointerInputs.all(),
    );
    term.write('selectable text');
    term.setMouseMode(MouseMode.upDownScroll);
    term.setMouseReportMode(MouseReportMode.sgr);
    final output = StringBuffer();
    term.onOutput = output.write;

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
    final origin = box.localToGlobal(Offset.zero);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.down(origin + const Offset(20, 6), buttons: kMiddleMouseButton),
    );
    await tester.sendEventToBinding(pointer.up());
    await tester.pump();

    final text = output.toString();
    expect(text, contains('\x1b[<1;'));
    expect(text, isNot(contains('\x1b[<2;')));
  });

  testWidgets('shift bypasses mouse tracking for local selection', (
    tester,
  ) async {
    final (:term, :controller, :box, :origin) = await _pumpTerminal(
      tester,
      pointerInputs: const PointerInputs.all(),
    );
    term.setMouseMode(MouseMode.upDownScroll);
    final output = StringBuffer();
    term.onOutput = output.write;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await _drag(
      tester,
      origin + const Offset(2, 6),
      origin + Offset(box.size.width - 4, 6),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    final selection = controller.selection;
    expect(selection, isNotNull);
    expect(term.buffer.getText(selection!), contains('selectable text'));
    expect(output.toString(), isEmpty);
  });

  testWidgets(
    'pointer input none keeps current screen selectable in mouse mode',
    (tester) async {
      final term = Terminal(maxLines: 1000);
      final controller = TerminalController(
        pointerInputs: const PointerInputs.none(),
      );
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      for (var i = 0; i < 80; i++) {
        term.write('current screen selectable line $i\r\n');
      }
      term.setMouseMode(MouseMode.upDownScroll);
      term.setMouseReportMode(MouseReportMode.sgr);
      final output = StringBuffer();
      term.onOutput = output.write;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 120,
              child: TerminalView(
                term,
                controller: controller,
                scrollController: scrollController,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      await tester.pump();

      final box = tester.renderObject<RenderBox>(find.byType(TerminalView));
      final origin = box.localToGlobal(Offset.zero);
      await _drag(
        tester,
        origin + const Offset(2, 6),
        origin + Offset(box.size.width - 4, 6),
      );

      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(term.buffer.getText(selection!), contains('current screen'));
      expect(output.toString(), isEmpty);
    },
  );

  testWidgets('bottom viewport can select visible scrollback rows near top', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    final controller = TerminalController(
      pointerInputs: const PointerInputs.none(),
    );
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    for (var i = 0; i < 80; i++) {
      term.write('history row $i selectable content\r\n');
    }
    term.setMouseMode(MouseMode.upDownScroll);
    term.setMouseReportMode(MouseReportMode.sgr);
    final output = StringBuffer();
    term.onOutput = output.write;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 160,
            child: TerminalView(
              term,
              controller: controller,
              scrollController: scrollController,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();

    final box = tester.renderObject<RenderBox>(find.byType(TerminalView));
    final origin = box.localToGlobal(Offset.zero);
    await _drag(
      tester,
      origin + const Offset(2, 10),
      origin + const Offset(360, 10),
    );

    final selection = controller.selection;
    expect(selection, isNotNull);
    final selected = term.buffer.getText(selection!);
    expect(selected, contains('history row'));
    expect(selected, contains('selectable'));
    expect(selected, isNot(contains('history row 79')));
    expect(output.toString(), isEmpty);
  });

  testWidgets('mouse drag selection wins over draggable scroll behavior', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    final controller = TerminalController(
      pointerInputs: const PointerInputs.none(),
    );
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    for (var i = 0; i < 80; i++) {
      term.write('scroll arena row $i selectable content\r\n');
    }
    term.setMouseMode(MouseMode.upDownScroll);
    final output = StringBuffer();
    term.onOutput = output.write;

    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const _MouseDragScrollBehavior(),
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 160,
            child: TerminalView(
              term,
              controller: controller,
              scrollController: scrollController,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();
    final before = scrollController.offset;

    final box = tester.renderObject<RenderBox>(find.byType(TerminalView));
    final origin = box.localToGlobal(Offset.zero);
    await _drag(
      tester,
      origin + const Offset(2, 10),
      origin + const Offset(360, 60),
    );

    final selection = controller.selection;
    expect(selection, isNotNull);
    expect(term.buffer.getText(selection!), contains('scroll arena row'));
    expect(output.toString(), isEmpty);
    expect(scrollController.offset, before);
  });

  testWidgets('mouse wheel still reports to terminal in scroll-report mode', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    final controller = TerminalController(
      pointerInputs: const PointerInputs.none(),
    );
    term
      ..write('wheel report target')
      ..setMouseMode(MouseMode.upDownScroll)
      ..setMouseReportMode(MouseReportMode.sgr);
    final output = StringBuffer();
    term.onOutput = output.write;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 160,
            child: TerminalView(term, controller: controller),
          ),
        ),
      ),
    );
    await tester.pump();

    final box = tester.renderObject<RenderBox>(find.byType(TerminalView));
    final origin = box.localToGlobal(Offset.zero);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: origin + const Offset(20, 20),
        scrollDelta: const Offset(0, 40),
      ),
    );
    await tester.pump();

    expect(output.toString(), contains('\x1b[<69;'));
  });

  testWidgets('mouse wheel still scrolls local scrollback without mouse mode', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    for (var i = 0; i < 80; i++) {
      term.write('plain scroll row $i\r\n');
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 160,
            child: TerminalView(term, scrollController: scrollController),
          ),
        ),
      ),
    );
    await tester.pump();
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();
    final before = scrollController.offset;

    final box = tester.renderObject<RenderBox>(find.byType(TerminalView));
    final origin = box.localToGlobal(Offset.zero);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: origin + const Offset(20, 20),
        scrollDelta: const Offset(0, -80),
      ),
    );
    await tester.pump();

    expect(scrollController.offset, lessThan(before));
  });

  testWidgets('terminal key input clears selection and keeps focus flow', (
    tester,
  ) async {
    final term = Terminal(maxLines: 1000);
    final controller = TerminalController(
      pointerInputs: const PointerInputs.none(),
    );
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    term.write('selectable text\r\nnext line');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 260,
            child: TerminalView(
              term,
              controller: controller,
              focusNode: focusNode,
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
    expect(controller.selection, isNotNull);

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.selection, isNull);
    expect(term.buffer.getText(), contains('selectable text'));
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
_pumpTerminal(
  WidgetTester tester, {
  PointerInputs pointerInputs = const PointerInputs.none(),
}) async {
  final term = Terminal(maxLines: 1000);
  final controller = TerminalController(pointerInputs: pointerInputs);
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

class _MouseDragScrollBehavior extends MaterialScrollBehavior {
  const _MouseDragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}
