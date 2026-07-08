package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/cc-collaboration/pkg/handoffschema"
)

// Project roles. owner manages the project; member can view + comment; viewer
// is read-only. RoleAdmin is an effective API role for global/team managers;
// it is not stored in project_members.
const (
	RoleOwner  = "owner"
	RoleMember = "member"
	RoleViewer = "viewer"
	RoleAdmin  = "admin"
)

// ValidRole reports whether r is one of the known project roles.
func ValidRole(r string) bool {
	return r == RoleOwner || r == RoleMember || r == RoleViewer
}

type Project struct {
	ID            string    `json:"id"`
	OrgID         string    `json:"org_id"`
	Name          string    `json:"name"`
	OwnerIdentity string    `json:"owner_identity"`
	CreatedAt     time.Time `json:"created_at"`
	Role          string    `json:"role,omitempty"`
}

type ProjectMember struct {
	Identity    string `json:"identity"`
	Role        string `json:"role"`
	DisplayName string `json:"display_name"`
}

// ProjectRole is a project with the calling identity's role in it (for /v1/me).
type ProjectRole struct {
	ID    string `json:"id"`
	OrgID string `json:"org_id"`
	Name  string `json:"name"`
	Role  string `json:"role"`
}

const effectiveProjectRoleExpr = `CASE
		          WHEN pm.role = ? THEN ?
		          WHEN om.role IN (?, ?) THEN ?
		          ELSE COALESCE(pm.role, '')
		        END`

func effectiveProjectRoleArgs(identity string) []any {
	return []any{RoleOwner, RoleOwner, OrgRoleOwner, OrgRoleAdmin, RoleAdmin, identity, identity, OrgRoleOwner, OrgRoleAdmin}
}

// CreateProject inserts a project in the owner's default organization.
func (s *Store) CreateProject(ctx context.Context, id, name, owner string, now time.Time) error {
	org, err := s.EnsureDefaultOrganization(ctx, owner, now)
	if err != nil {
		return err
	}
	return s.CreateProjectInOrg(ctx, id, org.ID, name, owner, now)
}

// CreateProjectInOrg inserts a project and seats its owner (role=owner)
// atomically. The owner must already belong to the organization.
func (s *Store) CreateProjectInOrg(ctx context.Context, id, orgID, name, owner string, now time.Time) error {
	active, err := s.UserActive(ctx, owner)
	if err != nil {
		return err
	}
	if !active {
		return ErrForbidden
	}
	role, ok, err := s.OrganizationMemberRole(ctx, orgID, owner)
	if err != nil {
		return err
	}
	if !ok || !OrgRoleCanManage(role) {
		return ErrForbidden
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO projects(id, org_id, name, owner_identity, created_at) VALUES(?, ?, ?, ?, ?)`,
		id, orgID, name, owner, now.UnixMilli()); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO project_members(project_id, identity, role) VALUES(?, ?, ?)`,
		id, owner, RoleOwner); err != nil {
		return err
	}
	return tx.Commit()
}

type scanner interface{ Scan(...any) error }

func scanProject(row scanner) (Project, error) {
	var (
		p         Project
		createdMS int64
	)
	if err := row.Scan(&p.ID, &p.OrgID, &p.Name, &p.OwnerIdentity, &createdMS); err != nil {
		return Project{}, err
	}
	p.CreatedAt = time.UnixMilli(createdMS).UTC()
	return p, nil
}

func (s *Store) GetProject(ctx context.Context, id string) (Project, error) {
	p, err := scanProject(s.db.QueryRowContext(ctx,
		`SELECT id, org_id, name, owner_identity, created_at FROM projects WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return Project{}, ErrNotFound
	}
	return p, err
}

// ListProjects returns every project (admin view).
func (s *Store) ListProjects(ctx context.Context) ([]Project, error) {
	return s.queryProjects(ctx, `SELECT id, org_id, name, owner_identity, created_at FROM projects ORDER BY name`)
}

// ListProjectsForIdentity returns projects the identity can access directly or
// govern through team owner/admin rights.
func (s *Store) ListProjectsForIdentity(ctx context.Context, identity string) ([]Project, error) {
	active, err := s.UserActive(ctx, identity)
	if err != nil {
		return nil, err
	}
	if !active {
		return nil, nil
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT p.id, p.org_id, p.name, p.owner_identity, p.created_at, `+effectiveProjectRoleExpr+`
		   FROM projects p
		   LEFT JOIN project_members pm ON pm.project_id = p.id AND pm.identity = ?
		   LEFT JOIN organization_members om ON om.org_id = p.org_id AND om.identity = ?
		  WHERE pm.identity IS NOT NULL OR om.role IN (?, ?)
		  ORDER BY p.name`,
		effectiveProjectRoleArgs(identity)...)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (Project, error) {
		p, err := scanProjectWithRole(r)
		return p, err
	})
}

