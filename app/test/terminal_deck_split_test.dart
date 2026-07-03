import 'package:app/screens/terminal_deck.dart';
import 'package:app/screens/terminal_pane.dart';
import 'package:app/widgets/split_pane.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Exercises TerminalHost's split-pane bookkeeping in isolation from real
// widget rendering — pane assignment, split, collapse-on-empty (whether
// caused by a close or by a split moving a pane's only tab out). Mirrors
// kill_local_session_test.dart's _Host pattern: sessions are constructed and
// added to `terms` directly (never addTerm, which spawns a real PTY via
// start()); tests that reach a setState-touching method (splitTermRight/Down,
// closeTerm) need a mounted Element via GlobalKey + pumpWidget, tests that
// only touch the pure/no-setState helpers (debugAssignSessionToPane,
// focusPane, the out-of-range guards) work against a bare unmounted State.
class _Host extends StatefulWidget {
  const _Host({super.key});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TerminalHost<_Host> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

TerminalSession _plainSession() => TerminalSession('/repo', '', agent: '');

// splitTermRight/splitTermDown/closeTerm all end in _activeChanged(), which
// calls .start() on the now-active session — arming a real boot-ready Timer.
// Nothing in these tests ever produces PTY output to clear it, and the test
// framework's end-of-test invariant check (which runs before addTearDown
// callbacks fire) fails on any pending Timer — so every test that reaches
// one of those methods must settle it explicitly, same as
// deliver_collision_test.dart's debugMarkBootSettled() calls. Safe to call on
// a session that was never started too (no-ops: no timer to cancel).
void _settleAll(_HostState host) {
  for (final s in host.terms) {
    s.debugMarkBootSettled();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fresh host starts as a single degenerate root pane, empty', () {
    final host = _HostState();
    expect(host.debugPaneTree, const PaneLeaf('root'));
    expect(host.debugPaneSessions, {'root': <String>[]});
    expect(host.debugFocusedPaneId, isNull);
  });

  test('debugAssignSessionToPane places a session in the current pane', () {
    final host = _HostState();
    final s1 = _plainSession();
    addTearDown(s1.dispose);
    host.terms.add(s1);

    host.debugAssignSessionToPane(s1.id);

    expect(host.debugPaneSessions['root'], [s1.id]);
  });

  test('focusPane to an unknown pane id falls back to the tree\'s first leaf', () {
    final host = _HostState();
    final s1 = _plainSession();
    addTearDown(s1.dispose);
    host.terms.add(s1);

    host.focusPane('does-not-exist');
    host.debugAssignSessionToPane(s1.id);

    expect(host.debugPaneSessions['root'], [s1.id]);
  });

  test('splitTermRight/splitTermDown no-op on an out-of-range index', () {
    final host = _HostState();
    host.splitTermRight(0); // terms is empty
    host.splitTermDown(-1);
    expect(host.debugPaneTree, const PaneLeaf('root'));
    expect(host.debugPaneSessions, {'root': <String>[]});
  });

