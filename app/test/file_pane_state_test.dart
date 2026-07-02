import 'package:app/screens/workspace/file_pane_state.dart';
import 'package:app/widgets/split_pane.dart';
import 'package:flutter_test/flutter_test.dart';

// Pure-logic tests for the split-pane file editor's per-pane bookkeeping:
// which pane a path belongs to, splitting a tab out into a sibling pane, and
// reconciling the maps + tree after files close (including cascading
// collapse of emptied panes). No widget pumping — see workspace_page.dart's
// _fileToPane/_paneActivePath field comments for how this plugs into State.

void main() {
  group('paneOfPath', () {
    test('defaults to root when unassigned', () {
      expect(paneOfPath(const {}, '/a.dart'), 'root');
    });

    test('returns the explicit assignment when present', () {
      expect(paneOfPath(const {'/a.dart': 'pane-1'}, '/a.dart'), 'pane-1');
    });
  });

  group('paneFileIndices', () {
    test('filters to indices assigned to the given pane, defaulting to root', () {
      final paths = ['/a.dart', '/b.dart', '/c.dart'];
      final fileToPane = {'/b.dart': 'pane-1'};
      expect(paneFileIndices(paths, fileToPane, 'root'), [0, 2]);
      expect(paneFileIndices(paths, fileToPane, 'pane-1'), [1]);
    });
  });

  group('splitPaneForFile', () {
    test('splits root into two panes, moving the target file out', () {
      final r = splitPaneForFile(
        tree: const PaneLeaf('root'),
        openPaths: const ['/a.dart', '/b.dart'],
        fileToPane: const {},
        paneActivePath: const {},
        path: '/b.dart',
        axis: SplitAxis.horizontal,
        newPaneId: 'pane-1',
      );
      expect(leafIds(r.tree), ['root', 'pane-1']);
      expect(paneOfPath(r.fileToPane, '/b.dart'), 'pane-1');
      expect(paneOfPath(r.fileToPane, '/a.dart'), 'root'); // untouched
      expect(r.paneActivePath['pane-1'], '/b.dart');
      expect(
        r.paneActivePath['root'],
        '/a.dart',
        reason: "source pane's active file moves to whatever's left",
      );
      expect(r.focusedPaneId, 'pane-1');
    });

    test('source pane active path goes null when it held only the split file', () {
      final r = splitPaneForFile(
        tree: const PaneLeaf('root'),
        openPaths: const ['/a.dart'],
        fileToPane: const {},
        paneActivePath: const {},
        path: '/a.dart',
        axis: SplitAxis.vertical,
        newPaneId: 'pane-1',
      );
      expect(r.paneActivePath['root'], isNull);
      expect(r.paneActivePath['pane-1'], '/a.dart');
    });

    test('splitting a file that already lives in a non-root pane targets that pane', () {
      final r = splitPaneForFile(
        tree: PaneSplit(
          id: 's1',
          axis: SplitAxis.horizontal,
          children: const [PaneLeaf('root'), PaneLeaf('pane-1')],
          weights: const [0.5, 0.5],
        ),
        openPaths: const ['/a.dart', '/b.dart'],
        fileToPane: const {'/b.dart': 'pane-1'},
        paneActivePath: const {'pane-1': '/b.dart'},
        path: '/b.dart',
        axis: SplitAxis.vertical,
        newPaneId: 'pane-2',
      );
      expect(leafIds(r.tree), ['root', 'pane-1', 'pane-2']);
      expect(paneOfPath(r.fileToPane, '/b.dart'), 'pane-2');
      expect(r.paneActivePath['pane-1'], isNull); // nothing left in pane-1
      expect(r.paneActivePath['pane-2'], '/b.dart');
    });
  });

  group('reconcilePaneTree', () {
    test('is a no-op when every pane still has files', () {
      final tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('root'), PaneLeaf('pane-1')],
        weights: const [0.5, 0.5],
      );
      final r = reconcilePaneTree(
        tree: tree,
        openPaths: const ['/a.dart', '/b.dart'],
        fileToPane: const {'/b.dart': 'pane-1'},
        paneActivePath: const {'root': '/a.dart', 'pane-1': '/b.dart'},
        focusedPaneId: 'pane-1',
      );
      expect(leafIds(r.tree), ['root', 'pane-1']);
      expect(r.paneActivePath, {'root': '/a.dart', 'pane-1': '/b.dart'});
      expect(r.focusedPaneId, 'pane-1');
    });

    test('collapses a pane left with zero files and refocuses if it was focused', () {
      final tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('root'), PaneLeaf('pane-1')],
        weights: const [0.5, 0.5],
      );
      // /b.dart (pane-1's only file) already closed — no longer in openPaths.
      final r = reconcilePaneTree(
        tree: tree,
        openPaths: const ['/a.dart'],
        fileToPane: const {'/b.dart': 'pane-1'},
        paneActivePath: const {'root': '/a.dart', 'pane-1': '/b.dart'},
        focusedPaneId: 'pane-1',
      );
      expect(r.tree, const PaneLeaf('root')); // collapsed back to a lone leaf
      expect(r.focusedPaneId, 'root'); // focus follows off the closed pane
      expect(r.paneActivePath['root'], '/a.dart');
      expect(r.paneActivePath.containsKey('pane-1'), isFalse);
      expect(r.fileToPane.containsKey('/b.dart'), isFalse); // stale entry dropped
    });

    test('keeps a non-focused pane collapsed even when the focused pane is untouched', () {
      final tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('root'), PaneLeaf('pane-1')],
        weights: const [0.3, 0.7],
      );
      final r = reconcilePaneTree(
        tree: tree,
        openPaths: const ['/a.dart'],
        fileToPane: const {'/b.dart': 'pane-1'},
        paneActivePath: const {'root': '/a.dart', 'pane-1': '/b.dart'},
        focusedPaneId: 'root',
      );
      expect(r.tree, const PaneLeaf('root'));
      expect(r.focusedPaneId, 'root'); // stays put, it was never the empty one
    });

    test('picks a new active path when the old one closed but the pane survives', () {
      final tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('root'), PaneLeaf('pane-1')],
        weights: const [0.5, 0.5],
      );
      // pane-1 had /b.dart (active) and /c.dart; /b.dart just closed.
      final r = reconcilePaneTree(
        tree: tree,
        openPaths: const ['/a.dart', '/c.dart'],
        fileToPane: const {'/c.dart': 'pane-1'},
        paneActivePath: const {'root': '/a.dart', 'pane-1': '/b.dart'},
        focusedPaneId: 'pane-1',
      );
      expect(leafIds(r.tree), ['root', 'pane-1']); // pane-1 survives (still has /c.dart)
      expect(r.paneActivePath['pane-1'], '/c.dart');
    });

    test('cascades collapse through a nested split down to a single leaf', () {
      // grandparent(splitA, leaf-w); splitA(leaf-root, leaf-pane-1)
      final splitA = PaneSplit(
        id: 'a',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('root'), PaneLeaf('pane-1')],
        weights: const [0.5, 0.5],
      );
      final grandparent = PaneSplit(
        id: 'g',
        axis: SplitAxis.vertical,
        children: [splitA, const PaneLeaf('pane-w')],
        weights: const [0.5, 0.5],
      );
      // Only pane-w's file remains open; root and pane-1 both emptied out.
      final r = reconcilePaneTree(
        tree: grandparent,
        openPaths: const ['/w.dart'],
        fileToPane: const {'/w.dart': 'pane-w'},
        paneActivePath: const {
          'root': '/a.dart',
          'pane-1': '/b.dart',
          'pane-w': '/w.dart',
        },
        focusedPaneId: 'root',
      );
      expect(r.tree, const PaneLeaf('pane-w'));
      expect(r.focusedPaneId, 'pane-w');
      expect(r.paneActivePath['pane-w'], '/w.dart');
    });

    test('drops every pane entry when nothing is open anywhere', () {
      final tree = PaneSplit(
        id: 's1',
        axis: SplitAxis.horizontal,
        children: const [PaneLeaf('root'), PaneLeaf('pane-1')],
        weights: const [0.5, 0.5],
      );
      final r = reconcilePaneTree(
        tree: tree,
        openPaths: const [],
        fileToPane: const {'/a.dart': 'root', '/b.dart': 'pane-1'},
        paneActivePath: const {'root': '/a.dart', 'pane-1': '/b.dart'},
        focusedPaneId: 'pane-1',
      );
      // Both panes empty: the loop stops once a single leaf remains (it never
      // closes the very last leaf away entirely) — callers treat an empty
      // _codeFiles list as the degenerate "nothing open" case regardless of
      // which leaf id survives.
      expect(leafIds(r.tree).length, 1);
      expect(r.fileToPane, isEmpty);
    });
  });
}
