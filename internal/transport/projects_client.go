package transport

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
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
	Name  string `json:"name"`
	OrgID string `json:"org_id"`
}

type ProjectSummary struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Role string `json:"role"`
}

type ProjectRepo struct {
	RepoName string `json:"repo_name"`
	CloneURL string `json:"clone_url"`
}

type ProjectDetail struct {
	Project      projectBrief    `json:"project"`
	Repos        []string        `json:"repos"`
	RepoBindings []ProjectRepo   `json:"repo_bindings"`
	Members      []ProjectMember `json:"members"`
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
		identity := cleanIdentity(m.Identity)
		if identity == "" {
			continue
		}
		out = append(out, identity)
	}
	for _, m := range orgMembers {
		identity := cleanIdentity(m.Identity)
		if identity == "" || !orgRoleCanManage(m.Role) {
			continue
		}
		out = append(out, identity)
	}
	return handoffschema.DedupeIdentities(out), nil
}

func (c *Client) projectTeam(ctx context.Context, projectID string) (projectBrief, []ProjectMember, error) {
	out, err := c.Project(ctx, projectID)
	if err != nil {
		return projectBrief{}, nil, err
	}
	return out.Project, out.Members, nil
}

func (c *Client) Projects(ctx context.Context) ([]ProjectSummary, error) {
	var out struct {
		Projects []ProjectSummary `json:"projects"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/projects", nil, &out); err != nil {
		return nil, err
	}
	return out.Projects, nil
}

func (c *Client) Project(ctx context.Context, projectID string) (*ProjectDetail, error) {
	var out ProjectDetail
	if err := c.do(ctx, http.MethodGet, "/v1/projects/"+url.PathEscape(projectID), nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) ProjectIDForRepo(ctx context.Context, repoName string) (string, bool, error) {
	repoName = strings.TrimSpace(repoName)
	if repoName == "" {
		return "", false, nil
	}
	projects, err := c.Projects(ctx)
	if err != nil {
		return "", false, err
	}
	for _, p := range projects {
		id := strings.TrimSpace(p.ID)
		if id == "" {
			continue
		}
		detail, err := c.Project(ctx, id)
		if err != nil {
			return "", false, err
		}
		for _, repo := range detail.Repos {
			if strings.TrimSpace(repo) == repoName {
				return id, true, nil
			}
		}
	}
	return "", false, nil
}

func (c *Client) ListOrganizationMembers(ctx context.Context, orgID string) ([]OrganizationMember, error) {
	var out struct {
		Members []OrganizationMember `json:"members"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/orgs/"+url.PathEscape(orgID), nil, &out); err != nil {
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
	projectID = strings.TrimSpace(projectID)
	orgID = strings.TrimSpace(orgID)
	member = strings.TrimSpace(member)
	if projectID != "" && orgID != "" {
		return nil, errors.New("project and org are mutually exclusive")
	}
	sender = cleanIdentity(sender)
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
			identity := cleanIdentity(m.Identity)
			if identity == "" || identity == sender || roleKey(m.Role) == "viewer" {
				continue
			}
			if active != nil && !active[identity] {
				continue
			}
			out = append(out, identity)
		}
		for _, m := range orgMembers {
			identity := cleanIdentity(m.Identity)
			if identity == "" || identity == sender || !orgRoleCanManage(m.Role) {
				continue
			}
			if active != nil && !active[identity] {
				continue
			}
			out = append(out, identity)
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
			identity := cleanIdentity(m.Identity)
			if identity == "" || identity == sender || roleKey(m.Role) == "guest" {
				continue
			}
			if active != nil && !active[identity] {
				continue
			}
			out = append(out, identity)
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
	projectID = strings.TrimSpace(projectID)
	orgID = strings.TrimSpace(orgID)
	if projectID != "" && orgID != "" {
		return nil, errors.New("project and org are mutually exclusive")
	}
	member = cleanIdentity(member)
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
			identity := cleanIdentity(m.Identity)
			if identity == "" {
				continue
			}
			if member != "" {
				if identity == member {
					return []string{member}, nil
				}
				continue
			}
			out = append(out, identity)
		}
		for _, m := range orgMembers {
			identity := cleanIdentity(m.Identity)
			if identity == "" || !orgRoleCanManage(m.Role) {
				continue
			}
			if member != "" {
				if identity == member {
					return []string{member}, nil
				}
				continue
			}
			out = append(out, identity)
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
			identity := cleanIdentity(m.Identity)
			if identity == "" {
				continue
			}
			if member != "" {
				if identity == member {
					return []string{member}, nil
				}
				continue
			}
			out = append(out, identity)
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
	sender = cleanIdentity(sender)
	member = cleanIdentity(member)
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
	if roleKey(role) == "viewer" {
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
	sender = cleanIdentity(sender)
	member = cleanIdentity(member)
	role, ok := orgMemberRole(members, member)
	if !ok {
		return nil, fmt.Errorf("%s is not a member of the organization", member)
	}
	if member == sender {
		return nil, fmt.Errorf("cannot send to yourself (%s)", sender)
	}
	if roleKey(role) == "guest" {
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
		identity := cleanIdentity(u.Identity)
		if identity == "" {
			continue
		}
		out[identity] = true
	}
	return out, nil
}

func memberRole(members []ProjectMember, identity string) (string, bool) {
	identity = cleanIdentity(identity)
	for _, m := range members {
		if cleanIdentity(m.Identity) == identity {
			return roleKey(m.Role), true
		}
	}
	return "", false
}

func orgMemberRole(members []OrganizationMember, identity string) (string, bool) {
	identity = cleanIdentity(identity)
	for _, m := range members {
		if cleanIdentity(m.Identity) == identity {
			return roleKey(m.Role), true
		}
	}
	return "", false
}

func orgCanManage(members []OrganizationMember, identity string) bool {
	role, ok := orgMemberRole(members, identity)
	return ok && orgRoleCanManage(role)
}

func orgRoleCanManage(role string) bool {
	role = roleKey(role)
	return role == "owner" || role == "admin"
}

func cleanIdentity(identity string) string {
	return strings.TrimSpace(identity)
}

func roleKey(role string) string {
	return strings.ToLower(strings.TrimSpace(role))
}

func (c *Client) ListProjectHandoffs(ctx context.Context, projectID string, limit int) ([]handoffschema.ListItem, error) {
	q := url.Values{}
	q.Set("scope", "project")
	if projectID != "" {
		q.Set("project", projectID)
	}
	if limit > 0 {
		q.Set("limit", strconv.Itoa(limit))
	}
	var out struct {
		Items []handoffschema.ListItem `json:"items"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/handoffs?"+q.Encode(), nil, &out); err != nil {
		return nil, err
	}
	return out.Items, nil
}
