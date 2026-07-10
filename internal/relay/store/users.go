package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"
)

// User is a relay account. The identity doubles as the login username and the
// handoff identity. PasswordHash is never serialized to clients.
type User struct {
	Identity     string    `json:"identity"`
	DisplayName  string    `json:"display_name,omitempty"`
	IsAdmin      bool      `json:"is_admin"`
	Disabled     bool      `json:"disabled"`
	CreatedAt    time.Time `json:"created_at"`
	PasswordHash string    `json:"-"`
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// CreateUser inserts a new account. Returns an error (UNIQUE violation) when the
// identity already exists.
func (s *Store) CreateUser(ctx context.Context, u User, now time.Time) error {
	u.Identity = strings.TrimSpace(u.Identity)
	u.DisplayName = strings.TrimSpace(u.DisplayName)
	if u.Identity == "" {
		return ErrInvalid
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO users(identity, password_hash, display_name, is_admin, disabled, created_at)
		 VALUES(?, ?, ?, ?, ?, ?)`,
		u.Identity, u.PasswordHash, u.DisplayName, boolToInt(u.IsAdmin), boolToInt(u.Disabled), now.UnixMilli())
	return err
}

// GetUser returns the account for identity, or ErrNotFound.
func (s *Store) GetUser(ctx context.Context, identity string) (User, error) {
	identity = strings.TrimSpace(identity)
	if identity == "" {
		return User{}, ErrNotFound
	}
	var (
		u                 User
		isAdmin, disabled int
		createdMS         int64
	)
	err := s.db.QueryRowContext(ctx,
		`SELECT identity, password_hash, display_name, is_admin, disabled, created_at
		   FROM users WHERE identity = ?`, identity).
		Scan(&u.Identity, &u.PasswordHash, &u.DisplayName, &isAdmin, &disabled, &createdMS)
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, ErrNotFound
	}
	if err != nil {
		return User{}, err
	}
	u.IsAdmin = isAdmin != 0
	u.Disabled = disabled != 0
	u.CreatedAt = time.UnixMilli(createdMS).UTC()
	return u, nil
}

// ListUsers returns all accounts, sorted by identity. PasswordHash is cleared.
func (s *Store) ListUsers(ctx context.Context) ([]User, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT identity, display_name, is_admin, disabled, created_at FROM users ORDER BY identity`)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (User, error) {
		var (
			u                 User
			isAdmin, disabled int
			createdMS         int64
		)
		if err := r.Scan(&u.Identity, &u.DisplayName, &isAdmin, &disabled, &createdMS); err != nil {
			return User{}, err
		}
		u.IsAdmin = isAdmin != 0
		u.Disabled = disabled != 0
		u.CreatedAt = time.UnixMilli(createdMS).UTC()
		return u, nil
	})
}

// UserIsAdmin reports whether identity is a DB-flagged admin. A missing account
// is not an admin (false, nil) — seed admins are layered on at the server level.
func (s *Store) UserIsAdmin(ctx context.Context, identity string) (bool, error) {
	identity = strings.TrimSpace(identity)
	if identity == "" {
		return false, nil
	}
	var isAdmin, disabled int
	err := s.db.QueryRowContext(ctx, `SELECT is_admin, disabled FROM users WHERE identity = ?`, identity).Scan(&isAdmin, &disabled)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return isAdmin != 0 && disabled == 0, nil
}

// UserActive reports whether an identity is allowed to authenticate. Missing
// DB users are allowed so legacy file-token identities keep working.
func (s *Store) UserActive(ctx context.Context, identity string) (bool, error) {
	identity = strings.TrimSpace(identity)
	if identity == "" {
		return false, nil
	}
	var disabled int
	err := s.db.QueryRowContext(ctx, `SELECT disabled FROM users WHERE identity = ?`, identity).Scan(&disabled)
	if errors.Is(err, sql.ErrNoRows) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	return disabled == 0, nil
}

func (s *Store) KnownIdentities(ctx context.Context) ([]string, error) {
	return s.queryStrings(ctx, `
SELECT identity FROM users WHERE disabled = 0
UNION
SELECT mt.identity FROM machine_tokens mt
  LEFT JOIN users u ON u.identity = mt.identity
 WHERE u.identity IS NULL OR u.disabled = 0
ORDER BY identity`)
}

// execAffecting runs a write and maps "0 rows affected" to ErrNotFound, so
// callers can distinguish "no such row" from a successful update.
func (s *Store) execAffecting(ctx context.Context, query string, args ...any) error {
	res, err := s.db.ExecContext(ctx, query, args...)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) SetPasswordHash(ctx context.Context, identity, hash string) error {
	identity = strings.TrimSpace(identity)
	if identity == "" {
		return ErrInvalid
	}
	return s.execAffecting(ctx, `UPDATE users SET password_hash = ? WHERE identity = ?`, hash, identity)
}

