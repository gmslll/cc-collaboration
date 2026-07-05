package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// GetSetting returns the stored JSON value for (identity, key) and whether a
// row exists. A missing row is ("", false, nil) — not an error — so callers can
// fall back to a client-side default. Settings are strictly per-identity: there
// is no cross-user read path, which is what lets a user's own devices sync a
// shared value (same identity) while staying isolated from everyone else.
func (s *Store) GetSetting(ctx context.Context, identity, key string) (string, bool, error) {
	var value string
	err := s.db.QueryRowContext(ctx,
		`SELECT value FROM user_settings WHERE identity = ? AND key = ?`,
		identity, key).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("get setting: %w", err)
	}
	return value, true, nil
}

// SetSetting upserts the opaque JSON value for (identity, key), stamping
// updated_at (epoch ms, matching the todos table). The value is stored verbatim;
// the relay never parses it.
func (s *Store) SetSetting(ctx context.Context, identity, key, value string) error {
	_, err := s.db.ExecContext(ctx, `
INSERT INTO user_settings (identity, key, value, updated_at)
VALUES (?, ?, ?, ?)
ON CONFLICT(identity, key) DO UPDATE SET
  value = excluded.value,
  updated_at = excluded.updated_at`,
		identity, key, value, time.Now().UnixMilli())
	if err != nil {
		return fmt.Errorf("set setting: %w", err)
	}
	return nil
}
