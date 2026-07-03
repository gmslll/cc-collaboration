package linear

import (
	"context"
	"fmt"
	"strings"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/todoschema"
)

// ImportResult summarizes one `cc-handoff todo import-linear` /
// import_linear_issues run.
type ImportResult struct {
	TeamKey   string
	ProjectID string
	Issues    int
	Created   int
	Updated   int
}

// ImportTeamIssuesForRepo is the shared "do the whole import" entry point
// used by both `cc-handoff todo import-linear` (cmd/cc-handoff/todo.go) and
// the import_linear_issues MCP tool (internal/mcp/todo_tools.go) — see the
// feature plan's Track A. It resolves cwd's config, builds the Linear + relay
// clients, fetches every issue for teamKey (falling back to the repo's
// configured [integrations.linear] team_key when teamKey is empty), and
// upserts each as a todo keyed by SourceRef ("linear:<identifier>") so
// re-running is idempotent. projectID scopes created todos to a cc-handoff
// team project; empty means personal todos owned by the caller's identity.
func ImportTeamIssuesForRepo(ctx context.Context, cwd, teamKey, projectID string) (ImportResult, error) {
	res, err := config.Resolve(cwd)
	if err != nil {
		return ImportResult{}, err
	}
	if res.LinearPersonalToken == "" {
		return ImportResult{}, fmt.Errorf("linear_personal_token not set in user config (~/.config/cc-handoff/config.toml). " +
			"Generate one at Linear → Account → Security & Access → Personal API Keys.")
	}
	if teamKey == "" {
		teamKey = res.Linear.TeamKey
	}
	if teamKey == "" {
		return ImportResult{}, fmt.Errorf("no Linear team key: pass --team, or set [integrations.linear] team_key in .cc-handoff.toml")
	}

	gql := NewClient(res.LinearPersonalToken)
	todoClient := transport.New(res.RelayURL, res.Token)

	// Candidate identity pool for assignee-email matching (see
	// matchAssigneeIdentity): always the caller's own identity, plus every
	// member of the target project when importing into a team project.
	candidates := []string{res.Me}
	if projectID != "" {
		members, err := todoClient.ListProjectMembers(ctx, projectID)
		if err != nil {
			return ImportResult{}, fmt.Errorf("list project %s members: %w", projectID, err)
		}
		for _, m := range members {
			candidates = append(candidates, m.Identity)
		}
	}

	issues, err := GetTeamIssues(ctx, gql, teamKey)
	if err != nil {
		return ImportResult{}, fmt.Errorf("fetch linear issues for team %s: %w", teamKey, err)
	}

	result := ImportResult{TeamKey: teamKey, ProjectID: projectID, Issues: len(issues)}
	for _, iss := range issues {
		created, err := upsertTodoFromIssue(ctx, todoClient, iss, projectID, candidates)
		if err != nil {
			return result, fmt.Errorf("import %s: %w", iss.Identifier, err)
		}
		if created {
			result.Created++
		} else {
			result.Updated++
		}
	}
	return result, nil
}