// EffectiveProjectRole returns the caller's effective role for a project. Team
// owner/admin can govern every project in the organization even when they are
// not direct project members.
func (s *Store) EffectiveProjectRole(ctx context.Context, projectID, identity string) (string, bool, error) {
	active, err := s.UserActive(ctx, identity)
	if err != nil {
		return "", false, err
	}
	if !active {
		return "", false, nil
	}
	var projectRole, orgRole string
	err = s.db.QueryRowContext(ctx,
		`SELECT COALESCE(pm.role, ''), COALESCE(om.role, '')
		   FROM projects p
		   LEFT JOIN project_members pm ON pm.project_id = p.id AND pm.identity = ?
		   LEFT JOIN organization_members om ON om.org_id = p.org_id AND om.identity = ?
		  WHERE p.id = ?`,
		identity, identity, projectID).Scan(&projectRole, &orgRole)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	if projectRole == RoleOwner {
		return RoleOwner, true, nil
	}
	if OrgRoleCanManage(orgRole) {
		return RoleAdmin, true, nil
	}
	if projectRole != "" {
		return projectRole, true, nil
	}
	return "", false, nil
}

// scanRows drains rows, scanning each with scan, and closes rows — centralizing
// the for-Next / Scan / append loop the list queries share.
func scanRows[T any](rows *sql.Rows, scan func(*sql.Rows) (T, error)) ([]T, error) {
	defer rows.Close()
	var out []T
	for rows.Next() {
		v, err := scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func (s *Store) queryProjects(ctx context.Context, query string, args ...any) ([]Project, error) {
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (Project, error) { return scanProject(r) })
}

func scanProjectWithRole(row scanner) (Project, error) {
	var (
		p         Project
		createdMS int64
	)
	if err := row.Scan(&p.ID, &p.OrgID, &p.Name, &p.OwnerIdentity, &createdMS, &p.Role); err != nil {
		return Project{}, err
	}
	p.CreatedAt = time.UnixMilli(createdMS).UTC()
	return p, nil
}

func (s *Store) RenameProject(ctx context.Context, id, name string) error {
	return s.execAffecting(ctx, `UPDATE projects SET name = ? WHERE id = ?`, name, id)
}

func (s *Store) DeleteProject(ctx context.Context, id string) error {
	return s.execAffecting(ctx, `DELETE FROM projects WHERE id = ?`, id)
}

// MapRepo binds a repo to a project; a repo belongs to exactly one project, so a
// re-map moves it. Requires the project to exist (FK).
func (s *Store) MapRepo(ctx context.Context, repoName, projectID string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO project_repos(repo_name, project_id) VALUES(?, ?)
		 ON CONFLICT(repo_name) DO UPDATE SET project_id = excluded.project_id`,
		repoName, projectID)
	return err
}

func (s *Store) UnmapRepo(ctx context.Context, repoName string) error {
	return s.execAffecting(ctx, `DELETE FROM project_repos WHERE repo_name = ?`, repoName)
}

func (s *Store) ListProjectRepos(ctx context.Context, projectID string) ([]string, error) {
	return s.queryStrings(ctx, `SELECT repo_name FROM project_repos WHERE project_id = ? ORDER BY repo_name`, projectID)
}

// AddMember adds or updates a member's role (upsert).
func (s *Store) AddMember(ctx context.Context, projectID, identity, role string) error {
	active, err := s.UserActive(ctx, identity)
	if err != nil {
		return err
	}
	if !active {
		return ErrForbidden
	}
	if err := s.guardLastProjectOwner(ctx, projectID, identity, role); err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO project_members(project_id, identity, role) VALUES(?, ?, ?)
		 ON CONFLICT(project_id, identity) DO UPDATE SET role = excluded.role`,
		projectID, identity, role); err != nil {
		return err
	}
	if role != RoleOwner {
		if err := replaceProjectOwnerIdentity(ctx, tx, projectID, identity); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) RemoveMember(ctx context.Context, projectID, identity string) error {
	role, ok, err := s.MemberRole(ctx, projectID, identity)
	if err != nil {
		return err
	}
	if !ok {
		return ErrNotFound
	}
	if role == RoleOwner {
		owners, err := s.CountProjectOwners(ctx, projectID)
		if err != nil {
			return err
		}
		if owners <= 1 {
			return ErrLastOwner
		}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if role == RoleOwner {
		if err := replaceProjectOwnerIdentity(ctx, tx, projectID, identity); err != nil {
			return err
		}
	}
	res, err := tx.ExecContext(ctx, `DELETE FROM project_members WHERE project_id = ? AND identity = ?`, projectID, identity)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return tx.Commit()
}

func (s *Store) ListMembers(ctx context.Context, projectID string) ([]ProjectMember, error) {
	// LEFT JOIN users for the member's display name so the assign-member picker
	// shows real names instead of raw identities — getProject is member-gated, so
	// this works for non-admins (unlike the admin-only /v1/users).
	rows, err := s.db.QueryContext(ctx,
		`SELECT pm.identity, pm.role, COALESCE(u.display_name, '')
		   FROM project_members pm
		   LEFT JOIN users u ON u.identity = pm.identity
		  WHERE pm.project_id = ? AND (u.identity IS NULL OR u.disabled = 0)
		  ORDER BY pm.identity`, projectID)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (ProjectMember, error) {
		var m ProjectMember
		err := r.Scan(&m.Identity, &m.Role, &m.DisplayName)
		return m, err
	})
}

// MemberRole returns identity's role in a project, or ok=false if not a member.
func (s *Store) MemberRole(ctx context.Context, projectID, identity string) (string, bool, error) {
	var role string
	err := s.db.QueryRowContext(ctx,
		`SELECT role FROM project_members WHERE project_id = ? AND identity = ?`, projectID, identity).Scan(&role)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return role, true, nil
}

// MemberProjects returns the projects (with the caller's effective role) for
// /v1/me. Team owner/admin see the projects they can govern as role=admin.
func (s *Store) MemberProjects(ctx context.Context, identity string) ([]ProjectRole, error) {
	active, err := s.UserActive(ctx, identity)
	if err != nil {
		return nil, err
	}
	if !active {
		return nil, nil
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT p.id, p.org_id, p.name, `+effectiveProjectRoleExpr+`
		   FROM projects p
		   LEFT JOIN project_members pm ON pm.project_id = p.id AND pm.identity = ?
		   LEFT JOIN organization_members om ON om.org_id = p.org_id AND om.identity = ?
		  WHERE pm.identity IS NOT NULL OR om.role IN (?, ?)
		  ORDER BY p.name`,
		effectiveProjectRoleArgs(identity)...)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (ProjectRole, error) {
		var pr ProjectRole
		err := r.Scan(&pr.ID, &pr.OrgID, &pr.Name, &pr.Role)
		return pr, err
	})
}

// IdentitiesShareTeam reports whether two identities share an organization or
// project. Legacy tokens.json deployments may have no team rows; in that case,
// if neither side has any org/project membership, they remain mutually
// reachable to preserve the pre-SaaS flat-roster behavior.
func (s *Store) IdentitiesShareTeam(ctx context.Context, a, b string) (bool, error) {
	if a == b {
		return true, nil
	}
	aOrgs, err := s.MemberOrganizations(ctx, a)
	if err != nil {
		return false, err
	}
	bOrgs, err := s.MemberOrganizations(ctx, b)
	if err != nil {
		return false, err
	}
	aProjects, err := s.MemberProjects(ctx, a)
	if err != nil {
		return false, err
	}
	bProjects, err := s.MemberProjects(ctx, b)
	if err != nil {
		return false, err
	}
	if len(aOrgs) == 0 && len(bOrgs) == 0 && len(aProjects) == 0 && len(bProjects) == 0 {
		return true, nil
	}
	orgs := make(map[string]struct{}, len(aOrgs))
	for _, org := range aOrgs {
		orgs[org.ID] = struct{}{}
	}
	for _, org := range bOrgs {
		if _, ok := orgs[org.ID]; ok {
			return true, nil
		}
	}
	projects := make(map[string]struct{}, len(aProjects))
	for _, project := range aProjects {
		projects[project.ID] = struct{}{}
	}
	for _, project := range bProjects {
		if _, ok := projects[project.ID]; ok {
			return true, nil
		}
	}
	return false, nil
}

func (s *Store) CountProjectOwners(ctx context.Context, projectID string) (int, error) {
	var count int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM project_members WHERE project_id = ? AND role = ?`, projectID, RoleOwner).Scan(&count)
	return count, err
}

func (s *Store) guardLastProjectOwner(ctx context.Context, projectID, identity, nextRole string) error {
	current, ok, err := s.MemberRole(ctx, projectID, identity)
	if err != nil || !ok || current != RoleOwner || nextRole == RoleOwner {
		return err
	}
	owners, err := s.CountProjectOwners(ctx, projectID)
	if err != nil {
		return err
	}
	if owners <= 1 {
		return ErrLastOwner
	}
	return nil
}

func replaceProjectOwnerIdentity(ctx context.Context, tx *sql.Tx, projectID, removedOrDemotedOwner string) error {
	var current string
	if err := tx.QueryRowContext(ctx,
		`SELECT owner_identity FROM projects WHERE id = ?`, projectID).Scan(&current); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	if current != removedOrDemotedOwner {
		return nil
	}
	var replacement string
	if err := tx.QueryRowContext(ctx,
		`SELECT identity FROM project_members
		  WHERE project_id = ? AND role = ? AND identity != ?
		  ORDER BY identity LIMIT 1`,
		projectID, RoleOwner, removedOrDemotedOwner).Scan(&replacement); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrLastOwner
		}
		return err
	}
	_, err := tx.ExecContext(ctx,
		`UPDATE projects SET owner_identity = ? WHERE id = ?`, replacement, projectID)
	return err
}