func (s *Store) SetAdmin(ctx context.Context, identity string, isAdmin bool) error {
	identity = strings.TrimSpace(identity)
	if identity == "" {
		return ErrInvalid
	}
	return s.execAffecting(ctx, `UPDATE users SET is_admin = ? WHERE identity = ?`, boolToInt(isAdmin), identity)
}

func (s *Store) SetDisabled(ctx context.Context, identity string, disabled bool) error {
	identity = strings.TrimSpace(identity)
	if identity == "" {
		return ErrInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx, `UPDATE users SET disabled = ? WHERE identity = ?`, boolToInt(disabled), identity)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	if disabled {
		if err := prepareDisableOwnerIdentity(ctx, tx, identity); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM sessions WHERE identity = ?`, identity); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM machine_tokens WHERE identity = ?`, identity); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM invitations WHERE identity = ?`, identity); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func prepareDisableOwnerIdentity(ctx context.Context, tx *sql.Tx, identity string) error {
	identity = strings.TrimSpace(identity)
	orgRows, err := tx.QueryContext(ctx,
		`SELECT org_id FROM organization_members WHERE identity = ? AND role = ?`,
		identity, OrgRoleOwner)
	if err != nil {
		return err
	}
	var orgIDs []string
	for orgRows.Next() {
		var id string
		if err := orgRows.Scan(&id); err != nil {
			orgRows.Close()
			return err
		}
		orgIDs = append(orgIDs, id)
	}
	if err := orgRows.Close(); err != nil {
		return err
	}
	if err := orgRows.Err(); err != nil {
		return err
	}
	for _, orgID := range orgIDs {
		if orgID == defaultOrganizationID(identity) {
			deleted, err := deleteEmptyDefaultOrganization(ctx, tx, orgID, identity)
			if err != nil {
				return err
			}
			if deleted {
				continue
			}
		}
		if err := requireOtherActiveOrgOwner(ctx, tx, orgID, identity); err != nil {
			return err
		}
		if err := replaceOrganizationOwnerIdentity(ctx, tx, orgID, identity); err != nil {
			return err
		}
	}

	projectRows, err := tx.QueryContext(ctx,
		`SELECT project_id FROM project_members WHERE identity = ? AND role = ?`,
		identity, RoleOwner)
	if err != nil {
		return err
	}
	var projectIDs []string
	for projectRows.Next() {
		var id string
		if err := projectRows.Scan(&id); err != nil {
			projectRows.Close()
			return err
		}
		projectIDs = append(projectIDs, id)
	}
	if err := projectRows.Close(); err != nil {
		return err
	}
	if err := projectRows.Err(); err != nil {
		return err
	}
	for _, projectID := range projectIDs {
		if err := requireOtherActiveProjectOwner(ctx, tx, projectID, identity); err != nil {
			return err
		}
		if err := replaceProjectOwnerIdentity(ctx, tx, projectID, identity); err != nil {
			return err
		}
	}
	return nil
}

func deleteEmptyDefaultOrganization(ctx context.Context, tx *sql.Tx, orgID, owner string) (bool, error) {
	var currentOwner string
	if err := tx.QueryRowContext(ctx,
		`SELECT owner_identity FROM organizations WHERE id = ?`, orgID).Scan(&currentOwner); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return false, ErrNotFound
		}
		return false, err
	}
	if currentOwner != owner {
		return false, nil
	}
	var members int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM organization_members WHERE org_id = ?`, orgID).Scan(&members); err != nil {
		return false, err
	}
	var projects int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM projects WHERE org_id = ?`, orgID).Scan(&projects); err != nil {
		return false, err
	}
	if members != 1 || projects != 0 {
		return false, nil
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM invitations WHERE org_id = ?`, orgID); err != nil {
		return false, err
	}
	_, err := tx.ExecContext(ctx, `DELETE FROM organizations WHERE id = ?`, orgID)
	if err != nil {
		return false, err
	}
	return true, nil
}

func requireOtherActiveOrgOwner(ctx context.Context, tx *sql.Tx, orgID, disabledOwner string) error {
	var owners int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*)
		   FROM organization_members om
		   LEFT JOIN users u ON u.identity = om.identity
		  WHERE om.org_id = ? AND om.role = ? AND om.identity != ?
		    AND (u.identity IS NULL OR u.disabled = 0)`,
		orgID, OrgRoleOwner, disabledOwner).Scan(&owners); err != nil {
		return err
	}
	if owners == 0 {
		return ErrLastOwner
	}
	return nil
}

func requireOtherActiveProjectOwner(ctx context.Context, tx *sql.Tx, projectID, disabledOwner string) error {
	var owners int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*)
		   FROM project_members pm
		   LEFT JOIN users u ON u.identity = pm.identity
		  WHERE pm.project_id = ? AND pm.role = ? AND pm.identity != ?
		    AND (u.identity IS NULL OR u.disabled = 0)`,
		projectID, RoleOwner, disabledOwner).Scan(&owners); err != nil {
		return err
	}
	if owners == 0 {
		return ErrLastOwner
	}
	return nil
}