// upsertTodoFromIssue applies the mapping rules from the feature plan to one
// Linear issue: find-by-SourceRef decides create vs. update. Assignee
// matching only applies on create — a re-import shouldn't clobber a manual
// reassignment made inside cc-handoff after the fact.
func upsertTodoFromIssue(ctx context.Context, c *transport.Client, iss Issue, projectID string, candidates []string) (created bool, err error) {
	sourceRef := "linear:" + iss.Identifier
	status := mapIssueStatus(iss.StateType)
	priority := mapIssuePriority(iss.Priority)
	bodyMD := composeBodyMD(iss.Labels, iss.Description)

	existing, found, err := c.FindTodoBySourceRef(ctx, sourceRef)
	if err != nil {
		return false, fmt.Errorf("lookup: %w", err)
	}
	if found {
		title := iss.Title
		if _, err := c.PatchTodo(ctx, existing.ID, transport.TodoPatch{
			Title:    &title,
			BodyMD:   &bodyMD,
			Priority: &priority,
			DueAt:    transport.OptionalTime{Set: true, Value: iss.DueDate},
		}); err != nil {
			return false, fmt.Errorf("patch: %w", err)
		}
		if _, err := c.SetTodoStatus(ctx, existing.ID, status); err != nil {
			return false, fmt.Errorf("set status: %w", err)
		}
		return false, nil
	}

	out, err := c.CreateTodo(ctx, &todoschema.Todo{
		ProjectID: projectID,
		Title:     iss.Title,
		BodyMD:    bodyMD,
		Priority:  priority,
		DueAt:     iss.DueDate,
		SourceRef: sourceRef,
		SourceURL: iss.URL,
	})
	if err != nil {
		return false, fmt.Errorf("create: %w", err)
	}
	if status != todoschema.StatusTodo {
		if _, err := c.SetTodoStatus(ctx, out.ID, status); err != nil {
			return true, fmt.Errorf("set status: %w", err)
		}
	}
	if assignee := matchAssigneeIdentity(candidates, iss.AssigneeEmail); assignee != "" {
		if _, err := c.AssignTodo(ctx, out.ID, assignee, "", "", "", "", ""); err != nil {
			return true, fmt.Errorf("assign: %w", err)
		}
	}
	return true, nil
}

// mapIssueStatus maps Linear's state.type onto our (now Linear-shaped)
// Status 1:1 — backlog/unstarted/started/completed/canceled each have a
// direct counterpart, unlike the old 6-value taxonomy where backlog and
// unstarted both had to compress onto the same "pending" bucket. Any
// unrecognized type (Linear adds new ones rarely, but schemas drift) falls
// back to triage rather than erroring the whole import — "needs a human to
// figure out what this is" is triage's actual purpose.
func mapIssueStatus(stateType string) todoschema.Status {
	switch stateType {
	case "backlog":
		return todoschema.StatusBacklog
	case "unstarted":
		return todoschema.StatusTodo
	case "started":
		return todoschema.StatusInProgress
	case "completed":
		return todoschema.StatusDone
	case "canceled":
		return todoschema.StatusCanceled
	default:
		return todoschema.StatusTriage
	}
}

// mapIssuePriority compresses Linear's own priority scale onto our
// low/normal/high. Linear's scale is NOT a plain ascending low→high range —
// it's 0=no priority, 1=urgent, 2=high, 3=medium, 4=low (urgent is the
// *lowest* number) — so the mapping mirrors that real semantics rather than
// splitting the 0-4 range in numeric order.
func mapIssuePriority(p int) todoschema.Priority {
	switch p {
	case 1, 2: // urgent, high
		return todoschema.PriorityHigh
	case 4: // low
		return todoschema.PriorityLow
	default: // 0 (no priority), 3 (medium), or anything unexpected
		return todoschema.PriorityNormal
	}
}

// composeBodyMD prepends a label line to description when Linear issue
// carries labels — there's no dedicated label field on todoschema.Todo (see
// the feature plan's explicitly-out-of-scope note), so labels live as the
// body's first line instead.
func composeBodyMD(labels []string, description string) string {
	if len(labels) == 0 {
		return description
	}
	return "🏷 " + strings.Join(labels, ", ") + "\n\n" + description
}

// matchAssigneeIdentity does a best-effort, case-insensitive match of a
// Linear assignee's email against the candidate identity pool (the caller
// plus, when importing into a team project, that project's members).
// Returns "" (no error) when nothing matches — an unmatched assignee simply
// leaves the todo unassigned, per the feature plan.
func matchAssigneeIdentity(candidates []string, email string) string {
	email = strings.TrimSpace(email)
	if email == "" {
		return ""
	}
	for _, id := range candidates {
		if strings.EqualFold(strings.TrimSpace(id), email) {
			return id
		}
	}
	return ""
}
