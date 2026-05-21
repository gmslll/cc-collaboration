package desktop

import (
	"fmt"
	"strings"
	"time"

	"github.com/cc-collaboration/pkg/handoffschema"
)

func viewTitle(v string) string {
	switch v {
	case viewSent:
		return "Sent"
	case viewHistory:
		return "History"
	default:
		return "Inbox"
	}
}

func formatRow(it handoffschema.ListItem) string {
	headline := it.Headline
	if headline == "" {
		headline = "(no headline)"
	}
	kind := string(it.Kind)
	if kind == "" {
		kind = "delivery"
	}
	state := string(it.State)
	if state == "" {
		state = "pending"
	}
	return fmt.Sprintf("[%s] %s — %s (%s, %s)", nonEmpty(it.Sender, "?"), headline, kind, state, formatTime(it.CreatedAt))
}

func haystack(it handoffschema.ListItem) string {
	parts := []string{
		it.ID,
		it.Sender,
		it.Recipient,
		it.RepoName,
		it.Branch,
		it.Headline,
		string(it.Kind),
		string(it.State),
	}
	parts = append(parts, it.Recipients...)
	return strings.ToLower(strings.Join(parts, " "))
}

func recipientsFromPackage(pkg *handoffschema.Package) []string {
	if pkg == nil {
		return nil
	}
	if len(pkg.Recipients) > 0 {
		return pkg.Recipients
	}
	if pkg.Recipient != "" {
		return []string{pkg.Recipient}
	}
	return nil
}

func formatTime(t time.Time) string {
	if t.IsZero() {
		return "-"
	}
	return t.Local().Format("Jan 02 15:04")
}

func formatBytes(n int) string {
	switch {
	case n < 1024:
		return fmt.Sprintf("%d B", n)
	case n < 1024*1024:
		return fmt.Sprintf("%.1f KB", float64(n)/1024)
	default:
		return fmt.Sprintf("%.1f MB", float64(n)/(1024*1024))
	}
}

func firstLine(s string) string {
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return strings.TrimSpace(s)
}

func nonEmpty(s, fallback string) string {
	if strings.TrimSpace(s) == "" {
		return fallback
	}
	return s
}
