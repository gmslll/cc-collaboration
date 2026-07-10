package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"
)

const (
	InvitationScopeOrg     = "org"
	InvitationScopeProject = "project"
)

type Invitation struct {
	ID              string    `json:"id"`
	Scope           string    `json:"scope"`
	OrgID           string    `json:"org_id"`
	OrgName         string    `json:"org_name,omitempty"`
	ProjectID       string    `json:"project_id,omitempty"`
	ProjectName     string    `json:"project_name,omitempty"`
	Identity        string    `json:"identity"`
	Role            string    `json:"role"`
	InviterIdentity string    `json:"inviter_identity"`
	CreatedAt       time.Time `json:"created_at"`
}

func (s *Store) CreateOrganizationInvitation(ctx context.Context, id, orgID, identity, role, inviter string, now time.Time) (Invitation, error) {
	id = strings.TrimSpace(id)
	orgID = strings.TrimSpace(orgID)
	identity = strings.TrimSpace(identity)
	role = strings.TrimSpace(role)
	inviter = strings.TrimSpace(inviter)
	if id == "" || orgID == "" || identity == "" || inviter == "" || !ValidOrgRole(role) {
		return Invitation{}, ErrInvalid
	}
	if active, err := s.UserActive(ctx, identity); err != nil {
		return Invitation{}, err
	} else if !active {
		return Invitation{}, ErrForbidden
	}
	if _, err := s.GetOrganization(ctx, orgID); err != nil {
		return Invitation{}, err
	}
	if _, ok, err := s.OrganizationMemberRole(ctx, orgID, identity); err != nil {
		return Invitation{}, err
	} else if ok {
		return Invitation{}, ErrConflict
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO invitations(id, scope, org_id, project_id, identity, role, inviter_identity, created_at)
		 VALUES(?, ?, ?, '', ?, ?, ?, ?)
		 ON CONFLICT(scope, org_id, project_id, identity)
		 DO UPDATE SET id = excluded.id, role = excluded.role, inviter_identity = excluded.inviter_identity, created_at = excluded.created_at`,
		id, InvitationScopeOrg, orgID, identity, role, inviter, now.UnixMilli())
	if err != nil {
		return Invitation{}, err
	}
	return s.GetInvitation(ctx, id)
}

func (s *Store) CreateProjectInvitation(ctx context.Context, id, projectID, identity, role, inviter string, now time.Time) (Invitation, error) {
	id = strings.TrimSpace(id)
	projectID = strings.TrimSpace(projectID)
	identity = strings.TrimSpace(identity)
	role = strings.TrimSpace(role)
	inviter = strings.TrimSpace(inviter)
	if id == "" || projectID == "" || identity == "" || inviter == "" || !ValidRole(role) {
		return Invitation{}, ErrInvalid
	}
	if active, err := s.UserActive(ctx, identity); err != nil {
		return Invitation{}, err
	} else if !active {
		return Invitation{}, ErrForbidden
	}
	project, err := s.GetProject(ctx, projectID)
	if err != nil {
		return Invitation{}, err
	}
	if _, ok, err := s.MemberRole(ctx, projectID, identity); err != nil {
		return Invitation{}, err
	} else if ok {
		return Invitation{}, ErrConflict
	}
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO invitations(id, scope, org_id, project_id, identity, role, inviter_identity, created_at)
		 VALUES(?, ?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(scope, org_id, project_id, identity)
		 DO UPDATE SET id = excluded.id, role = excluded.role, inviter_identity = excluded.inviter_identity, created_at = excluded.created_at`,
		id, InvitationScopeProject, project.OrgID, projectID, identity, role, inviter, now.UnixMilli())
	if err != nil {
		return Invitation{}, err
	}
	return s.GetInvitation(ctx, id)
}

func (s *Store) GetInvitation(ctx context.Context, id string) (Invitation, error) {
	id = strings.TrimSpace(id)
	return scanInvitation(s.db.QueryRowContext(ctx, invitationSelectSQL+` WHERE i.id = ?`, id))
}

