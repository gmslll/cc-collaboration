import 'package:app/widgets/split_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Pure tree-operation tests (split / close / collapse / weights) plus a
// couple of widget smoke tests for SplitPaneView's rendering + drag-to-resize.

void main() {
  group('splitLeaf', () {
    test('splits a lone leaf into a 2-child split, 0.5/0.5, default order', () {
      final tree = splitLeaf(const PaneLeaf('a'), 'a', SplitAxis.horizontal, 'b');
      expect(tree, isA<PaneSplit>());
      final split = tree as PaneSplit;
      expect(split.axis, SplitAxis.horizontal);
      expect(split.children, [const PaneLeaf('a'), const PaneLeaf('b')]);
      expect(split.weights, [0.5, 0.5]);
    });

    test('newFirst reverses child order', () {
      final tree = splitLeaf(
        const PaneLeaf('a'),
        'a',
        SplitAxis.vertical,
        'b',
        newFirst: true,
      );
      final split = tree as PaneSplit;
      expect(split.children, [const PaneLeaf('b'), const PaneLeaf('a')]);
    });

    test('splits a nested leaf, leaving siblings untouched (same instance)', () {
      final leafB = const PaneLeaf('b');
      final original = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: [const PaneLeaf('a'), leafB],
        weights: const [0.5, 0.5],
      );
      final updated = splitLeaf(original, 'a', SplitAxis.vertical, 'c') as PaneSplit;
      expect(updated.id, 's1');
      expect(identical(updated.children[1], leafB), isTrue); // sibling untouched
      final nested = updated.children[0] as PaneSplit;
      expect(nested.children, [const PaneLeaf('a'), const PaneLeaf('c')]);
    });

    test('missing targetLeafId returns the same tree instance', () {
      final tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('a'), PaneLeaf('b')],
        weights: const [0.5, 0.5],
      );
      expect(identical(splitLeaf(tree, 'zzz', SplitAxis.horizontal, 'c'), tree), isTrue);
    });

    test('caller can pin an explicit splitId', () {
      final tree = splitLeaf(
        const PaneLeaf('a'),
        'a',
        SplitAxis.horizontal,
        'b',
        splitId: 'my-split',
      );
      expect((tree as PaneSplit).id, 'my-split');
    });
  });

  group('closeLeaf', () {
    test('closing the only leaf in a single-leaf tree returns null', () {
      expect(closeLeaf(const PaneLeaf('a'), 'a'), isNull);
    });

    test('closing not-present leaf id returns tree unchanged (same instance)', () {
      final tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('a'), PaneLeaf('b')],
        weights: const [0.5, 0.5],
      );
      expect(identical(closeLeaf(tree, 'zzz'), tree), isTrue);
      expect(identical(closeLeaf(const PaneLeaf('a'), 'zzz'), const PaneLeaf('a')), isTrue);
    });

    test('closing one of 2 children collapses the split into the remaining leaf', () {
      final tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('a'), PaneLeaf('b')],
        weights: const [0.3, 0.7],
      );
      final result = closeLeaf(tree, 'a');
      expect(result, const PaneLeaf('b')); // collapsed, not a PaneSplit anymore
    });

    test('closing one of 3 children keeps the split, renormalizes weights to sum 1.0', () {
      final tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('a'), PaneLeaf('b'), PaneLeaf('c')],
        weights: const [0.2, 0.3, 0.5],
      );
      final result = closeLeaf(tree, 'b') as PaneSplit;
      expect(leafIds(result), ['a', 'c']);
      expect(result.weights.length, 2);
      final sum = result.weights.reduce((x, y) => x + y);
      expect(sum, closeTo(1.0, 1e-9));
      // relative proportions between the two survivors are preserved (2:5)
      expect(result.weights[0] / result.weights[1], closeTo(0.2 / 0.5, 1e-9));
    });

    test('collapse cascades through multiple levels', () {
      // grandparent(splitA, leafW); splitA(splitB, leafX); splitB(leafY, leafZ)
      final splitB = PaneSplit(
        id: 'b',
        axis: SplitAxis.vertical,
        children: const [PaneLeaf('y'), PaneLeaf('z')],
        weights: const [0.5, 0.5],
      );
      final splitA = PaneSplit(
        id: 'a',
        axis: SplitAxis.horizontal,
        children: [splitB, const PaneLeaf('x')],
        weights: const [0.5, 0.5],
      );
      final grandparent = PaneSplit(
        id: 'g',
        axis: SplitAxis.vertical,
        children: [splitA, const PaneLeaf('w')],
        weights: const [0.5, 0.5],
      );

      final result = closeLeaf(grandparent, 'y') as PaneSplit;
      expect(result.id, 'g'); // grandparent itself keeps its own 2 children
      expect(leafIds(result), ['z', 'x', 'w']);
      final newSplitA = result.children[0] as PaneSplit;
      expect(newSplitA.id, 'a');
      expect(leafIds(newSplitA), ['z', 'x']); // splitB collapsed into 'z' directly
      expect(newSplitA.children[0], const PaneLeaf('z')); // no more nested split here
    });

    test('cascades all the way to null when everything closes down to the target', () {
      final tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('a'), PaneLeaf('b')],
        weights: const [0.5, 0.5],
      );
      final afterA = closeLeaf(tree, 'a'); // -> PaneLeaf('b')
      expect(afterA, const PaneLeaf('b'));
      expect(closeLeaf(afterA!, 'b'), isNull);
    });
  });

  group('leafIds', () {
    test('collects leaves depth-first in tree order', () {
      final tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: [
          PaneSplit(
            id: 's2',
            axis: SplitAxis.vertical,
            children: const [PaneLeaf('a'), PaneLeaf('b')],
            weights: const [0.5, 0.5],
          ),
          const PaneLeaf('c'),
        ],
        weights: const [0.5, 0.5],
      );
      expect(leafIds(tree), ['a', 'b', 'c']);
    });
  });

  group('updateWeights', () {
    test('replaces weights only on the matching split id, by id not identity', () {
      final inner = PaneSplit(
        id: 'inner',
        axis: SplitAxis.vertical,
        children: const [PaneLeaf('a'), PaneLeaf('b')],
        weights: const [0.5, 0.5],
      );
      final outer = PaneSplit(
        id: 'outer',
        axis: SplitAxis.horizontal,
        children: [inner, const PaneLeaf('c')],
        weights: const [0.4, 0.6],
      );

      // A stale/rebuilt PaneSplit instance with the same id still addresses
      // the live node — that's the whole point of keying by id.
      final staleHandle = PaneSplit(
        id: 'inner',
        axis: SplitAxis.vertical,
        children: const [PaneLeaf('stale1'), PaneLeaf('stale2')],
        weights: const [0.5, 0.5],
      );
      final result = updateWeights(outer, staleHandle, [0.2, 0.8]) as PaneSplit;

      expect(result.weights, [0.4, 0.6]); // outer's own weights untouched
      final newInner = result.children[0] as PaneSplit;
      expect(newInner.weights, [0.2, 0.8]);
      expect(identical(result.children[1], outer.children[1]), isTrue); // sibling untouched
    });

    test('no matching id leaves the tree unchanged (same instance)', () {
      final tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('a'), PaneLeaf('b')],
        weights: const [0.5, 0.5],
      );
      final phantom = PaneSplit(
        id: 'zzz',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('x1'), PaneLeaf('x2')],
        weights: const [0.5, 0.5],
      );
      expect(identical(updateWeights(tree, phantom, [0.1, 0.9]), tree), isTrue);
    });
  });

  group('SplitPaneView widget', () {
    Widget host(PaneNode tree, void Function(PaneSplit, List<double>) onChanged) =>
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 300,
              child: SplitPaneView(
                tree: tree,
                paneBuilder: (context, paneId) =>
                    ColoredBox(key: ValueKey(paneId), color: Colors.black),
                onWeightsChanged: onChanged,
              ),
            ),
          ),
        );

    testWidgets('renders every leaf via paneBuilder', (tester) async {
      final tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('a'), PaneLeaf('b')],
        weights: const [0.5, 0.5],
      );
      await tester.pumpWidget(host(tree, (_, _) {}));
      expect(find.byKey(const ValueKey('a')), findsOneWidget);
      expect(find.byKey(const ValueKey('b')), findsOneWidget);
    });

    testWidgets('dragging the divider reports rebalanced weights, no crash', (
      tester,
    ) async {
      PaneSplit? reportedTarget;
      List<double>? reportedWeights;
      final tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('a'), PaneLeaf('b')],
        weights: const [0.5, 0.5],
      );
      await tester.pumpWidget(
        host(tree, (target, weights) {
          reportedTarget = target;
          reportedWeights = weights;
        }),
      );

      // The divider is the sole GestureDetector in this scene (panes are
      // plain ColoredBoxes with no gestures of their own).
      final divider = find.byType(GestureDetector);
      expect(divider, findsOneWidget);

      await tester.drag(divider, const Offset(60, 0));
      await tester.pump();

      expect(reportedTarget?.id, 's1');
      expect(reportedWeights, isNotNull);
      expect(reportedWeights![0] + reportedWeights![1], closeTo(1.0, 1e-9));
      expect(reportedWeights![0], greaterThan(0.5)); // dragged right → grows
    });

    testWidgets('a full split→drag→update cycle rebuilds without error', (
      tester,
    ) async {
      PaneNode tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.vertical,
        children: const [PaneLeaf('a'), PaneLeaf('b')],
        weights: const [0.5, 0.5],
      );

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => host(tree, (target, weights) {
            setState(() => tree = updateWeights(tree, target, weights));
          }),
        ),
      );

      final divider = find.byType(GestureDetector);
      await tester.drag(divider, const Offset(0, -40));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('a')), findsOneWidget);
      expect(find.byKey(const ValueKey('b')), findsOneWidget);
    });
  });
}