// --- sessions (UI login) ---

// CreateSession records a login session keyed by the token hash, expiring at expires.
func (s *Store) CreateSession(ctx context.Context, tokenHash, identity string, now, expires time.Time) error {
	tokenHash = strings.TrimSpace(tokenHash)
	identity = strings.TrimSpace(identity)
	if tokenHash == "" || identity == "" {
		return ErrInvalid
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO sessions(token_hash, identity, created_at, expires_at) VALUES(?, ?, ?, ?)`,
		tokenHash, identity, now.UnixMilli(), expires.UnixMilli())
	return err
}

// SessionIdentity returns the identity for a non-expired session token hash.
func (s *Store) SessionIdentity(ctx context.Context, tokenHash string, now time.Time) (string, bool, error) {
	tokenHash = strings.TrimSpace(tokenHash)
	var identity string
	err := s.db.QueryRowContext(ctx,
		`SELECT identity FROM sessions WHERE token_hash = ? AND expires_at > ?`, tokenHash, now.UnixMilli()).
		Scan(&identity)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return identity, true, nil
}

func (s *Store) DeleteSession(ctx context.Context, tokenHash string) error {
	tokenHash = strings.TrimSpace(tokenHash)
	_, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE token_hash = ?`, tokenHash)
	return err
}

func (s *Store) DeleteExpiredSessions(ctx context.Context, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE expires_at <= ?`, now.UnixMilli())
	return err
}

// --- machine tokens (CLI / watch / MCP) ---

// MachineToken is a long-lived bearer credential a user mints for a machine.
// Hash (the token's sha256) doubles as the opaque revoke id; the raw token is
// shown to the user only once at creation and never stored.
type MachineToken struct {
	Hash      string    `json:"id"`
	Identity  string    `json:"identity"`
	Label     string    `json:"label"`
	CreatedAt time.Time `json:"created_at"`
}

func (s *Store) CreateMachineToken(ctx context.Context, tokenHash, identity, label string, now time.Time) error {
	tokenHash = strings.TrimSpace(tokenHash)
	identity = strings.TrimSpace(identity)
	label = strings.TrimSpace(label)
	if tokenHash == "" || identity == "" {
		return ErrInvalid
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO machine_tokens(token_hash, identity, label, created_at) VALUES(?, ?, ?, ?)`,
		tokenHash, identity, label, now.UnixMilli())
	return err
}

// SeedMachineToken inserts a token from the legacy tokens.json, ignoring it if
// already present (idempotent across restarts).
func (s *Store) SeedMachineToken(ctx context.Context, tokenHash, identity string, now time.Time) error {
	tokenHash = strings.TrimSpace(tokenHash)
	identity = strings.TrimSpace(identity)
	if tokenHash == "" || identity == "" {
		return ErrInvalid
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT OR IGNORE INTO machine_tokens(token_hash, identity, label, created_at) VALUES(?, ?, 'seed', ?)`,
		tokenHash, identity, now.UnixMilli())
	return err
}

func (s *Store) MachineTokenIdentity(ctx context.Context, tokenHash string) (string, bool, error) {
	tokenHash = strings.TrimSpace(tokenHash)
	var identity string
	err := s.db.QueryRowContext(ctx, `SELECT identity FROM machine_tokens WHERE token_hash = ?`, tokenHash).Scan(&identity)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return identity, true, nil
}

func (s *Store) ListMachineTokens(ctx context.Context, identity string) ([]MachineToken, error) {
	identity = strings.TrimSpace(identity)
	rows, err := s.db.QueryContext(ctx,
		`SELECT token_hash, identity, label, created_at FROM machine_tokens WHERE identity = ? ORDER BY created_at DESC`, identity)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (MachineToken, error) {
		var (
			t         MachineToken
			createdMS int64
		)
		if err := r.Scan(&t.Hash, &t.Identity, &t.Label, &createdMS); err != nil {
			return MachineToken{}, err
		}
		t.CreatedAt = time.UnixMilli(createdMS).UTC()
		return t, nil
	})
}

// DeleteMachineToken revokes a token, scoped to its owner so a user can only
// revoke their own.
func (s *Store) DeleteMachineToken(ctx context.Context, identity, tokenHash string) error {
	identity = strings.TrimSpace(identity)
	tokenHash = strings.TrimSpace(tokenHash)
	if identity == "" || tokenHash == "" {
		return ErrInvalid
	}
	return s.execAffecting(ctx,
		`DELETE FROM machine_tokens WHERE token_hash = ? AND identity = ?`, tokenHash, identity)
}
