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
// is read-only. Global admin (users.is_admin) supersedes all of these.
const (
	RoleOwner  = "owner"
	RoleMember = "member"
	RoleViewer = "viewer"
)

// ValidRole reports whether r is one of the known project roles.
func ValidRole(r string) bool {
	return r == RoleOwner || r == RoleMember || r == RoleViewer
}

type Project struct {
	ID            string    `json:"id"`
	Name          string    `json:"name"`
	OwnerIdentity string    `json:"owner_identity"`
	CreatedAt     time.Time `json:"created_at"`
}

type ProjectMember struct {
	Identity string `json:"identity"`
	Role     string `json:"role"`
}

// ProjectRole is a project with the calling identity's role in it (for /v1/me).
type ProjectRole struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Role string `json:"role"`
}

// CreateProject inserts a project and seats its owner (role=owner) atomically.
func (s *Store) CreateProject(ctx context.Context, id, name, owner string, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO projects(id, name, owner_identity, created_at) VALUES(?, ?, ?, ?)`,
		id, name, owner, now.UnixMilli()); err != nil {
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
	if err := row.Scan(&p.ID, &p.Name, &p.OwnerIdentity, &createdMS); err != nil {
		return Project{}, err
	}
	p.CreatedAt = time.UnixMilli(createdMS).UTC()
	return p, nil
}

func (s *Store) GetProject(ctx context.Context, id string) (Project, error) {
	p, err := scanProject(s.db.QueryRowContext(ctx,
		`SELECT id, name, owner_identity, created_at FROM projects WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return Project{}, ErrNotFound
	}
	return p, err
}

// ListProjects returns every project (admin view).
func (s *Store) ListProjects(ctx context.Context) ([]Project, error) {
	return s.queryProjects(ctx, `SELECT id, name, owner_identity, created_at FROM projects ORDER BY name`)
}

// ListProjectsForIdentity returns the projects an identity is a member of.
func (s *Store) ListProjectsForIdentity(ctx context.Context, identity string) ([]Project, error) {
	return s.queryProjects(ctx,
		`SELECT p.id, p.name, p.owner_identity, p.created_at FROM projects p
		   JOIN project_members pm ON pm.project_id = p.id
		  WHERE pm.identity = ? ORDER BY p.name`, identity)
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
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO project_members(project_id, identity, role) VALUES(?, ?, ?)
		 ON CONFLICT(project_id, identity) DO UPDATE SET role = excluded.role`,
		projectID, identity, role)
	return err
}

func (s *Store) RemoveMember(ctx context.Context, projectID, identity string) error {
	return s.execAffecting(ctx, `DELETE FROM project_members WHERE project_id = ? AND identity = ?`, projectID, identity)
}

func (s *Store) ListMembers(ctx context.Context, projectID string) ([]ProjectMember, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT identity, role FROM project_members WHERE project_id = ? ORDER BY identity`, projectID)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (ProjectMember, error) {
		var m ProjectMember
		err := r.Scan(&m.Identity, &m.Role)
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

// MemberProjects returns the projects (with the caller's role) an identity is in.
func (s *Store) MemberProjects(ctx context.Context, identity string) ([]ProjectRole, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT p.id, p.name, pm.role FROM project_members pm
		   JOIN projects p ON p.id = pm.project_id
		  WHERE pm.identity = ? ORDER BY p.name`, identity)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (ProjectRole, error) {
		var pr ProjectRole
		err := r.Scan(&pr.ID, &pr.Name, &pr.Role)
		return pr, err
	})
}

// RepoVisibleTo returns the caller's role for the project owning repoName, or
// ok=false when the repo is unmapped or the caller isn't a member. Used by the
// read-authz check (view + comment gating).
func (s *Store) RepoVisibleTo(ctx context.Context, repoName, identity string) (string, bool, error) {
	var role string
	err := s.db.QueryRowContext(ctx,
		`SELECT pm.role FROM project_repos pr
		   JOIN project_members pm ON pm.project_id = pr.project_id
		  WHERE pr.repo_name = ? AND pm.identity = ?`, repoName, identity).Scan(&role)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return role, true, nil
}

// VisibleRepoNames returns every repo across the caller's projects (the
// project-scoped list filter set).
func (s *Store) VisibleRepoNames(ctx context.Context, identity string) ([]string, error) {
	return s.queryStrings(ctx,
		`SELECT pr.repo_name FROM project_repos pr
		   JOIN project_members pm ON pm.project_id = pr.project_id
		  WHERE pm.identity = ?`, identity)
}

// ListByRepos returns compact list items for handoffs whose repo is in
// repoNames, newest-first — the project-scoped view. Empty repoNames returns
// nil early (avoids an `IN ()` syntax error).
func (s *Store) ListByRepos(ctx context.Context, repoNames []string, limit int) ([]handoffschema.ListItem, error) {
	if len(repoNames) == 0 {
		return nil, nil
	}
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(repoNames)), ",")
	args := make([]any, 0, len(repoNames)+1)
	for _, r := range repoNames {
		args = append(args, r)
	}
	args = append(args, limit)
	rows, err := s.db.QueryContext(ctx,
		`SELECT h.id, h.sender, h.recipients, h.urgency, h.state, h.created_at,
		        h.repo_name, h.branch, h.headline, h.kind, h.bug_group_id
		   FROM handoffs h
		  WHERE h.repo_name IN (`+placeholders+`)
		  ORDER BY h.created_at DESC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, scanListItem)
}

// ListAll returns compact list items for every handoff, newest-first (admin scope).
func (s *Store) ListAll(ctx context.Context, limit int) ([]handoffschema.ListItem, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT h.id, h.sender, h.recipients, h.urgency, h.state, h.created_at,
		        h.repo_name, h.branch, h.headline, h.kind, h.bug_group_id
		   FROM handoffs h
		  ORDER BY h.created_at DESC LIMIT ?`, limit)
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
