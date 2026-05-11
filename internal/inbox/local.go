package inbox

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/cc-collaboration/pkg/handoffschema"
)

// LocalItem is the metadata view ListLocal returns for one materialized
// handoff. It mirrors the fields callers want for table / json output (CLI
// `cc-handoff inbox` and MCP `list_local_inbox` both consume this), so the
// directory walk + package.json decode + flag detection lives in one place.
type LocalItem struct {
	ID            string    `json:"id"`
	Sender        string    `json:"sender"`
	Recipient     string    `json:"recipient"`
	Repo          string    `json:"repo"`
	Urgency       string    `json:"urgency"`
	CreatedAt     time.Time `json:"created_at"`
	Retracted     bool      `json:"retracted"`
	HasComments   bool      `json:"has_comments"`
	Path          string    `json:"path"`
	AmendsHandoff string    `json:"amends_handoff,omitempty"`
}

// ListLocal returns the materialized handoffs under inboxDir, newest-first.
// Non-package directories and unparseable package.json files are silently
// skipped — they're not necessarily errors (could be partial materialization
// in flight or unrelated user files in the inbox dir). A missing inboxDir
// returns (nil, nil) so first-time callers don't need to special-case it.
func ListLocal(inboxDir string) ([]LocalItem, error) {
	entries, err := os.ReadDir(inboxDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []LocalItem
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		dir := filepath.Join(inboxDir, e.Name())
		raw, err := os.ReadFile(filepath.Join(dir, "package.json"))
		if err != nil {
			continue
		}
		var p handoffschema.Package
		if err := json.Unmarshal(raw, &p); err != nil {
			continue
		}
		_, retractedErr := os.Stat(filepath.Join(dir, "RETRACTED.md"))
		_, commentsErr := os.Stat(filepath.Join(dir, "comments.md"))
		out = append(out, LocalItem{
			ID:            p.ID,
			Sender:        p.Sender,
			Recipient:     p.Recipient,
			Repo:          p.Repo.Name,
			Urgency:       string(p.Urgency),
			CreatedAt:     p.CreatedAt,
			Retracted:     retractedErr == nil,
			HasComments:   commentsErr == nil,
			Path:          dir,
			AmendsHandoff: p.AmendsHandoff,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	return out, nil
}