func (s *Store) ListInvitationsForIdentity(ctx context.Context, identity string) ([]Invitation, error) {
	identity = strings.TrimSpace(identity)
	if identity == "" {
		return nil, nil
	}
	return s.queryInvitations(ctx, invitationSelectSQL+` WHERE i.identity = ? ORDER BY i.created_at DESC`, identity)
}

func (s *Store) ListOrganizationInvitations(ctx context.Context, orgID string) ([]Invitation, error) {
	orgID = strings.TrimSpace(orgID)
	return s.queryInvitations(ctx, invitationSelectSQL+` WHERE i.scope = ? AND i.org_id = ? ORDER BY i.created_at DESC`, InvitationScopeOrg, orgID)
}

func (s *Store) ListProjectInvitations(ctx context.Context, projectID string) ([]Invitation, error) {
	projectID = strings.TrimSpace(projectID)
	return s.queryInvitations(ctx, invitationSelectSQL+` WHERE i.scope = ? AND i.project_id = ? ORDER BY i.created_at DESC`, InvitationScopeProject, projectID)
}

func (s *Store) DeleteInvitation(ctx context.Context, id string) error {
	id = strings.TrimSpace(id)
	return s.execAffecting(ctx, `DELETE FROM invitations WHERE id = ?`, id)
}

func (s *Store) DeclineInvitation(ctx context.Context, id, identity string) error {
	id = strings.TrimSpace(id)
	identity = strings.TrimSpace(identity)
	return s.execAffecting(ctx, `DELETE FROM invitations WHERE id = ? AND identity = ?`, id, identity)
}

func (s *Store) AcceptInvitation(ctx context.Context, id, identity string) error {
	id = strings.TrimSpace(id)
	identity = strings.TrimSpace(identity)
	if id == "" || identity == "" {
		return ErrInvalid
	}
	active, err := s.UserActive(ctx, identity)
	if err != nil {
		return err
	}
	if !active {
		return ErrForbidden
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var inv Invitation
	var createdMS int64
	err = tx.QueryRowContext(ctx,
		`SELECT id, scope, org_id, project_id, identity, role, inviter_identity, created_at
		   FROM invitations WHERE id = ? AND identity = ?`,
		id, identity).
		Scan(&inv.ID, &inv.Scope, &inv.OrgID, &inv.ProjectID, &inv.Identity, &inv.Role, &inv.InviterIdentity, &createdMS)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	inv.CreatedAt = time.UnixMilli(createdMS).UTC()
	switch inv.Scope {
	case InvitationScopeOrg:
		if !ValidOrgRole(inv.Role) {
			return ErrInvalid
		}
		if exists, err := organizationExists(ctx, tx, inv.OrgID); err != nil {
			return err
		} else if !exists {
			if err := deleteMissingInvitation(ctx, tx, id); err != nil {
				return err
			}
			return ErrNotFound
		}
		role, err := strongestOrganizationInvitationRole(ctx, tx, inv.OrgID, identity, inv.Role)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO organization_members(org_id, identity, role) VALUES(?, ?, ?)
			 ON CONFLICT(org_id, identity) DO UPDATE SET role = excluded.role`,
			inv.OrgID, identity, role); err != nil {
			return err
		}
	case InvitationScopeProject:
		if !ValidRole(inv.Role) {
			return ErrInvalid
		}
		var orgID string
		if err := tx.QueryRowContext(ctx, `SELECT org_id FROM projects WHERE id = ?`, inv.ProjectID).Scan(&orgID); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				if err := deleteMissingInvitation(ctx, tx, id); err != nil {
					return err
				}
				return ErrNotFound
			}
			return err
		}
		orgRole, err := strongestOrganizationInvitationRole(ctx, tx, orgID, identity, OrgRoleMember)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO organization_members(org_id, identity, role) VALUES(?, ?, ?)
			 ON CONFLICT(org_id, identity) DO UPDATE SET role = excluded.role`,
			orgID, identity, orgRole); err != nil {
			return err
		}
		projectRole, err := strongestProjectInvitationRole(ctx, tx, inv.ProjectID, identity, inv.Role)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO project_members(project_id, identity, role) VALUES(?, ?, ?)
			 ON CONFLICT(project_id, identity) DO UPDATE SET role = excluded.role`,
			inv.ProjectID, identity, projectRole); err != nil {
			return err
		}
	default:
		return ErrInvalid
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM invitations WHERE id = ?`, id); err != nil {
		return err
	}
	return tx.Commit()
}

