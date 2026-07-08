package transport

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"

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

type projectBrief struct {
	ID    string `json:"id"`
	OrgID string `json:"org_id"`
}

type OrganizationMember struct {
	Identity string `json:"identity"`
	Role     string `json:"role"`
}

// ListProjectMembers returns the direct members of project id. Use
// ListProjectAssigneeIdentities when callers need effective project assignees.
func (c *Client) ListProjectMembers(ctx context.Context, projectID string) ([]ProjectMember, error) {
	_, members, err := c.projectTeam(ctx, projectID)
	return members, err
}

// ListProjectAssigneeIdentities returns identities that may be assigned a todo
// in project id: direct project members plus organization owner/admin users who
// have effective project access through the owning team.
func (c *Client) ListProjectAssigneeIdentities(ctx context.Context, projectID string) ([]string, error) {
	project, members, err := c.projectTeam(ctx, projectID)
	if err != nil {
		return nil, err
	}
	orgMembers, err := c.projectOrgMembers(ctx, project.OrgID)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(members)+len(orgMembers))
	for _, m := range members {
		if m.Identity == "" {
			continue
		}
		out = append(out, m.Identity)
	}
	for _, m := range orgMembers {
		if m.Identity == "" || !orgRoleCanManage(m.Role) {
			continue
		}
		out = append(out, m.Identity)
	}
	return handoffschema.DedupeIdentities(out), nil
}