// RepoVisibleTo returns the caller's effective role for the project owning
// repoName, or ok=false when the repo is unmapped or the caller cannot access
// that project. Used by the read-authz check (view + comment gating).
func (s *Store) RepoVisibleTo(ctx context.Context, repoName, identity string) (string, bool, error) {
	active, err := s.UserActive(ctx, identity)
	if err != nil {
		return "", false, err
	}
	if !active {
		return "", false, nil
	}
	var role string
	args := append(effectiveProjectRoleArgs(identity), repoName)
	err = s.db.QueryRowContext(ctx,
		`SELECT `+effectiveProjectRoleExpr+`
		   FROM project_repos pr
		   JOIN projects p ON p.id = pr.project_id
		   LEFT JOIN project_members pm ON pm.project_id = pr.project_id AND pm.identity = ?
		   LEFT JOIN organization_members om ON om.org_id = p.org_id AND om.identity = ?
		  WHERE (pm.identity IS NOT NULL OR om.role IN (?, ?)) AND pr.repo_name = ?`,
		args...).Scan(&role)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return role, true, nil
}

// VisibleRepoNames returns every repo across the caller's directly visible or
// team-managed projects (the project-scoped list filter set).
func (s *Store) VisibleRepoNames(ctx context.Context, identity string) ([]string, error) {
	active, err := s.UserActive(ctx, identity)
	if err != nil {
		return nil, err
	}
	if !active {
		return nil, nil
	}
	return s.queryStrings(ctx,
		`SELECT pr.repo_name FROM project_repos pr
		   JOIN projects p ON p.id = pr.project_id
		   LEFT JOIN project_members pm ON pm.project_id = pr.project_id AND pm.identity = ?
		   LEFT JOIN organization_members om ON om.org_id = p.org_id AND om.identity = ?
		  WHERE pm.identity IS NOT NULL OR om.role IN (?, ?)
		  ORDER BY pr.repo_name`,
		identity, identity, OrgRoleOwner, OrgRoleAdmin)
}

