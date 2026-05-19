package linear

import (
	"cmp"
	"fmt"

	"github.com/cc-collaboration/internal/notify"
)

// ToNotify renders one Linear notification into the cross-platform
// desktop-notify payload. Title shows in the alert banner; subtitle and body
// give context. Used by both the watch poller and the linear-sync CLI so
// notifications look identical regardless of which trigger surfaced them.
func ToNotify(n Notification) notify.Notification {
	return notify.Notification{
		Title:    fmt.Sprintf("Linear: %s in %s", n.ActorName, n.IssueIdent),
		Subtitle: n.IssueTitle,
		Body:     cmp.Or(n.Snippet, n.IssueTitle),
	}
}