func (c *Client) projectTeam(ctx context.Context, projectID string) (projectBrief, []ProjectMember, error) {
	var out struct {
		Project projectBrief    `json:"project"`
		Members []ProjectMember `json:"members"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/projects/"+projectID, nil, &out); err != nil {
		return projectBrief{}, nil, err
	}
	return out.Project, out.Members, nil
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
// recipient identities. When member is set, it must be an identity inside that
// team and the result is limited to that one identity. It excludes the sender
// and read-only roles: project viewers and organization guests can discover/read
// shared work via project/org views, but they should not get actionable pickup
// slots.
func (c *Client) ResolveTeamRecipients(ctx context.Context, projectID, orgID, sender, member string) ([]string, error) {
	if projectID != "" && orgID != "" {
		return nil, errors.New("project and org are mutually exclusive")
	}
	member = strings.TrimSpace(member)
	switch {
	case projectID != "":
		project, members, err := c.projectTeam(ctx, projectID)
		if err != nil {
			return nil, err
		}
		orgMembers, err := c.projectOrgMembers(ctx, project.OrgID)
		if err != nil {
			return nil, err
		}
		if !projectSenderCanShare(members, orgMembers, sender) {
			isAdmin, err := c.currentIdentityIsAdmin(ctx, sender)
			if err != nil {
				return nil, err
			}
			if !isAdmin {
				return nil, errors.New("sender cannot send project-shared handoffs")
			}
		}
		active, err := c.activeIdentities(ctx)
		if err != nil {
			return nil, err
		}
		if member != "" {
			return resolveOneProjectRecipient(members, orgMembers, active, sender, member)
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
		for _, m := range orgMembers {
			if m.Identity == "" || m.Identity == sender || !orgRoleCanManage(m.Role) {
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
		role, ok := orgMemberRole(members, sender)
		if !ok || role == "guest" {
			isAdmin, err := c.currentIdentityIsAdmin(ctx, sender)
			if err != nil {
				return nil, err
			}
			if !ok && !isAdmin {
				return nil, errors.New("sender is not a member of the organization")
			}
			if role == "guest" && !isAdmin {
				return nil, errors.New("organization guests cannot send team-shared handoffs")
			}
		}
		active, err := c.activeIdentities(ctx)
		if err != nil {
			return nil, err
		}
		if member != "" {
			return resolveOneOrgRecipient(members, active, sender, member)
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

// ListTeamIdentities returns identities in a project/org, including read-only
// roles. Project scope includes direct project members plus team owners/admins
// with effective project access. It is intended for display/filtering commands
// such as online. When member is set, it validates that identity belongs to the
// selected team/effective project team.
func (c *Client) ListTeamIdentities(ctx context.Context, projectID, orgID, member string) ([]string, error) {
	if projectID != "" && orgID != "" {
		return nil, errors.New("project and org are mutually exclusive")
	}
	member = strings.TrimSpace(member)
	switch {
	case projectID != "":
		project, members, err := c.projectTeam(ctx, projectID)
		if err != nil {
			return nil, err
		}
		orgMembers, err := c.projectOrgMembers(ctx, project.OrgID)
		if err != nil {
			return nil, err
		}
		out := make([]string, 0, len(members))
		for _, m := range members {
			if m.Identity == "" {
				continue
			}
			if member != "" {
				if m.Identity == member {
					return []string{member}, nil
				}
				continue
			}
			out = append(out, m.Identity)
		}
		for _, m := range orgMembers {
			if m.Identity == "" || !orgRoleCanManage(m.Role) {
				continue
			}
			if member != "" {
				if m.Identity == member {
					return []string{member}, nil
				}
				continue
			}
			out = append(out, m.Identity)
		}
		if member != "" {
			return nil, fmt.Errorf("%s is not a member or team manager of project %s", member, projectID)
		}
		return handoffschema.DedupeIdentities(out), nil
	case orgID != "":
		members, err := c.ListOrganizationMembers(ctx, orgID)
		if err != nil {
			return nil, err
		}
		out := make([]string, 0, len(members))
		for _, m := range members {
			if m.Identity == "" {
				continue
			}
			if member != "" {
				if m.Identity == member {
					return []string{member}, nil
				}
				continue
			}
			out = append(out, m.Identity)
		}
		if member != "" {
			return nil, fmt.Errorf("%s is not a member of organization %s", member, orgID)
		}
		return handoffschema.DedupeIdentities(out), nil
	default:
		if member != "" {
			return nil, errors.New("member requires project or org")
		}
		return nil, nil
	}
}

func resolveOneProjectRecipient(members []ProjectMember, orgMembers []OrganizationMember, active map[string]bool, sender, member string) ([]string, error) {
	role, ok := memberRole(members, member)
	if !ok && orgCanManage(orgMembers, member) {
		role, ok = "admin", true
	}
	if !ok {
		return nil, fmt.Errorf("%s is not a member of the project", member)
	}
	if member == sender {
		return nil, fmt.Errorf("cannot send to yourself (%s)", sender)
	}
	if role == "viewer" {
		return nil, fmt.Errorf("project viewer %s cannot receive actionable team handoffs", member)
	}
	if active != nil && !active[member] {
		return nil, fmt.Errorf("team member %s is disabled or inactive", member)
	}
	return []string{member}, nil
}

func projectSenderCanShare(members []ProjectMember, orgMembers []OrganizationMember, sender string) bool {
	if orgCanManage(orgMembers, sender) {
		return true
	}
	role, ok := memberRole(members, sender)
	return ok && role != "viewer"
}

func (c *Client) projectOrgMembers(ctx context.Context, orgID string) ([]OrganizationMember, error) {
	if strings.TrimSpace(orgID) == "" {
		return nil, nil
	}
	return c.ListOrganizationMembers(ctx, orgID)
}

func resolveOneOrgRecipient(members []OrganizationMember, active map[string]bool, sender, member string) ([]string, error) {
	role, ok := orgMemberRole(members, member)
	if !ok {
		return nil, fmt.Errorf("%s is not a member of the organization", member)
	}
	if member == sender {
		return nil, fmt.Errorf("cannot send to yourself (%s)", sender)
	}
	if role == "guest" {
		return nil, fmt.Errorf("organization guest %s cannot receive actionable team handoffs", member)
	}
	if active != nil && !active[member] {
		return nil, fmt.Errorf("team member %s is disabled or inactive", member)
	}
	return []string{member}, nil
}

func (c *Client) currentIdentityIsAdmin(ctx context.Context, sender string) (bool, error) {
	if strings.TrimSpace(sender) == "" {
		return false, nil
	}
	me, err := c.Me(ctx)
	if err != nil {
		if errors.Is(err, ErrNotImplemented) {
			return false, nil
		}
		return false, err
	}
	return me.Identity == sender && me.IsAdmin, nil
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

func orgCanManage(members []OrganizationMember, identity string) bool {
	role, ok := orgMemberRole(members, identity)
	return ok && orgRoleCanManage(role)
}

func orgRoleCanManage(role string) bool {
	return role == "owner" || role == "admin"
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
