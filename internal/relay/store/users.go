package store

import (
	"context"
	"database/sql"
	"errors"
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
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO users(identity, password_hash, display_name, is_admin, disabled, created_at)
		 VALUES(?, ?, ?, ?, ?, ?)`,
		u.Identity, u.PasswordHash, u.DisplayName, boolToInt(u.IsAdmin), boolToInt(u.Disabled), now.UnixMilli())
	return err
}

// GetUser returns the account for identity, or ErrNotFound.
func (s *Store) GetUser(ctx context.Context, identity string) (User, error) {
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
	var isAdmin int
	err := s.db.QueryRowContext(ctx, `SELECT is_admin FROM users WHERE identity = ?`, identity).Scan(&isAdmin)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return isAdmin != 0, nil
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
	return s.execAffecting(ctx, `UPDATE users SET password_hash = ? WHERE identity = ?`, hash, identity)
}

func (s *Store) SetAdmin(ctx context.Context, identity string, isAdmin bool) error {
	return s.execAffecting(ctx, `UPDATE users SET is_admin = ? WHERE identity = ?`, boolToInt(isAdmin), identity)
}

func (s *Store) SetDisabled(ctx context.Context, identity string, disabled bool) error {
	return s.execAffecting(ctx, `UPDATE users SET disabled = ? WHERE identity = ?`, boolToInt(disabled), identity)
}

// --- sessions (UI login) ---

// CreateSession records a login session keyed by the token hash, expiring at expires.
func (s *Store) CreateSession(ctx context.Context, tokenHash, identity string, now, expires time.Time) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO sessions(token_hash, identity, created_at, expires_at) VALUES(?, ?, ?, ?)`,
		tokenHash, identity, now.UnixMilli(), expires.UnixMilli())
	return err
}

// SessionIdentity returns the identity for a non-expired session token hash.
func (s *Store) SessionIdentity(ctx context.Context, tokenHash string, now time.Time) (string, bool, error) {
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
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO machine_tokens(token_hash, identity, label, created_at) VALUES(?, ?, ?, ?)`,
		tokenHash, identity, label, now.UnixMilli())
	return err
}

// SeedMachineToken inserts a token from the legacy tokens.json, ignoring it if
// already present (idempotent across restarts).
func (s *Store) SeedMachineToken(ctx context.Context, tokenHash, identity string, now time.Time) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT OR IGNORE INTO machine_tokens(token_hash, identity, label, created_at) VALUES(?, ?, 'seed', ?)`,
		tokenHash, identity, now.UnixMilli())
	return err
}

func (s *Store) MachineTokenIdentity(ctx context.Context, tokenHash string) (string, bool, error) {
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
	return s.execAffecting(ctx,
		`DELETE FROM machine_tokens WHERE token_hash = ? AND identity = ?`, tokenHash, identity)
}
