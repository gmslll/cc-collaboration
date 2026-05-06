package inbox

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/cc-collaboration/pkg/handoffschema"
)

// UnreadDir is the per-handoff directory where the watch daemon drops one
// JSON file per unread partner comment. The Stop hook drains it.
func UnreadDir(packageDir string) string { return filepath.Join(packageDir, "unread") }

// UnreadEntry pairs a Comment with its on-disk marker path so the Stop hook
// can clear markers it actually delivered.
type UnreadEntry struct {
	HandoffID string
	Path      string
	Comment   handoffschema.Comment
}

// WriteUnread persists one comment as <pkgDir>/unread/<id>.json. Atomic
// (tmp+rename) so a crash mid-write can't leave a half-written marker that
// fails to unmarshal — that file would be silently skipped by ListUnread,
// stranding the comment forever.
func WriteUnread(packageDir string, c handoffschema.Comment) error {
	dir := UnreadDir(packageDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, strconv.FormatInt(c.ID, 10)+".json")
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

// ListUnread scans every <inboxDir>/<id>/unread/*.json across all materialized
// handoffs and returns the entries in FIFO order (Comment.ID ascending).
// Missing inboxDir returns (nil, nil) for first-time callers.
func ListUnread(inboxDir string) ([]UnreadEntry, error) {
	entries, err := os.ReadDir(inboxDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []UnreadEntry
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		handoffDir := filepath.Join(inboxDir, e.Name())
		unreadDir := UnreadDir(handoffDir)
		files, err := os.ReadDir(unreadDir)
		if err != nil {
			continue
		}
		for _, f := range files {
			if f.IsDir() || !strings.HasSuffix(f.Name(), ".json") {
				continue
			}
			path := filepath.Join(unreadDir, f.Name())
			raw, err := os.ReadFile(path)
			if err != nil {
				continue
			}
			var c handoffschema.Comment
			if err := json.Unmarshal(raw, &c); err != nil {
				continue
			}
			out = append(out, UnreadEntry{HandoffID: e.Name(), Path: path, Comment: c})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Comment.ID < out[j].Comment.ID })
	return out, nil
}

// ClearUnread deletes the marker files of the given entries. Per-file errors
// are logged to stderr and swallowed: a partial failure must not strand
// markers and trigger a wake-loop on the next Stop hook fire.
func ClearUnread(entries []UnreadEntry) {
	for _, e := range entries {
		if err := os.Remove(e.Path); err != nil && !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "warning: clear unread marker %s: %v\n", e.Path, err)
		}
	}
}
