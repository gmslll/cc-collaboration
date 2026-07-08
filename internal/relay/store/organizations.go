package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

const (
	OrgRoleOwner  = "owner"
	OrgRoleAdmin  = "admin"
	OrgRoleMember = "member"
	OrgRoleGuest  = "guest"
)

func ValidOrgRole(role string) bool {
	return role == OrgRoleOwner || role == OrgRoleAdmin || role == OrgRoleMember || role == OrgRoleGuest
}

func OrgRoleCanManage(role string) bool {
	return role == OrgRoleOwner || role == OrgRoleAdmin
}

type Organization struct {
	ID            string    `json:"id"`
	Name          string    `json:"name"`
	OwnerIdentity string    `json:"owner_identity"`
	CreatedAt     time.Time `json:"created_at"`
}

type OrganizationMember struct {
	Identity    string `json:"identity"`
	Role        string `json:"role"`
	DisplayName string `json:"display_name"`
}

type OrganizationRole struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Role string `json:"role"`
}

func (s *Store) CreateOrganization(ctx context.Context, id, name, owner string, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO organizations(id, name, owner_identity, created_at) VALUES(?, ?, ?, ?)`,
		id, name, owner, now.UnixMilli()); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO organization_members(org_id, identity, role) VALUES(?, ?, ?)`,
		id, owner, OrgRoleOwner); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) EnsureDefaultOrganization(ctx context.Context, owner string, now time.Time) (Organization, error) {
	id := defaultOrganizationID(owner)
	if org, err := s.GetOrganization(ctx, id); err == nil {
		return org, nil
	} else if !errors.Is(err, ErrNotFound) {
		return Organization{}, err
	}
	name := owner + "'s team"
	if err := s.CreateOrganization(ctx, id, name, owner, now); err != nil {
		return Organization{}, err
	}
	return s.GetOrganization(ctx, id)
}

func (s *Store) GetOrganization(ctx context.Context, id string) (Organization, error) {
	return scanOrganization(s.db.QueryRowContext(ctx,
		`SELECT id, name, owner_identity, created_at FROM organizations WHERE id = ?`, id))
}

func (s *Store) ListOrganizations(ctx context.Context) ([]Organization, error) {
	return s.queryOrganizations(ctx, `SELECT id, name, owner_identity, created_at FROM organizations ORDER BY name`)
}

func (s *Store) ListOrganizationsForIdentity(ctx context.Context, identity string) ([]Organization, error) {
	return s.queryOrganizations(ctx,
		`SELECT o.id, o.name, o.owner_identity, o.created_at
		   FROM organizations o
		   JOIN organization_members om ON om.org_id = o.id
		  WHERE om.identity = ? ORDER BY o.name`, identity)
}

func (s *Store) MemberOrganizations(ctx context.Context, identity string) ([]OrganizationRole, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT o.id, o.name, om.role
		   FROM organization_members om
		   JOIN organizations o ON o.id = om.org_id
		  WHERE om.identity = ? ORDER BY o.name`, identity)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (OrganizationRole, error) {
		var org OrganizationRole
		err := r.Scan(&org.ID, &org.Name, &org.Role)
		return org, err
	})
}

func (s *Store) ListOrganizationMembers(ctx context.Context, orgID string) ([]OrganizationMember, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT om.identity, om.role, COALESCE(u.display_name, '')
		   FROM organization_members om
		   LEFT JOIN users u ON u.identity = om.identity
		  WHERE om.org_id = ? ORDER BY om.identity`, orgID)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (OrganizationMember, error) {
		var m OrganizationMember
		err := r.Scan(&m.Identity, &m.Role, &m.DisplayName)
		return m, err
	})
}

func (s *Store) OrganizationMemberRole(ctx context.Context, orgID, identity string) (string, bool, error) {
	var role string
	err := s.db.QueryRowContext(ctx,
		`SELECT role FROM organization_members WHERE org_id = ? AND identity = ?`, orgID, identity).Scan(&role)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return role, true, nil
}

