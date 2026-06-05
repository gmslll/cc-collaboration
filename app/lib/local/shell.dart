// Shared POSIX-shell quoting for the helpers that shell out via the user's login
// shell (git, the cc-handoff CLI). shEsc escapes a value for use inside single
// quotes; shQuote wraps it as one single-quoted argument.
String shEsc(String s) => s.replaceAll("'", r"'\''");

String shQuote(String s) => "'${shEsc(s)}'";
