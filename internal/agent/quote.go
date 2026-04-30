package agent

import "strings"

// POSIXSingleQuote wraps s in single quotes, escaping embedded single quotes
// using the POSIX idiom '\”. Used by darwin's Terminal.app/iTerm2 launcher,
// which feeds bash-style commands through osascript.
func POSIXSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// PSSingleQuote wraps s in a PowerShell single-quoted literal, escaping
// embedded single quotes by doubling them — PowerShell's only escape rule
// inside single-quoted strings. Used by the Windows cmd /c start launcher
// when feeding a PowerShell -Command argument.
func PSSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}
