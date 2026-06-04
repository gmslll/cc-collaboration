package main

import (
	"context"
	"fmt"
	"os"
	"regexp"
	"strings"
)

// gradePromptPrefix is prepended to the error excerpt before it's piped to the
// grader. Kept terse so small local models stay on-task and reply with a single
// word.
const gradePromptPrefix = "You are a log triage assistant. Rate the severity of the error below as exactly one of: critical, high, medium, low. Reply with only that one word.\n\n"

// severityRe matches the first severity word in a (possibly chatty) grader
// reply.
var severityRe = regexp.MustCompile(`(?i)\b(critical|high|medium|low)\b`)

// gradeSeverity runs the configured local-AI grader on errorText and returns
// the severity it reports (critical/high/medium/low), or "" when grading is
// unconfigured, the command fails, or no level is found. Best-effort: a grading
// failure prints a warning and degrades to no level rather than failing the
// caller.
func gradeSeverity(ctx context.Context, gradeCommand, errorText string) string {
	if strings.TrimSpace(gradeCommand) == "" {
		return ""
	}
	name, args := localShell(gradeCommand)
	out, err := runCaptureIn(ctx, strings.NewReader(gradePromptPrefix+errorText), name, args...)
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: grade command failed: %v\n", err)
		return ""
	}
	return parseSeverity(out)
}

// parseSeverity extracts the first severity word from a grader reply, lowercased.
// Returns "" when none is present. Pure — unit-tested against chatty output.
func parseSeverity(out string) string {
	return strings.ToLower(severityRe.FindString(out))
}
