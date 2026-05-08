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

// posixCompose builds `cd '<cwd>' [&& <preLaunch>] && <invocation>`. Shared
// by all POSIX agent adapters so pre-launch insertion stays uniform.
func posixCompose(cwd, preLaunch, invocation string) string {
	parts := []string{"cd " + POSIXSingleQuote(cwd)}
	if preLaunch != "" {
		parts = append(parts, preLaunch)
	}
	parts = append(parts, invocation)
	return strings.Join(parts, " && ")
}

// psCompose is the PowerShell counterpart of posixCompose, using `;` as the
// statement separator (PowerShell's `&&` was 7+; we keep `;` for portability).
func psCompose(cwd, preLaunch, invocation string) string {
	parts := []string{"Set-Location -LiteralPath " + PSSingleQuote(cwd)}
	if preLaunch != "" {
		parts = append(parts, preLaunch)
	}
	parts = append(parts, invocation)
	return strings.Join(parts, "; ")
}