func (s *Store) AddOrganizationMember(ctx context.Context, orgID, identity, role string) error {
	if err := s.guardLastOrgOwner(ctx, orgID, identity, role); err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx,
		`INSERT INTO organization_members(org_id, identity, role) VALUES(?, ?, ?)
		 ON CONFLICT(org_id, identity) DO UPDATE SET role = excluded.role`,
		orgID, identity, role)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	if role != OrgRoleOwner {
		if err := replaceOrganizationOwnerIdentity(ctx, tx, orgID, identity); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) RemoveOrganizationMember(ctx context.Context, orgID, identity string) error {
	role, ok, err := s.OrganizationMemberRole(ctx, orgID, identity)
	if err != nil {
		return err
	}
	if !ok {
		return ErrNotFound
	}
	if role == OrgRoleOwner {
		owners, err := s.CountOrganizationOwners(ctx, orgID)
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
	if role == OrgRoleOwner {
		if err := replaceOrganizationOwnerIdentity(ctx, tx, orgID, identity); err != nil {
			return err
		}
	}
	if err := removeOrganizationProjectMemberships(ctx, tx, orgID, identity); err != nil {
		return err
	}
	res, err := tx.ExecContext(ctx, `DELETE FROM organization_members WHERE org_id = ? AND identity = ?`, orgID, identity)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return tx.Commit()
}

func (s *Store) CountOrganizationOwners(ctx context.Context, orgID string) (int, error) {
	var count int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM organization_members WHERE org_id = ? AND role = ?`, orgID, OrgRoleOwner).Scan(&count)
	return count, err
}

func (s *Store) ListProjectsForOrganization(ctx context.Context, orgID string) ([]Project, error) {
	return s.queryProjects(ctx,
		`SELECT id, org_id, name, owner_identity, created_at FROM projects WHERE org_id = ? ORDER BY name`, orgID)
}

func scanOrganization(row scanner) (Organization, error) {
	var (
		org       Organization
		createdMS int64
	)
	if err := row.Scan(&org.ID, &org.Name, &org.OwnerIdentity, &createdMS); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Organization{}, ErrNotFound
		}
		return Organization{}, err
	}
	org.CreatedAt = time.UnixMilli(createdMS).UTC()
	return org, nil
}

func (s *Store) queryOrganizations(ctx context.Context, query string, args ...any) ([]Organization, error) {
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (Organization, error) { return scanOrganization(r) })
}

func (s *Store) guardLastOrgOwner(ctx context.Context, orgID, identity, nextRole string) error {
	current, ok, err := s.OrganizationMemberRole(ctx, orgID, identity)
	if err != nil || !ok || current != OrgRoleOwner || nextRole == OrgRoleOwner {
		return err
	}
	owners, err := s.CountOrganizationOwners(ctx, orgID)
	if err != nil {
		return err
	}
	if owners <= 1 {
		return ErrLastOwner
	}
	return nil
}

func replaceOrganizationOwnerIdentity(ctx context.Context, tx *sql.Tx, orgID, removedOrDemotedOwner string) error {
	var current string
	if err := tx.QueryRowContext(ctx,
		`SELECT owner_identity FROM organizations WHERE id = ?`, orgID).Scan(&current); err != nil {
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
		`SELECT identity FROM organization_members
		  WHERE org_id = ? AND role = ? AND identity != ?
		  ORDER BY identity LIMIT 1`,
		orgID, OrgRoleOwner, removedOrDemotedOwner).Scan(&replacement); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrLastOwner
		}
		return err
	}
	_, err := tx.ExecContext(ctx,
		`UPDATE organizations SET owner_identity = ? WHERE id = ?`, replacement, orgID)
	return err
}

func removeOrganizationProjectMemberships(ctx context.Context, tx *sql.Tx, orgID, identity string) error {
	rows, err := tx.QueryContext(ctx,
		`SELECT p.id, pm.role
		   FROM projects p
		   JOIN project_members pm ON pm.project_id = p.id
		  WHERE p.org_id = ? AND pm.identity = ?`,
		orgID, identity)
	if err != nil {
		return err
	}
	var memberships []struct {
		projectID string
		role      string
	}
	for rows.Next() {
		var m struct {
			projectID string
			role      string
		}
		if err := rows.Scan(&m.projectID, &m.role); err != nil {
			rows.Close()
			return err
		}
		memberships = append(memberships, m)
	}
	if err := rows.Close(); err != nil {
		return err
	}
	if err := rows.Err(); err != nil {
		return err
	}
	for _, m := range memberships {
		if m.role != RoleOwner {
			continue
		}
		var owners int
		if err := tx.QueryRowContext(ctx,
			`SELECT COUNT(*) FROM project_members WHERE project_id = ? AND role = ?`,
			m.projectID, RoleOwner).Scan(&owners); err != nil {
			return err
		}
		if owners <= 1 {
			return ErrLastOwner
		}
		if err := replaceProjectOwnerIdentity(ctx, tx, m.projectID, identity); err != nil {
			return err
		}
	}
	_, err = tx.ExecContext(ctx,
		`DELETE FROM project_members
		  WHERE identity = ?
		    AND project_id IN (SELECT id FROM projects WHERE org_id = ?)`,
		identity, orgID)
	return err
}