// ListByRepos returns compact list items for non-capsule handoffs whose repo is
// in repoNames, newest-first — the project-scoped view. Empty repoNames returns
// nil early (avoids an `IN ()` syntax error).
func (s *Store) ListByRepos(ctx context.Context, repoNames []string, limit int) ([]handoffschema.ListItem, error) {
	if len(repoNames) == 0 {
		return nil, nil
	}
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(repoNames)), ",")
	args := make([]any, 0, len(repoNames)+2)
	for _, r := range repoNames {
		args = append(args, r)
	}
	args = append(args, string(handoffschema.KindCapsule))
	args = append(args, limit)
	rows, err := s.db.QueryContext(ctx,
		`SELECT h.id, h.sender, h.recipients, h.urgency, h.state, h.created_at,
		        h.repo_name, h.branch, h.headline, h.kind, h.bug_group_id
		   FROM handoffs h
		  WHERE h.repo_name IN (`+placeholders+`)
		    AND h.kind != ?
		  ORDER BY h.created_at DESC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, scanListItem)
}

// ListAll returns compact list items for every non-capsule handoff, newest-first
// (admin scope). Capsules live behind the plaza listing and its visibility rule.
func (s *Store) ListAll(ctx context.Context, limit int) ([]handoffschema.ListItem, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT h.id, h.sender, h.recipients, h.urgency, h.state, h.created_at,
		        h.repo_name, h.branch, h.headline, h.kind, h.bug_group_id
		   FROM handoffs h
		  WHERE h.kind != ?
		  ORDER BY h.created_at DESC LIMIT ?`,
		string(handoffschema.KindCapsule), limit)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, scanListItem)
}

func (s *Store) queryStrings(ctx context.Context, query string, args ...any) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (string, error) {
		var v string
		err := r.Scan(&v)
		return v, err
	})
}
