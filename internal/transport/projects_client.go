package transport

import (
	"context"
	"net/http"
)

// ProjectMember mirrors store.ProjectMember (internal/relay/store/projects.go)
// — kept as a separate wire type here rather than importing the store
// package, matching how the rest of this package avoids depending on
// relay-internal types.
type ProjectMember struct {
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
