import 'package:flutter/material.dart';

import '../theme.dart';

// SplitPaneView is a content-agnostic split-pane layout engine (GoLand/VSCode
// style "split right" / "split down"): a binary(-ish) tree of panes, each leaf
// rendered by a caller-supplied builder, each split resizable via a draggable
// divider. This file owns only the tree data model + its pure operations and
// the widget that renders/drags it — it knows nothing about tabs, terminals or
// files. Business layers (file tabs, terminal sessions, ...) own a PaneNode,
// mutate it via the pure functions below, and hand it to SplitPaneView.

enum SplitAxis { horizontal, vertical } // horizontal = 左右分屏, vertical = 上下分屏

sealed class PaneNode {
  const PaneNode();
}

class PaneLeaf extends PaneNode {
  final String id; // caller-assigned stable id (uuid, counter, ...)
  const PaneLeaf(this.id);

  @override
  bool operator ==(Object other) => other is PaneLeaf && other.id == id;
  @override
  int get hashCode => Object.hash(PaneLeaf, id);
  @override
  String toString() => 'PaneLeaf($id)';
}

class PaneSplit extends PaneNode {
  // Stable identity independent of tree position/instance. PaneSplit is an
  // immutable value replaced wholesale on every edit (new children/weights),
  // so `identical()` can't be used to relocate "the same split" across
  // rebuilds — code that needs to address a specific split node (e.g.
  // SplitPaneView's onWeightsChanged callback) compares `id` instead.
  final String id;
  final SplitAxis axis;
  final List<PaneNode> children; // usually 2, but not hardcoded to exactly 2
  final List<double> weights; // same length as children; sums to ~1.0

  PaneSplit({
    required this.id,
    required this.axis,
    required this.children,
    required this.weights,
  }) : assert(children.length >= 2),
       assert(weights.length == children.length);

  PaneSplit copyWith({List<PaneNode>? children, List<double>? weights}) =>
      PaneSplit(
        id: id,
        axis: axis,
        children: children ?? this.children,
        weights: weights ?? this.weights,
      );

  @override
  String toString() => 'PaneSplit($id, $axis, $children, $weights)';
}

// splitLeaf replaces the leaf matching [targetLeafId] with a new PaneSplit
// holding the original leaf and a fresh PaneLeaf(newLeafId) (order controlled
// by [newFirst]), each weighted 0.5. Returns [tree] unchanged (same instance)
// if no leaf matches — callers are expected to guarantee targetLeafId exists.
// [splitId] lets a caller pin the new split's id explicitly; otherwise one is
// derived deterministically from the two leaf ids involved.
PaneNode splitLeaf(
  PaneNode tree,
  String targetLeafId,
  SplitAxis axis,
  String newLeafId, {
  bool newFirst = false,
  String? splitId,
}) {
  if (tree is PaneLeaf) {
    if (tree.id != targetLeafId) return tree;
    final newLeaf = PaneLeaf(newLeafId);
    return PaneSplit(
      id: splitId ?? 'split-$targetLeafId-$newLeafId',
      axis: axis,
      children: newFirst ? [newLeaf, tree] : [tree, newLeaf],
      weights: const [0.5, 0.5],
    );
  }
  final split = tree as PaneSplit;
  var changed = false;
  final children = <PaneNode>[];
  for (final child in split.children) {
    final updated = splitLeaf(
      child,
      targetLeafId,
      axis,
      newLeafId,
      newFirst: newFirst,
      splitId: splitId,
    );
    if (!identical(updated, child)) changed = true;
    children.add(updated);
  }
  return changed ? split.copyWith(children: children) : split;
}

// closeLeaf removes the leaf matching [leafId]. A PaneSplit left with a single
// child collapses into that child directly (no split node ever holds < 2
// children), and collapse cascades upward: if that makes the *grandparent*
// split down to one child too, it collapses as well, and so on. Returns null
// only when [tree] itself is the single matching leaf (the whole region is
// now empty) — callers decide how to render that.
PaneNode? closeLeaf(PaneNode tree, String leafId) {
  if (tree is PaneLeaf) {
    return tree.id == leafId ? null : tree;
  }
  final split = tree as PaneSplit;
  final newChildren = <PaneNode>[];
  final newWeights = <double>[];
  for (var i = 0; i < split.children.length; i++) {
    final updated = closeLeaf(split.children[i], leafId);
    if (updated == null) continue; // dropped
    newChildren.add(updated);
    newWeights.add(split.weights[i]);
  }

  if (newChildren.isEmpty) return null; // defensive: shouldn't happen (>=2 children)
  if (newChildren.length == 1) return newChildren.single; // collapse into parent slot

  if (newChildren.length == split.children.length) {
    // Nothing removed at this level, but a descendant may have collapsed
    // (its reference changed shape without changing this level's count).
    var changed = false;
    for (var i = 0; i < newChildren.length; i++) {
      if (!identical(newChildren[i], split.children[i])) changed = true;
    }
    return changed ? split.copyWith(children: newChildren) : split;
  }

  // A direct child was dropped: renormalize the remaining weights to sum 1.0.
  final total = newWeights.fold<double>(0, (a, b) => a + b);
  final normalized = total > 0
      ? [for (final w in newWeights) w / total]
      : List<double>.filled(newWeights.length, 1 / newWeights.length);
  return split.copyWith(children: newChildren, weights: normalized);
}

// leafIds collects every leaf id in the tree, depth-first, left/top-to-right/
// bottom order.
List<String> leafIds(PaneNode tree) {
  if (tree is PaneLeaf) return [tree.id];
  final split = tree as PaneSplit;
  return [for (final child in split.children) ...leafIds(child)];
}

