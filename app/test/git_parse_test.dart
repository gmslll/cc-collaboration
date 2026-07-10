import 'package:app/local/git.dart';
import 'package:app/screens/workspace/git_graph.dart';
import 'package:flutter_test/flutter_test.dart';

// Builds one `git log --pretty=format:%H%x1f%h%x1f%an%x1f%ad%x1f%D%x1f%P%x1f%s%x00`
// record (fields joined by \x1f, terminated by \x00).
String _rec(String hash, String parent) {
  final fields = [
    hash, // %H
    hash.substring(0, 7), // %h
    'gms', // %an
    '2026-06-26T15:00:00+08:00', // %ad
    '', // %D refs
    parent, // %P
    'subject for $hash', // %s
  ].join('\x1f');
  return '$fields\x00';
}

void main() {
  final a = 'a' * 40;
  final b = 'b' * 40;
  final c = 'c' * 40;

  // Real git joins per-commit output with '\n'. So the on-the-wire stream is
  // `recA\x00\nrecB\x00\nrecC\x00` — every record after the first is preceded by
  // a newline. This is the exact shape that used to leak '\n' into the hash.
  final out = '${_rec(a, b)}\n${_rec(b, c)}\n${_rec(c, '')}';

  test('parseGitLog strips the inter-record newline from the hash', () {
    final commits = parseGitLog(out);
    expect(commits.length, 3);

    // The regression: commits[1]/[2] must NOT carry a leading '\n' in the hash.
    expect(commits[0].hash, a);
    expect(commits[1].hash, b);
    expect(commits[2].hash, c);
    for (final commit in commits) {
      expect(
        commit.hash.trim(),
        commit.hash,
        reason: 'hash has stray whitespace',
      );
      expect(commit.hash.startsWith('\n'), isFalse);
    }

    // Parents parsed, and they actually line up with the next commit's hash
    // (so present.contains(parent) can connect the topology).
    expect(commits[0].parents, [b]);
    expect(commits[1].parents, [c]);
    expect(commits[2].parents, isEmpty);
    expect(commits[0].parents.first, commits[1].hash);
  });

  test('parsed commits produce connecting edges (not just stubs)', () {
    final layout = computeGraphRows(parseGitLog(out));
    final kinds = layout.rows.expand((r) => r.edges).map((e) => e.kind).toSet();
    // Linear A->B->C must yield real cross-row connectors, not only stubs.
    expect(kinds.contains(EdgeKind.fromDot), isTrue);
    expect(kinds.contains(EdgeKind.toDot), isTrue);
    expect(layout.laneCount, 1); // all on one lane
  });

  test('GitStatusSummary exposes precise bulk action availability', () {
    const clean = GitStatusSummary(
      branch: 'main',
      staged: 0,
      modified: 0,
      untracked: 0,
      conflicted: 0,
      ahead: 0,
      behind: 0,
    );
    expect(clean.hasStageableChanges, isFalse);
    expect(clean.hasStagedChanges, isFalse);
    expect(clean.hasAnyChanges, isFalse);

    const unstaged = GitStatusSummary(
      branch: 'main',
      staged: 0,
      modified: 1,
      untracked: 1,
      conflicted: 0,
      ahead: 0,
      behind: 0,
    );
    expect(unstaged.hasStageableChanges, isTrue);
    expect(unstaged.hasStagedChanges, isFalse);
    expect(unstaged.hasAnyChanges, isTrue);

    const staged = GitStatusSummary(
      branch: 'main',
      staged: 2,
      modified: 0,
      untracked: 0,
      conflicted: 0,
      ahead: 0,
      behind: 0,
    );
    expect(staged.hasStageableChanges, isFalse);
    expect(staged.hasStagedChanges, isTrue);
    expect(staged.hasAnyChanges, isTrue);
  });
}
