import '../../widgets/split_pane.dart';

// Pure, State-free helpers for the split-pane file editor's per-pane
// bookkeeping (which pane owns which open file + each pane's active file).
// _WorkspacePageState in workspace_page.dart owns the actual mutable
// _fileToPane / _paneActivePath maps + _filePaneTree; these functions
// compute the next value from explicit inputs, so the split/close/collapse
// logic is unit-testable without pumping the whole page (which needs a
// RelayClient, AppConfig, filesystem + git access to construct).
//
// A path absent from fileToPane defaults to living in the original 'root'
// pane/leaf — see the _fileToPane field comment in workspace_page.dart.

String paneOfPath(Map<String, String> fileToPane, String path) =>
    fileToPane[path] ?? 'root';

List<int> paneFileIndices(
  List<String> openPaths,
  Map<String, String> fileToPane,
  String paneId,
) => [
  for (var i = 0; i < openPaths.length; i++)
    if (paneOfPath(fileToPane, openPaths[i]) == paneId) i,
];

class PaneReconcileResult {
  final PaneNode tree;
  final Map<String, String> fileToPane;
  final Map<String, String?> paneActivePath;
  final String focusedPaneId;
  const PaneReconcileResult({
    required this.tree,
    required this.fileToPane,
    required this.paneActivePath,
    required this.focusedPaneId,
  });
}

// Drops closed paths from fileToPane/paneActivePath, collapses any pane left
// with zero open files (cascading through closeLeaf, since collapsing one
// pane can starve its former parent's sibling), and — if the focused pane
// collapsed away — repoints focus at whatever leaf survived. Only
// meaningful once actually split; callers guard on `tree is PaneSplit`.
PaneReconcileResult reconcilePaneTree({
  required PaneNode tree,
  required List<String> openPaths,
  required Map<String, String> fileToPane,
  required Map<String, String?> paneActivePath,
  required String focusedPaneId,
}) {
  final valid = openPaths.toSet();
  final nextFileToPane = {
    for (final e in fileToPane.entries)
      if (valid.contains(e.key)) e.key: e.value,
  };
  final nextPaneActivePath = <String, String?>{
    for (final e in paneActivePath.entries)
      e.key: (e.value != null && valid.contains(e.value)) ? e.value : null,
  };
  String pane(String path) => paneOfPath(nextFileToPane, path);

  var nextTree = tree;
  var nextFocused = focusedPaneId;
  while (true) {
    final leaves = leafIds(nextTree);
    if (leaves.length <= 1) break;
    final empty = leaves.firstWhere(
      (id) => !openPaths.any((p) => pane(p) == id),
      orElse: () => '',
    );
    if (empty.isEmpty) break;
    nextTree = closeLeaf(nextTree, empty) ?? const PaneLeaf('root');
    nextPaneActivePath.remove(empty);
    if (nextFocused == empty) {
      final remaining = leafIds(nextTree);
      nextFocused = remaining.isNotEmpty ? remaining.first : 'root';
    }
  }

  for (final id in leafIds(nextTree)) {
    final files = [for (final p in openPaths) if (pane(p) == id) p];
    if (files.isEmpty) continue;
    final active = nextPaneActivePath[id];
    if (active == null || !files.contains(active)) {
      nextPaneActivePath[id] = files.first;
    }
  }

  return PaneReconcileResult(
    tree: nextTree,
    fileToPane: nextFileToPane,
    paneActivePath: nextPaneActivePath,
    focusedPaneId: nextFocused,
  );
}

class PaneSplitResult {
  final PaneNode tree;
  final Map<String, String> fileToPane;
  final Map<String, String?> paneActivePath;
  final String focusedPaneId;
  const PaneSplitResult({
    required this.tree,
    required this.fileToPane,
    required this.paneActivePath,
    required this.focusedPaneId,
  });
}

// "Split right" / "split down": pulls [path] out of its current pane into a
// freshly-split sibling pane ([newPaneId], caller-assigned so it stays
// pure), and points the source pane's active file at whatever's left there.
PaneSplitResult splitPaneForFile({
  required PaneNode tree,
  required List<String> openPaths,
  required Map<String, String> fileToPane,
  required Map<String, String?> paneActivePath,
  required String path,
  required SplitAxis axis,
  required String newPaneId,
}) {
  final sourcePane = paneOfPath(fileToPane, path);
  final nextFileToPane = {...fileToPane, path: newPaneId};
  final nextTree = splitLeaf(tree, sourcePane, axis, newPaneId);
  final remaining = [
    for (final p in openPaths)
      if (paneOfPath(nextFileToPane, p) == sourcePane) p,
  ];
  final nextPaneActivePath = {
    ...paneActivePath,
    newPaneId: path,
    sourcePane: remaining.isNotEmpty ? remaining.first : null,
  };
  return PaneSplitResult(
    tree: nextTree,
    fileToPane: nextFileToPane,
    paneActivePath: nextPaneActivePath,
    focusedPaneId: newPaneId,
  );
}