// updateWeights immutably replaces the weights of the PaneSplit whose `id`
// matches [target].id, leaving every other node untouched. Locating by id
// (rather than `identical`) is what makes this reliable across rebuilds: the
// caller can hold on to a PaneSplit reference from a previous tree snapshot
// (e.g. captured in a drag callback) and still address "that same split" in
// the current tree.
PaneNode updateWeights(PaneNode tree, PaneSplit target, List<double> newWeights) {
  if (tree is PaneLeaf) return tree;
  final split = tree as PaneSplit;
  if (split.id == target.id) {
    assert(newWeights.length == split.children.length);
    return split.copyWith(weights: newWeights);
  }
  var changed = false;
  final children = <PaneNode>[];
  for (final child in split.children) {
    final updated = updateWeights(child, target, newWeights);
    if (!identical(updated, child)) changed = true;
    children.add(updated);
  }
  return changed ? split.copyWith(children: children) : split;
}

// SplitPaneView renders a PaneNode tree: leaves via [paneBuilder], splits as a
// Row (horizontal axis) or Column (vertical axis) of resizable panes. It owns
// no tree state itself — dragging a divider computes new weights and reports
// them via [onWeightsChanged]; the caller is expected to run those through
// [updateWeights] and setState the result back in as a new [tree].
class SplitPaneView extends StatelessWidget {
  final PaneNode tree;
  final Widget Function(BuildContext context, String paneId) paneBuilder;
  final void Function(PaneSplit target, List<double> newWeights)
  onWeightsChanged;

  const SplitPaneView({
    super.key,
    required this.tree,
    required this.paneBuilder,
    required this.onWeightsChanged,
  });

  @override
  Widget build(BuildContext context) => _buildNode(context, tree);

  Widget _buildNode(BuildContext context, PaneNode node) {
    if (node is PaneLeaf) return paneBuilder(context, node.id);
    return _SplitNodeView(
      split: node as PaneSplit,
      buildChild: _buildNode,
      onWeightsChanged: onWeightsChanged,
    );
  }
}

class _SplitNodeView extends StatelessWidget {
  static const _dividerThickness = 8.0;
  static const _minWeight = 0.1;

  final PaneSplit split;
  final Widget Function(BuildContext context, PaneNode node) buildChild;
  final void Function(PaneSplit target, List<double> newWeights)
  onWeightsChanged;

  const _SplitNodeView({
    required this.split,
    required this.buildChild,
    required this.onWeightsChanged,
  });

  static int _flexFor(double weight) => (weight * 10000).round().clamp(1, 1 << 30);

  @override
  Widget build(BuildContext context) {
    final horizontal = split.axis == SplitAxis.horizontal;
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalExtent = horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        final dividerSpace = _dividerThickness * (split.children.length - 1);
        final available = (totalExtent - dividerSpace).clamp(
          1.0,
          double.infinity,
        );

        final items = <Widget>[];
        for (var i = 0; i < split.children.length; i++) {
          items.add(
            Expanded(
              flex: _flexFor(split.weights[i]),
              child: buildChild(context, split.children[i]),
            ),
          );
          if (i < split.children.length - 1) {
            final left = i;
            final right = i + 1;
            items.add(
              _PaneDivider(
                axis: split.axis,
                thickness: _dividerThickness,
                onDragDelta: (deltaPx) {
                  final frac = deltaPx / available;
                  final total = split.weights[left] + split.weights[right];
                  var a = split.weights[left] + frac;
                  var b = total - a;
                  if (a < _minWeight) {
                    a = _minWeight;
                    b = total - a;
                  }
                  if (b < _minWeight) {
                    b = _minWeight;
                    a = total - b;
                  }
                  final newWeights = List<double>.of(split.weights);
                  newWeights[left] = a;
                  newWeights[right] = b;
                  onWeightsChanged(split, newWeights);
                },
              ),
            );
          }
        }

        return Flex(
          direction: horizontal ? Axis.horizontal : Axis.vertical,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: items,
        );
      },
    );
  }
}

// _PaneDivider mirrors the look/feel of the app's existing pane-resize handles
// (see DragHandle / resizeHandle in widgets.dart, and
// WorkspacePage._horizontalResizeHandle): an 8px hit area with a thin 1px
// border-colored line that thickens to 2px and switches to the accent color
// on hover/drag.
class _PaneDivider extends StatefulWidget {
  final SplitAxis axis;
  final double thickness;
  final ValueChanged<double> onDragDelta;

  const _PaneDivider({
    required this.axis,
    required this.thickness,
    required this.onDragDelta,
  });

  @override
  State<_PaneDivider> createState() => _PaneDividerState();
}

class _PaneDividerState extends State<_PaneDivider> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == SplitAxis.horizontal;
    final noMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _active = true),
      onExit: (_) => setState(() => _active = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: horizontal
            ? (d) => widget.onDragDelta(d.delta.dx)
            : null,
        onVerticalDragUpdate: horizontal
            ? null
            : (d) => widget.onDragDelta(d.delta.dy),
        child: SizedBox(
          width: horizontal ? widget.thickness : null,
          height: horizontal ? null : widget.thickness,
          child: Center(
            child: AnimatedContainer(
              duration: noMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              width: horizontal ? (_active ? 2 : 1) : null,
              height: horizontal ? null : (_active ? 2 : 1),
              color: _active ? CcColors.accent : CcColors.border,
            ),
          ),
        ),
      ),
    );
  }
}
