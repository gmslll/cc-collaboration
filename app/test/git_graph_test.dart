import 'package:app/local/git.dart';
import 'package:app/screens/workspace/git_graph.dart';
import 'package:flutter_test/flutter_test.dart';

GitCommit _c(String hash, List<String> parents) => GitCommit(
  hash: hash,
  shortHash: hash,
  author: 'gms',
  date: DateTime(2026, 1, 1),
  subject: 'commit $hash',
  refs: '',
  parents: parents,
);

void main() {
  group('computeGraphRows', () {
    test('linear history with one merge', () {
      // A -> B(merge of C,D) ; C -> E ; D -> E ; E root
      final commits = [
        _c('A', ['B']),
        _c('B', ['C', 'D']),
        _c('C', ['E']),
        _c('D', ['E']),
        _c('E', const []),
      ];
      final layout = computeGraphRows(commits);

      expect(layout.rows.length, 5);
      expect(layout.laneCount, 2);

      final a = layout.rows[0];
      final b = layout.rows[1];
      final c = layout.rows[2];
      final d = layout.rows[3];
      final e = layout.rows[4];

      // Only B is a merge.
      expect([a, b, c, d, e].map((r) => r.isMerge).toList(), [
        false,
        true,
        false,
        false,
        false,
      ]);

      // Dot lanes: A=0, B=0, C=0, D peels off to lane 1, E converges back to 0.
      expect(a.dotLane, 0);
      expect(b.dotLane, 0);
      expect(c.dotLane, 0);
      expect(d.dotLane, 1);
      expect(e.dotLane, 0);

      // B fans out to a second lane (the feature parent D).
      expect(
        b.edges.where((x) => x.kind == EdgeKind.fromDot && x.toLane == 1).length,
        1,
      );

      // C carries a pass-through for lane 1 (the open feature lane).
      expect(c.edges.any((x) => x.kind == EdgeKind.pass && x.fromLane == 1), true);

      // E is where lanes 0 and 1 converge into the root dot.
      final toDotLanes =
          e.edges.where((x) => x.kind == EdgeKind.toDot).map((x) => x.fromLane).toSet();
      expect(toDotLanes, {0, 1});
    });

    test('dangling parent terminates as a short stub, not a persistent lane', () {
      // Only the top two commits are loaded; X's parent Z is out of window.
      final commits = [
        _c('A', ['X']),
        _c('X', ['Z']), // Z dangling
      ];
      final layout = computeGraphRows(commits);
      expect(layout.rows.length, 2);
      // X's only parent is out of window -> a short stub, and no extra lane is
      // held open (this is what keeps the rail from growing ghost verticals).
      expect(layout.rows[1].edges.any((e) => e.kind == EdgeKind.stub), true);
      expect(layout.laneCount, 1);
    });

    test('multiple roots each terminate their own lane', () {
      final commits = [
        _c('A', const []),
        _c('B', const []),
      ];
      final layout = computeGraphRows(commits);
      expect(layout.rows.length, 2);
      // Two independent roots => no merge, distinct rows, lane count >= 1.
      expect(layout.rows.every((r) => !r.isMerge), true);
    });
  });
}