func strongestOrganizationInvitationRole(ctx context.Context, tx *sql.Tx, orgID, identity, invitedRole string) (string, error) {
	var current string
	if err := tx.QueryRowContext(ctx,
		`SELECT role FROM organization_members WHERE org_id = ? AND identity = ?`,
		orgID, identity).Scan(&current); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return invitedRole, nil
		}
		return "", err
	}
	if organizationRoleRank(current) > organizationRoleRank(invitedRole) {
		return current, nil
	}
	return invitedRole, nil
}

func strongestProjectInvitationRole(ctx context.Context, tx *sql.Tx, projectID, identity, invitedRole string) (string, error) {
	var current string
	if err := tx.QueryRowContext(ctx,
		`SELECT role FROM project_members WHERE project_id = ? AND identity = ?`,
		projectID, identity).Scan(&current); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return invitedRole, nil
		}
		return "", err
	}
	if projectRoleRank(current) > projectRoleRank(invitedRole) {
		return current, nil
	}
	return invitedRole, nil
}

func organizationRoleRank(role string) int {
	switch strings.TrimSpace(role) {
	case OrgRoleOwner:
		return 4
	case OrgRoleAdmin:
		return 3
	case OrgRoleMember:
		return 2
	case OrgRoleGuest:
		return 1
	default:
		return 0
	}
}

func projectRoleRank(role string) int {
	switch strings.TrimSpace(role) {
	case RoleOwner:
		return 3
	case RoleMember:
		return 2
	case RoleViewer:
		return 1
	default:
		return 0
	}
}

func organizationExists(ctx context.Context, tx *sql.Tx, orgID string) (bool, error) {
	var exists int
	if err := tx.QueryRowContext(ctx, `SELECT 1 FROM organizations WHERE id = ?`, orgID).Scan(&exists); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

func deleteMissingInvitation(ctx context.Context, tx *sql.Tx, id string) error {
	if _, err := tx.ExecContext(ctx, `DELETE FROM invitations WHERE id = ?`, id); err != nil {
		return err
	}
	return tx.Commit()
}

const invitationSelectSQL = `SELECT i.id, i.scope, i.org_id, COALESCE(o.name, ''), i.project_id, COALESCE(p.name, ''),
       i.identity, i.role, i.inviter_identity, i.created_at
  FROM invitations i
  LEFT JOIN organizations o ON o.id = i.org_id
  LEFT JOIN projects p ON p.id = i.project_id`

func (s *Store) queryInvitations(ctx context.Context, query string, args ...any) ([]Invitation, error) {
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (Invitation, error) {
		return scanInvitationRow(r)
	})
}

func scanInvitation(row scanner) (Invitation, error) {
	inv, err := scanInvitationRow(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Invitation{}, ErrNotFound
	}
	return inv, err
}

func scanInvitationRow(row scanner) (Invitation, error) {
	var (
		inv       Invitation
		createdMS int64
	)
	err := row.Scan(
		&inv.ID, &inv.Scope, &inv.OrgID, &inv.OrgName, &inv.ProjectID, &inv.ProjectName,
		&inv.Identity, &inv.Role, &inv.InviterIdentity, &createdMS,
	)
	if err != nil {
		return Invitation{}, err
	}
	inv.CreatedAt = time.UnixMilli(createdMS).UTC()
	return inv, nil
}
