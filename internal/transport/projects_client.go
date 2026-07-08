package transport

import (
	"context"
	"errors"
	"net/http"
	"strconv"

	"github.com/cc-collaboration/pkg/handoffschema"
)

// ProjectMember mirrors store.ProjectMember (internal/relay/store/projects.go)
// — kept as a separate wire type here rather than importing the store
// package, matching how the rest of this package avoids depending on
// relay-internal types.
type ProjectMember struct {
	Identity string `json:"identity"`
	Role     string `json:"role"`
}

type OrganizationMember struct {
	Identity string `json:"identity"`
	Role     string `json:"role"`
}

// ListProjectMembers returns the members of project id. Used by the
// todo-import flow (internal/linear/import.go) to build the candidate pool
// for matching a Linear issue's assignee email to a cc-handoff identity.
func (c *Client) ListProjectMembers(ctx context.Context, projectID string) ([]ProjectMember, error) {
	var out struct {
		Members []ProjectMember `json:"members"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/projects/"+projectID, nil, &out); err != nil {
		return nil, err
	}
	return out.Members, nil
}

func (c *Client) ListOrganizationMembers(ctx context.Context, orgID string) ([]OrganizationMember, error) {
	var out struct {
		Members []OrganizationMember `json:"members"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/orgs/"+orgID, nil, &out); err != nil {
		return nil, err
	}
	return out.Members, nil
}

// ResolveTeamRecipients expands a project or organization target into concrete
// recipient identities. It excludes the sender and read-only roles: project
// viewers and organization guests can discover/read shared work via project/org
// views, but they should not get actionable pickup slots.
func (c *Client) ResolveTeamRecipients(ctx context.Context, projectID, orgID, sender string) ([]string, error) {
	if projectID != "" && orgID != "" {
		return nil, errors.New("project and org are mutually exclusive")
	}
	switch {
	case projectID != "":
		members, err := c.ListProjectMembers(ctx, projectID)
		if err != nil {
			return nil, err
		}
		if role, ok := memberRole(members, sender); ok && role == "viewer" {
			return nil, errors.New("project viewers cannot send team-shared handoffs")
		}
		active, err := c.activeIdentities(ctx)
		if err != nil {
			return nil, err
		}
		out := make([]string, 0, len(members))
		for _, m := range members {
			if m.Identity == "" || m.Identity == sender || m.Role == "viewer" {
				continue
			}
			if active != nil && !active[m.Identity] {
				continue
			}
			out = append(out, m.Identity)
		}
		return handoffschema.DedupeIdentities(out), nil
	case orgID != "":
		members, err := c.ListOrganizationMembers(ctx, orgID)
		if err != nil {
			return nil, err
		}
		if role, ok := orgMemberRole(members, sender); ok && role == "guest" {
			return nil, errors.New("organization guests cannot send team-shared handoffs")
		}
		active, err := c.activeIdentities(ctx)
		if err != nil {
			return nil, err
		}
		out := make([]string, 0, len(members))
		for _, m := range members {
			if m.Identity == "" || m.Identity == sender || m.Role == "guest" {
				continue
			}
			if active != nil && !active[m.Identity] {
				continue
			}
			out = append(out, m.Identity)
		}
		return handoffschema.DedupeIdentities(out), nil
	default:
		return nil, nil
	}
}

func (c *Client) activeIdentities(ctx context.Context) (map[string]bool, error) {
	users, err := c.ListOnlineUsers(ctx)
	if err != nil {
		if errors.Is(err, ErrNotImplemented) {
			return nil, nil
		}
		return nil, err
	}
	out := make(map[string]bool, len(users))
	for _, u := range users {
		out[u.Identity] = true
	}
	return out, nil
}

func memberRole(members []ProjectMember, identity string) (string, bool) {
	for _, m := range members {
		if m.Identity == identity {
			return m.Role, true
		}
	}
	return "", false
}

func orgMemberRole(members []OrganizationMember, identity string) (string, bool) {
	for _, m := range members {
		if m.Identity == identity {
			return m.Role, true
		}
	}
	return "", false
}

func (c *Client) ListProjectHandoffs(ctx context.Context, projectID string, limit int) ([]handoffschema.ListItem, error) {
	q := "?scope=project"
	if projectID != "" {
		q += "&project=" + projectID
	}
	if limit > 0 {
		q += "&limit=" + strconv.Itoa(limit)
	}
	var out struct {
		Items []handoffschema.ListItem `json:"items"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/handoffs"+q, nil, &out); err != nil {
		return nil, err
	}
	return out.Items, nil
}
