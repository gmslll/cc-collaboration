//go:build darwin

package notify

import (
	"context"
	"os/exec"
	"strings"
)

// Show displays a macOS Notification Center banner. Returns an error only if
// osascript itself fails; if the user has banners suppressed the call still
// succeeds silently.
func Show(ctx context.Context, n Notification) error {
	script := buildAppleScript(n)
	return exec.CommandContext(ctx, "osascript", "-e", script).Run()
}

func buildAppleScript(n Notification) string {
	var sb strings.Builder
	sb.WriteString("display notification ")
	sb.WriteString(quote(n.Body))
	if n.Title != "" {
		sb.WriteString(" with title ")
		sb.WriteString(quote(n.Title))
	}
	if n.Subtitle != "" {
		sb.WriteString(" subtitle ")
		sb.WriteString(quote(n.Subtitle))
	}
	return sb.String()
}

// quote AppleScript-quotes a string by replacing `"` with `\"` and `\` with `\\`.
func quote(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`)
	return `"` + r.Replace(s) + `"`
}
