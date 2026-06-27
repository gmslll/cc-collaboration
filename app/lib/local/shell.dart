// Shared POSIX-shell quoting for the helpers that shell out via the user's login
// shell (git, the cc-handoff CLI). shEsc escapes a value for use inside single
// quotes; shQuote wraps it as one single-quoted argument.
String shEsc(String s) => s.replaceAll("'", r"'\''");

String shQuote(String s) => "'${shEsc(s)}'";

/// splitPosixCommand reverses the (single/double-)quoted command strings the git
/// helpers build via [shQuote] back into an argv list, so they can be run
/// directly with Process.run on Windows — which has no POSIX shell, and where
/// handing the string to cmd.exe would mangle the quotes and swallow git's exit
/// code. It handles space/tab separation, '...'/"..." literal grouping (with
/// shell-style concatenation of adjacent segments, e.g. `'a'...'b'` → `a...b`),
/// and backslash escapes outside quotes (shQuote emits `'\''` for an embedded
/// quote). It is NOT a general shell parser: it only needs to cover what shQuote
/// plus the static git fragments emit (no $/backtick expansion, no globbing).
List<String> splitPosixCommand(String s) {
  final out = <String>[];
  final buf = StringBuffer();
  var inWord = false;
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == ' ' || c == '\t') {
      if (inWord) {
        out.add(buf.toString());
        buf.clear();
        inWord = false;
      }
      i++;
      continue;
    }
    inWord = true;
    if (c == "'" || c == '"') {
      final quote = c;
      i++;
      while (i < s.length && s[i] != quote) {
        buf.write(s[i]);
        i++;
      }
      i++; // skip the closing quote
    } else if (c == r'\' && i + 1 < s.length) {
      buf.write(s[i + 1]); // backslash escapes the next char (shQuote's `'\''`)
      i += 2;
    } else {
      buf.write(c);
      i++;
    }
  }
  if (inWord) out.add(buf.toString());
  return out;
}
