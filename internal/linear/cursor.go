package linear

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/cc-collaboration/internal/config"
)

// CursorFile is the JSON layout written next to the user-level config so the
// poller / sync command can resume across restarts. Notifications are
// user-scoped (one personal token sees one user's inbox), so the cursor
// lives at user-level too — not per-repo.
type CursorFile struct {
	LastSeen time.Time `json:"last_seen"`
}

// CursorPath returns the absolute path of linear-cursor.json next to the
// user's cc-handoff config.
func CursorPath() (string, error) {
	cfg, err := config.UserConfigPath()
	if err != nil {
		return "", err
	}
	return filepath.Join(filepath.Dir(cfg), "linear-cursor.json"), nil
}

// LoadCursor returns the persisted last-seen timestamp, or the zero Time when
// the file doesn't exist (callers treat that as "use now as baseline").
func LoadCursor(path string) (time.Time, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return time.Time{}, nil
		}
		return time.Time{}, fmt.Errorf("read %s: %w", path, err)
	}
	var c CursorFile
	if err := json.Unmarshal(b, &c); err != nil {
		return time.Time{}, fmt.Errorf("parse %s: %w", path, err)
	}
	return c.LastSeen, nil
}

// SaveCursor writes the new last-seen timestamp atomically (tmp + rename) so
// a crash mid-write can't leave a corrupt JSON behind.
func SaveCursor(path string, t time.Time) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.Marshal(CursorFile{LastSeen: t.UTC()})
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
