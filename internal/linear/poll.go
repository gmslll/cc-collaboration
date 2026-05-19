package linear

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// DefaultNotificationTypes filters notifications to the @-mention subset by
// default. Override via [integrations.linear.notifications].types when the
// user wants assignment / status-change / new-comment events too.
var DefaultNotificationTypes = []string{"issueMention", "issueCommentMention"}

// Notification is the shape consumed by the desktop-notify code and by the
// MCP/CLI markdown renderer. Only the fields the UI actually reads are kept;
// the raw GraphQL payload has many more.
type Notification struct {
	ID         string
	Type       string
	CreatedAt  time.Time
	IssueIdent string
	IssueTitle string
	IssueURL   string
	ActorName  string
	Snippet    string
}

const pollQuery = `
query CCHandoffPolling($since: DateTime, $types: [String!]) {
  notifications(
    filter: { createdAt: { gt: $since }, type: { in: $types } }
    first: 50
  ) {
    nodes {
      id
      type
      createdAt
      issue { identifier title url }
      actor { name }
      comment { body }
    }
  }
}
`

type pollResponse struct {
	Notifications struct {
		Nodes []notificationNode `json:"nodes"`
	} `json:"notifications"`
}

type notificationNode struct {
	ID        string    `json:"id"`
	Type      string    `json:"type"`
	CreatedAt time.Time `json:"createdAt"`
	Issue     *struct {
		Identifier string `json:"identifier"`
		Title      string `json:"title"`
		URL        string `json:"url"`
	} `json:"issue"`
	Actor *struct {
		Name string `json:"name"`
	} `json:"actor"`
	Comment *struct {
		Body string `json:"body"`
	} `json:"comment"`
}

// PollOnce fetches notifications created strictly after `since`, filtered by
// `types`. A zero `since` means "use the current time as baseline" — the
// caller should persist `newCursor` even when items is empty so subsequent
// polls don't replay history. `types` defaults to DefaultNotificationTypes
// when nil/empty.
func PollOnce(ctx context.Context, c *Client, since time.Time, types []string) (items []Notification, newCursor time.Time, err error) {
	if len(types) == 0 {
		types = DefaultNotificationTypes
	}
	cursor := since
	if cursor.IsZero() {
		cursor = time.Now().UTC()
	}
	vars := map[string]any{
		"since": cursor.UTC().Format(time.RFC3339Nano),
		"types": types,
	}
	raw, err := c.Query(ctx, pollQuery, vars)
	if err != nil {
		return nil, since, err
	}
	var resp pollResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, since, fmt.Errorf("decode notifications: %w", err)
	}
	out := make([]Notification, 0, len(resp.Notifications.Nodes))
	maxCursor := cursor
	for _, n := range resp.Notifications.Nodes {
		item := Notification{
			ID:        n.ID,
			Type:      n.Type,
			CreatedAt: n.CreatedAt,
		}
		if n.Issue != nil {
			item.IssueIdent = n.Issue.Identifier
			item.IssueTitle = n.Issue.Title
			item.IssueURL = n.Issue.URL
		}
		if n.Actor != nil {
			item.ActorName = n.Actor.Name
		}
		if n.Comment != nil {
			item.Snippet = snippet(n.Comment.Body, 140)
		}
		out = append(out, item)
		if n.CreatedAt.After(maxCursor) {
			maxCursor = n.CreatedAt
		}
	}
	return out, maxCursor, nil
}

func snippet(s string, max int) string {
	s = strings.TrimSpace(strings.ReplaceAll(s, "\n", " "))
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}
