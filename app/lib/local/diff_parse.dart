// Parsing for the GoLand-style diff viewer: a unified diff (git diff output, or
// a GitHub PR file patch) → per-file metadata + aligned side-by-side rows.

enum DiffKind { context, added, removed, empty }

// A side-by-side diff row: either a hunk header (full width) or a paired
// old/new line. For a changed block, removed lines pair with added lines
// position-by-position; the shorter side is padded with empty cells.
class DiffRow {
  final bool isHunk;
  final String hunkText;
  final int? oldNo;
  final int? newNo;
  final String left;
  final DiffKind leftKind;
  final String right;
  final DiffKind rightKind;

  const DiffRow.line({
    this.oldNo,
    this.newNo,
    this.left = '',
    this.leftKind = DiffKind.empty,
    this.right = '',
    this.rightKind = DiffKind.empty,
  })  : isHunk = false,
        hunkText = '';

  const DiffRow.hunk(this.hunkText)
      : isHunk = true,
        oldNo = null,
        newNo = null,
        left = '',
        leftKind = DiffKind.empty,
        right = '',
        rightKind = DiffKind.empty;
}

// One changed file: path + status + add/del counts + its raw unified-diff text
// (used directly for the "unified" view; parsed into rows for "split").
class FileDiff {
  final String path;
  final String status; // modified / added / deleted / renamed
  final int adds;
  final int dels;
  final String raw;
  const FileDiff(this.path, this.status, this.adds, this.dels, this.raw);
}

// parseUnifiedDiff splits a full `git diff` into per-file FileDiffs (by the
// `diff --git` markers), pulling path/status/+−counts and keeping the raw block.
List<FileDiff> parseUnifiedDiff(String diff) {
  final lines = diff.split('\n');
  final files = <FileDiff>[];
  var i = 0;
  while (i < lines.length) {
    if (!lines[i].startsWith('diff --git ')) {
      i++;
      continue;
    }
    final start = i;
    i++;
    while (i < lines.length && !lines[i].startsWith('diff --git ')) {
      i++;
    }
    files.add(_fileFromBlock(lines.sublist(start, i)));
  }
  return files;
}

FileDiff _fileFromBlock(List<String> block) {
  var status = 'modified';
  String? oldPath, newPath;
  var adds = 0, dels = 0;
  for (final l in block) {
    if (l.startsWith('new file')) {
      status = 'added';
    } else if (l.startsWith('deleted file')) {
      status = 'deleted';
    } else if (l.startsWith('rename ')) {
      status = 'renamed';
    } else if (l.startsWith('--- ')) {
      oldPath = _strip(l.substring(4));
    } else if (l.startsWith('+++ ')) {
      newPath = _strip(l.substring(4));
    } else if (l.startsWith('+') && !l.startsWith('+++')) {
      adds++;
    } else if (l.startsWith('-') && !l.startsWith('---')) {
      dels++;
    }
  }
  var path = (newPath != null && newPath != '/dev/null') ? newPath : oldPath;
  if (path == null || path == '/dev/null') {
    final m = RegExp(r'^diff --git a/(.+) b/(.+)$').firstMatch(block.first);
    if (m != null) path = m.group(2);
  }
  return FileDiff(path ?? '?', status, adds, dels, block.join('\n'));
}

String _strip(String p) {
  p = p.trim();
  if (p == '/dev/null') return p;
  return (p.startsWith('a/') || p.startsWith('b/')) ? p.substring(2) : p;
}

// parseRows turns a unified diff/patch into aligned side-by-side rows. The
// removed/added pairing is for the split view specifically (the unified view
// renders `raw` directly); if other pairing strategies appear, move this into
// the widget. A file with no hunks (rename/mode-only) yields no line rows.
List<DiffRow> parseRows(String raw) {
  final rows = <DiffRow>[];
  var oldNo = 0, newNo = 0;
  final removed = <(int, String)>[];
  final added = <(int, String)>[];

  void flush() {
    final n = removed.length > added.length ? removed.length : added.length;
    for (var k = 0; k < n; k++) {
      final r = k < removed.length ? removed[k] : null;
      final a = k < added.length ? added[k] : null;
      rows.add(DiffRow.line(
        oldNo: r?.$1,
        left: r?.$2 ?? '',
        leftKind: r != null ? DiffKind.removed : DiffKind.empty,
        newNo: a?.$1,
        right: a?.$2 ?? '',
        rightKind: a != null ? DiffKind.added : DiffKind.empty,
      ));
    }
    removed.clear();
    added.clear();
  }

  for (final line in raw.split('\n')) {
    if (line.startsWith('@@')) {
      flush();
      final m =
          RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@').firstMatch(line);
      if (m != null) {
        oldNo = int.parse(m.group(1)!);
        newNo = int.parse(m.group(2)!);
      }
      rows.add(DiffRow.hunk(line));
    } else if (line.startsWith('+') && !line.startsWith('+++')) {
      added.add((newNo, line.substring(1)));
      newNo++;
    } else if (line.startsWith('-') && !line.startsWith('---')) {
      removed.add((oldNo, line.substring(1)));
      oldNo++;
    } else if (line.startsWith(' ')) {
      flush();
      final text = line.substring(1);
      rows.add(DiffRow.line(
        oldNo: oldNo,
        left: text,
        leftKind: DiffKind.context,
        newNo: newNo,
        right: text,
        rightKind: DiffKind.context,
      ));
      oldNo++;
      newNo++;
    }
    // else: file headers (diff/index/---/+++), "\ No newline", or the trailing
    // empty line from split — skip.
  }
  flush();
  return rows;
}
