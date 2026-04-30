package inbox

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// WatchCursor tracks per-repo state the watch daemon needs to resume catch-up
// across restarts. Lives at <repoRoot>/.claude/handoff-inbox/.watch-cursor.json.
type WatchCursor struct {
	LastCommentID int64 `json:"last_comment_id"`
}

const cursorFile = ".watch-cursor.json"

func CursorPath(repoRoot string) string {
	return filepath.Join(InboxDir(repoRoot), cursorFile)
}

// LoadCursor reads the cursor file. exists=false (no error) when the file is
// absent — the caller decides bootstrap behavior.
func LoadCursor(repoRoot string) (WatchCursor, bool, error) {
	path := CursorPath(repoRoot)
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return WatchCursor{}, false, nil
	}
	if err != nil {
		return WatchCursor{}, false, fmt.Errorf("read cursor: %w", err)
	}
	var c WatchCursor
	if err := json.Unmarshal(b, &c); err != nil {
		return WatchCursor{}, false, fmt.Errorf("parse cursor %s: %w", path, err)
	}
	return c, true, nil
}

// SaveCursor writes atomically (tmp file + rename) so a crash mid-write can't
// leave a half-written cursor that fails to parse on next start.
func SaveCursor(repoRoot string, c WatchCursor) error {
	path := CursorPath(repoRoot)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