  group('splitTermRight/splitTermDown (require a mounted host: setState)', () {
    testWidgets(
      'splitting a pane\'s only tab moves it out and collapses the emptied source',
      (tester) async {
        final key = GlobalKey<_HostState>();
        await tester.pumpWidget(_Host(key: key));
        final host = key.currentState!;
        final s1 = _plainSession();
        addTearDown(s1.dispose);
        host.terms.add(s1);
        host.debugAssignSessionToPane(s1.id);

        host.splitTermRight(0);
        _settleAll(host);
        await tester.pump();

        // Net effect of splitting a single-tab pane: still exactly one leaf
        // (the source collapsed away per _collapseIfEmpty), just under a new
        // pane id holding the moved session — not a permanent blank pane.
        final leaves = leafIds(host.debugPaneTree);
        expect(leaves, hasLength(1));
        expect(host.debugPaneSessions.keys, leaves);
        expect(host.debugPaneSessions[leaves.single], [s1.id]);
        expect(host.debugFocusedPaneId, leaves.single);
        expect(host.activeTerm, 0);
      },
    );

    testWidgets(
      'splitting one of two tabs leaves the other behind in the source pane',
      (tester) async {
        final key = GlobalKey<_HostState>();
        await tester.pumpWidget(_Host(key: key));
        final host = key.currentState!;
        final s1 = _plainSession();
        final s2 = _plainSession();
        addTearDown(s1.dispose);
        addTearDown(s2.dispose);
        host.terms.addAll([s1, s2]);
        host.debugAssignSessionToPane(s1.id);
        host.debugAssignSessionToPane(s2.id);
        expect(host.debugPaneSessions['root'], [s1.id, s2.id]);

        host.splitTermRight(1); // split s2 (terms[1]) out to the right
        _settleAll(host);
        await tester.pump();

        final tree = host.debugPaneTree as PaneSplit;
        expect(tree.axis, SplitAxis.horizontal);
        final leaves = leafIds(tree);
        expect(leaves, hasLength(2));
        expect(host.debugPaneSessions['root'], [s1.id]); // s2 gone, s1 stays
        final newPaneId = leaves.firstWhere((l) => l != 'root');
        expect(host.debugPaneSessions[newPaneId], [s2.id]);
        expect(host.debugFocusedPaneId, newPaneId);
      },
    );

    testWidgets('a second split (Down) produces 3 panes total', (tester) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(_Host(key: key));
      final host = key.currentState!;
      final s1 = _plainSession();
      final s2 = _plainSession();
      final s3 = _plainSession();
      addTearDown(s1.dispose);
      addTearDown(s2.dispose);
      addTearDown(s3.dispose);
      host.terms.addAll([s1, s2, s3]);
      for (final s in host.terms) {
        host.debugAssignSessionToPane(s.id);
      }

      host.splitTermRight(1); // s2 -> new pane beside root ({s1}|{s2})
      _settleAll(host);
      await tester.pump();
      host.splitTermDown(0); // split s1 (still in root) downward
      _settleAll(host);
      await tester.pump();

      final leaves = leafIds(host.debugPaneTree);
      expect(leaves, hasLength(3));
      final allIds = host.debugPaneSessions.values.expand((l) => l).toSet();
      expect(allIds, {s1.id, s2.id, s3.id});
    });

    testWidgets(
      'splitTermRight self-heals a session that was never explicitly assigned to a pane',
      (tester) async {
        final key = GlobalKey<_HostState>();
        await tester.pumpWidget(_Host(key: key));
        final host = key.currentState!;
        final s1 = _plainSession();
        addTearDown(s1.dispose);
        host.terms.add(s1); // deliberately skip debugAssignSessionToPane

        host.splitTermRight(0);
        _settleAll(host);
        await tester.pump();

        final leaves = leafIds(host.debugPaneTree);
        expect(leaves, hasLength(1));
        expect(host.debugPaneSessions[leaves.single], [s1.id]);
      },
    );
  });

  group('closeTerm interaction with panes (require a mounted host)', () {
    testWidgets(
      'closing the last session in a split-off pane collapses it back to a single pane',
      (tester) async {
        final key = GlobalKey<_HostState>();
        await tester.pumpWidget(_Host(key: key));
        final host = key.currentState!;
        final s1 = _plainSession();
        final s2 = _plainSession();
        addTearDown(s1.dispose); // s2 gets disposed by closeTerm itself
        host.terms.addAll([s1, s2]);
        host.debugAssignSessionToPane(s1.id);
        host.debugAssignSessionToPane(s2.id);
        host.splitTermRight(1); // s2 -> its own pane
        _settleAll(host);
        await tester.pump();
        expect(leafIds(host.debugPaneTree), hasLength(2));

        host.closeTerm(host.terms.indexOf(s2));
        _settleAll(host);
        await tester.pump();

        expect(host.debugPaneTree, const PaneLeaf('root'));
        expect(host.debugPaneSessions.keys, ['root']);
        expect(host.debugPaneSessions['root'], [s1.id]);
      },
    );

    testWidgets(
      'closing the only session in the only (unsplit) pane leaves a single empty leaf, not stuck elsewhere',
      (tester) async {
        final key = GlobalKey<_HostState>();
        await tester.pumpWidget(_Host(key: key));
        final host = key.currentState!;
        final s1 = _plainSession();
        host.terms.add(s1); // closeTerm disposes it
        host.debugAssignSessionToPane(s1.id);

        host.closeTerm(0);
        _settleAll(host);
        await tester.pump();

        final leaves = leafIds(host.debugPaneTree);
        expect(leaves, hasLength(1));
        expect(host.debugPaneSessions[leaves.single], isEmpty);
      },
    );
  });

  // Regression coverage for pane-scoped closeOtherTerms/closeTermsToLeft/
  // closeTermsToRight (and their View siblings): before this fix these bulk
  // actions reasoned about the *global* terms list/index, so a "close
  // others/left/right" fired from one split pane's tab strip could reach
  // into a sibling pane's sessions whenever their global indices happened to
  // fall in the wrong direction. Deliberately split off a session at a
  // *lower* global index than the pane under test, so a naive
  // index-comparison implementation would wrongly sweep it up.
  group('bulk close is scoped to the acting tab\'s own pane', () {
    testWidgets('closeOtherTerms leaves a sibling pane fully untouched', (
      tester,
    ) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(_Host(key: key));
      final host = key.currentState!;
      final s1 = _plainSession();
      final s2 = _plainSession();
      final s3 = _plainSession();
      final s4 = _plainSession();
      addTearDown(s1.dispose);
      addTearDown(s3.dispose);
      host.terms.addAll([s1, s2, s3, s4]);
      for (final s in host.terms) {
        host.debugAssignSessionToPane(s.id);
      }
      host.splitTermRight(0); // s1 -> its own pane; root becomes [s2, s3, s4]
      _settleAll(host);
      await tester.pump();
      expect(host.debugPaneSessions['root'], [s2.id, s3.id, s4.id]);

      host.closeOtherTerms(host.terms.indexOf(s3)); // keep s3, within root
      _settleAll(host);
      await tester.pump();

      // s2/s4 (root's own siblings) are gone; s1, split off into its own
      // pane, must survive even though "close others" ran elsewhere.
      final remaining = host.terms.map((s) => s.id).toSet();
      expect(remaining, {s1.id, s3.id});
      expect(host.debugPaneSessions['root'], [s3.id]);
    });

    testWidgets(
      'closeTermsToLeft does not reach into a pane split off at a lower global index',
      (tester) async {
        final key = GlobalKey<_HostState>();
        await tester.pumpWidget(_Host(key: key));
        final host = key.currentState!;
        final s1 = _plainSession();
        final s2 = _plainSession();
        final s3 = _plainSession();
        final s4 = _plainSession();
        addTearDown(s1.dispose);
        addTearDown(s3.dispose);
        addTearDown(s4.dispose);
        host.terms.addAll([s1, s2, s3, s4]);
        for (final s in host.terms) {
          host.debugAssignSessionToPane(s.id);
        }
        host.splitTermRight(0); // s1 -> its own pane; root becomes [s2, s3, s4]
        _settleAll(host);
        await tester.pump();

        // s3 sits at global index 2, position 1 within root's own ordering.
        host.closeTermsToLeft(host.terms.indexOf(s3));
        _settleAll(host);
        await tester.pump();

        // Only s2 (root's own tab to s3's left) is gone. s1 — global index 0,
        // numerically "to the left" of s3 — lives in a different pane and
        // must survive: exactly the cross-pane bug this scoping guards.
        final remaining = host.terms.map((s) => s.id).toSet();
        expect(remaining, {s1.id, s3.id, s4.id});
      },
    );

    testWidgets(
      'closeTermsToRight does not reach into a pane split off at a higher global index',
      (tester) async {
        final key = GlobalKey<_HostState>();
        await tester.pumpWidget(_Host(key: key));
        final host = key.currentState!;
        final s1 = _plainSession();
        final s2 = _plainSession();
        final s3 = _plainSession();
        final s4 = _plainSession();
        addTearDown(s1.dispose);
        addTearDown(s2.dispose);
        addTearDown(s4.dispose);
        host.terms.addAll([s1, s2, s3, s4]);
        for (final s in host.terms) {
          host.debugAssignSessionToPane(s.id);
        }
        host.splitTermRight(3); // s4 -> its own pane; root becomes [s1, s2, s3]
        _settleAll(host);
        await tester.pump();

        // s2 sits at global index 1, position 1 within root's own ordering.
        host.closeTermsToRight(host.terms.indexOf(s2));
        _settleAll(host);
        await tester.pump();

        // Only s3 (root's own tab to s2's right) is gone. s4 — global index
        // 3, numerically "to the right" of s2 — lives in a different pane
        // and must survive.
        final remaining = host.terms.map((s) => s.id).toSet();
        expect(remaining, {s1.id, s2.id, s4.id});
      },
    );

    testWidgets(
      'closeOtherTermsView hides only the acting tab\'s own pane siblings',
      (tester) async {
        final key = GlobalKey<_HostState>();
        await tester.pumpWidget(_Host(key: key));
        final host = key.currentState!;
        final s1 = _plainSession();
        final s2 = _plainSession();
        final s3 = _plainSession();
        addTearDown(s1.dispose);
        addTearDown(s2.dispose);
        addTearDown(s3.dispose);
        host.terms.addAll([s1, s2, s3]);
        for (final s in host.terms) {
          host.debugAssignSessionToPane(s.id);
        }
        host.splitTermRight(0); // s1 -> its own pane; root becomes [s2, s3]
        _settleAll(host);
        await tester.pump();

        host.closeOtherTermsView(host.terms.indexOf(s2)); // keep s2, in root
        _settleAll(host);
        await tester.pump();

        expect(host.isTabHidden(s3.id), isTrue);
        expect(host.isTabHidden(s2.id), isFalse);
        expect(host.isTabHidden(s1.id), isFalse); // different pane, untouched
        expect(host.terms, hasLength(3)); // hide-only: nobody actually closed
      },
    );
  });
}
