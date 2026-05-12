package inbox

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// LinearLink is the on-disk record that ties a handoff to a Linear issue.
// Written by the sender after creating the issue, read by status/sync flows
// that want to know the issue identifier without round-tripping Linear.
type LinearLink struct {
	HandoffID  string    `json:"handoff_id"`
	Identifier string    `json:"identifier"`
	URL        string    `json:"url,omitempty"`
	LinkedAt   time.Time `json:"linked_at"`
}

// WriteLinearLink writes the binding atomically (tmp + rename, same pattern
// as SaveCursor) to <inboxDir>/sent/<handoffID>/linear.json. Returns the
// absolute path written.
func WriteLinearLink(inboxDir, handoffID, identifier, url string) (string, error) {
	dir := filepath.Join(inboxDir, "sent", handoffID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("create %s: %w", dir, err)
	}
	path := filepath.Join(dir, "linear.json")
	data, err := json.MarshalIndent(LinearLink{
		HandoffID:  handoffID,
		Identifier: identifier,
		URL:        url,
		LinkedAt:   time.Now().UTC(),
	}, "", "  ")
	if err != nil {
		return "", err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return "", fmt.Errorf("write %s: %w", tmp, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return "", fmt.Errorf("rename %s: %w", path, err)
	}
	return path, nil
}
