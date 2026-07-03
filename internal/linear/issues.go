package linear

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

// Issue is the shape GetTeamIssues surfaces for one Linear issue — unlike
// Notification (poll.go), which only carries enough to render a desktop
// ping, this carries full issue content for the todo-import flow (see
// internal/linear/import.go).
type Issue struct {
	Identifier  string // e.g. "ENG-456"
	URL         string
	Title       string
	Description string // Markdown — Linear's native format, so it round-trips into body_md as-is.
	StateName   string
	// StateType is Linear's coarse workflow bucket: backlog | unstarted |
	// started | completed | canceled. See mapIssueStatus (import.go) for how
	// this maps onto todoschema.Status.
	StateType string
	// Priority is Linear's own 0-4 scale: 0=no priority, 1=urgent, 2=high,
	// 3=medium, 4=low (NOT a plain ascending low→high scale — see
	// mapIssuePriority in import.go).
	Priority      int
	AssigneeEmail string
	Labels        []string
	DueDate       *time.Time
}

// teamIssuesQuery filters to a single team by its short key (e.g. "ENG").
// projectIssuesQuery further narrows the source to one Linear project UUID.
// Both pull the fields the todo-import flow maps onto a todoschema.Todo.
// Capped at a single page of 250 — good enough for "keep re-running import to
// stay in sync"; a team with more open+closed issues than that would need a
// follow-up cursor loop (out of scope for now, same tradeoff pollQuery in
// poll.go makes with first: 50).
const teamIssuesQuery = `
query CCHandoffTeamIssues($teamKey: String!) {
  issues(filter: { team: { key: { eq: $teamKey } } }, first: 250, orderBy: updatedAt) {
    nodes {
      identifier
      url
      title
      description
      state { name type }
      priority
      assignee { email }
      labels { nodes { name } }
      dueDate
    }
  }
}
`

const projectIssuesQuery = `
query CCHandoffProjectIssues($teamKey: String!, $projectID: String!) {
  issues(filter: { team: { key: { eq: $teamKey } }, project: { id: { eq: $projectID } } }, first: 250, orderBy: updatedAt) {
    nodes {
      identifier
      url
      title
      description
      state { name type }
      priority
      assignee { email }
      labels { nodes { name } }
      dueDate
    }
  }
}
`

type teamIssuesResponse struct {
	Issues struct {
		Nodes []issueNode `json:"nodes"`
	} `json:"issues"`
}

type issueNode struct {
	Identifier  string `json:"identifier"`
	URL         string `json:"url"`
	Title       string `json:"title"`
	Description string `json:"description"`
	State       *struct {
		Name string `json:"name"`
		Type string `json:"type"`
	} `json:"state"`
	Priority int `json:"priority"`
	Assignee *struct {
		Email string `json:"email"`
	} `json:"assignee"`
	Labels struct {
		Nodes []struct {
			Name string `json:"name"`
		} `json:"nodes"`
	} `json:"labels"`
	// DueDate is Linear's TimelessDate scalar: a bare "YYYY-MM-DD" string, or
	// null.
	DueDate *string `json:"dueDate"`
}

// GetTeamIssues fetches every issue (up to the first page — see
// teamIssuesQuery/projectIssuesQuery) belonging to the Linear team identified
// by teamKey, optionally narrowed to projectID, newest-updated first. Reuses c
// exactly like PollOnce does (poll.go) — no separate client construction here.
func GetTeamIssues(ctx context.Context, c *Client, teamKey, projectID string) ([]Issue, error) {
	query := teamIssuesQuery
	vars := map[string]any{"teamKey": teamKey}
	if projectID != "" {
		query = projectIssuesQuery
		vars["projectID"] = projectID
	}
	raw, err := c.Query(ctx, query, vars)
	if err != nil {
		return nil, err
	}
	var resp teamIssuesResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, fmt.Errorf("decode issues: %w", err)
	}
	out := make([]Issue, 0, len(resp.Issues.Nodes))
	for _, n := range resp.Issues.Nodes {
		iss := Issue{
			Identifier:  n.Identifier,
			URL:         n.URL,
			Title:       n.Title,
			Description: n.Description,
			Priority:    n.Priority,
		}
		if n.State != nil {
			iss.StateName = n.State.Name
			iss.StateType = n.State.Type
		}
		if n.Assignee != nil {
			iss.AssigneeEmail = n.Assignee.Email
		}
		for _, l := range n.Labels.Nodes {
			iss.Labels = append(iss.Labels, l.Name)
		}
		if n.DueDate != nil && *n.DueDate != "" {
			if t, err := time.Parse("2006-01-02", *n.DueDate); err == nil {
				iss.DueDate = &t
			}
		}
		out = append(out, iss)
	}
	return out, nil
}
