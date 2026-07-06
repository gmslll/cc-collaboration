// Per-word diff for the GoLand-style "Highlight words" behavior: given the old
// and new text of a changed line, it returns which character ranges on each
// side are unchanged vs. changed, so the diff viewer can box only the words
// that actually differ instead of tinting the whole line. Pure Dart, zero
// Flutter dependency — the rendering side (applyDiffBackground in syntax.dart)
// turns these spans into background colors.

// WordDiffKind labels a span: [equal] text is present on both sides unchanged;
// [diff] text was removed (old side) or added (new side).
enum WordDiffKind { equal, diff }

// WordDiffSpan is a half-open character range [start, end) on one side of the
// line, with its kind. Offsets are into that side's line string (not token
// indices). A side's spans always cover [0, line.length) with no gaps.
class WordDiffSpan {
  final int start, end;
  final WordDiffKind kind;
  const WordDiffSpan(this.start, this.end, this.kind);
}

// The two aligned span lists — oldSpans covers the removed line, newSpans the
// added line. Each strictly, seamlessly covers its side's full length.
typedef WordDiffResult = ({List<WordDiffSpan> oldSpans, List<WordDiffSpan> newSpans});

// _Op is one step of the LCS alignment between the two token sequences.
enum _Op { equal, removed, added }

// A tokenizer match: the token text plus its [start, end) offset in the line.
class _Tok {
  final int start, end;
  const _Tok(this.start, this.end);
}

// Tokenize into runs of word chars (\w+, i.e. ASCII letters/digits/underscore)
// and runs of non-word chars (\W+, punctuation/whitespace). Identifiers and
// numbers stay whole so a changed identifier highlights as one unit, matching
// GoLand — not letter-by-letter. Known limitation: \w is ASCII-only, so a run
// of CJK text lands in one coarse \W token; acceptable (no Unicode segmenter).
final _tokenRe = RegExp(r'\w+|\W+');

List<_Tok> _tokenize(String line) => [
      for (final m in _tokenRe.allMatches(line)) _Tok(m.start, m.end),
    ];

// Memoize by (oldLine, newLine) so per-frame rebuilds don't re-run the DP.
// Mirrors syntax.dart's _spanCache (bounded, cleared wholesale when large).
// Null results (fallbacks) are cached too, so we don't recompute them.
final Map<String, WordDiffResult?> _cache = {};

// diffWords aligns [oldLine] and [newLine] token-by-token and returns the
// per-side equal/diff spans, or null to fall back to a plain whole-line tint:
//   * identical lines (nothing to diff),
//   * too dissimilar (Dice similarity < 0.25 — a near-total rewrite, where
//     scattered word highlights would be noise; GoLand skips these too),
//   * pathologically large token products (DP guard).
// The caller treats null as "no per-word highlight for this row".
WordDiffResult? diffWords(String oldLine, String newLine) {
  if (oldLine == newLine) return null;
  final key = '$oldLine\n$newLine';
  if (_cache.containsKey(key)) return _cache[key];

  final result = _compute(oldLine, newLine);
  if (_cache.length > 4000) _cache.clear();
  _cache[key] = result;
  return result;
}

WordDiffResult? _compute(String oldLine, String newLine) {
  final oldToks = _tokenize(oldLine);
  final newToks = _tokenize(newLine);
  final n = oldToks.length, m = newToks.length;
  // Pathological-input guard: skip the O(n·m) DP for absurd token counts.
  if (n * m > 200000) return null;

  final ops = _lcsOps(oldLine, newLine, oldToks, newToks);

  // Dice similarity over tokens: too little in common → a rewrite, bail out.
  var commonCount = 0;
  for (final op in ops) {
    if (op == _Op.equal) commonCount++;
  }
  final denom = n + m;
  if (denom == 0) return null;
  final ratio = 2 * commonCount / denom;
  if (ratio < 0.25) return null;

  // Walk the op sequence, assigning each token a per-token span on its side,
  // then coalesce runs of the same kind. Because tokens are consumed in order
  // and the tokenizer leaves no gaps, the coalesced spans seamlessly cover
  // [0, line.length) on each side.
  final oldUnits = <WordDiffSpan>[];
  final newUnits = <WordDiffSpan>[];
  var oi = 0, ni = 0;
  for (final op in ops) {
    switch (op) {
      case _Op.equal:
        oldUnits.add(WordDiffSpan(oldToks[oi].start, oldToks[oi].end, WordDiffKind.equal));
        newUnits.add(WordDiffSpan(newToks[ni].start, newToks[ni].end, WordDiffKind.equal));
        oi++;
        ni++;
      case _Op.removed:
        oldUnits.add(WordDiffSpan(oldToks[oi].start, oldToks[oi].end, WordDiffKind.diff));
        oi++;
      case _Op.added:
        newUnits.add(WordDiffSpan(newToks[ni].start, newToks[ni].end, WordDiffKind.diff));
        ni++;
    }
  }

  return (
    oldSpans: _coalesce(oldUnits, oldLine.length),
    newSpans: _coalesce(newUnits, newLine.length),
  );
}

// _lcsOps computes a longest-common-subsequence alignment of the two token
// sequences via a standard suffix DP (dp[i][j] = LCS length of a[i:], b[j:]),
// then walks forward from (0,0) emitting equal/removed/added ops. O(n·m) time
// and space; fine for single lines (tens of tokens), no need for Myers.
List<_Op> _lcsOps(String a, String b, List<_Tok> at, List<_Tok> bt) {
  final n = at.length, m = bt.length;
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      if (_tokEq(a, at[i], b, bt[j])) {
        dp[i][j] = dp[i + 1][j + 1] + 1;
      } else {
        dp[i][j] = dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1];
      }
    }
  }
  final ops = <_Op>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (_tokEq(a, at[i], b, bt[j])) {
      ops.add(_Op.equal);
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      ops.add(_Op.removed);
      i++;
    } else {
      ops.add(_Op.added);
      j++;
    }
  }
  while (i < n) {
    ops.add(_Op.removed);
    i++;
  }
  while (j < m) {
    ops.add(_Op.added);
    j++;
  }
  return ops;
}

// Token equality by substring — avoids materializing token strings up front.
bool _tokEq(String a, _Tok ta, String b, _Tok tb) {
  final la = ta.end - ta.start;
  if (la != tb.end - tb.start) return false;
  for (var k = 0; k < la; k++) {
    if (a.codeUnitAt(ta.start + k) != b.codeUnitAt(tb.start + k)) return false;
  }
  return true;
}

// _coalesce merges consecutive same-kind per-token spans into maximal spans.
// [units] are already in order and adjacent (token[i].end == token[i+1].start),
// so the result seamlessly covers [0, lineLen). Empty input (a blank side)
// yields a single empty equal span, but such rows fail the similarity gate.
List<WordDiffSpan> _coalesce(List<WordDiffSpan> units, int lineLen) {
  if (units.isEmpty) return [WordDiffSpan(0, lineLen, WordDiffKind.equal)];
  final out = <WordDiffSpan>[];
  var start = units.first.start;
  var end = units.first.end;
  var kind = units.first.kind;
  for (var i = 1; i < units.length; i++) {
    final u = units[i];
    if (u.kind == kind) {
      end = u.end;
    } else {
      out.add(WordDiffSpan(start, end, kind));
      start = u.start;
      end = u.end;
      kind = u.kind;
    }
  }
  out.add(WordDiffSpan(start, end, kind));
  return out;
}
