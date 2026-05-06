package inbox

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/cc-collaboration/pkg/handoffschema"
)

func TestUnreadRoundTrip(t *testing.T) {
	root := t.TempDir()

	mk := func(handoffID string, commentID int64, sender, body string) handoffschema.Comment {
		return handoffschema.Comment{
			ID:        commentID,
			HandoffID: handoffID,
			Sender:    sender,
			Body:      body,
			CreatedAt: time.Unix(1700000000+commentID, 0).UTC(),
		}
	}

	pkgDirA := filepath.Join(root, "h_A")
	pkgDirB := filepath.Join(root, "h_B")
	if err := os.MkdirAll(pkgDirA, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(pkgDirB, 0o755); err != nil {
		t.Fatal(err)
	}

	// Write 3 markers across 2 handoffs. Insert out of order to verify FIFO sort.
	for _, c := range []handoffschema.Comment{
		mk("h_A", 3, "alex@frontend", "looks good"),
		mk("h_B", 1, "alex@frontend", "what's the auth scheme?"),
		mk("h_A", 2, "alex@frontend", "thanks for the brief"),
	} {
		dir := filepath.Join(root, c.HandoffID)
		if err := WriteUnread(dir, c); err != nil {
			t.Fatalf("WriteUnread %d: %v", c.ID, err)
		}
	}

	// Verify on-disk layout: <root>/<id>/unread/<commentID>.json
	for _, want := range []string{
		filepath.Join(pkgDirA, "unread", "2.json"),
		filepath.Join(pkgDirA, "unread", "3.json"),
		filepath.Join(pkgDirB, "unread", "1.json"),
	} {
		if _, err := os.Stat(want); err != nil {
			t.Errorf("missing marker %s: %v", want, err)
		}
	}

	entries, err := ListUnread(root)
	if err != nil {
		t.Fatalf("ListUnread: %v", err)
	}
	if got, want := len(entries), 3; got != want {
		t.Fatalf("got %d entries, want %d", got, want)
	}
	wantIDs := []int64{1, 2, 3}
	for i, e := range entries {
		if e.Comment.ID != wantIDs[i] {
			t.Errorf("entry[%d] id=%d, want %d (FIFO order broken)", i, e.Comment.ID, wantIDs[i])
		}
	}
	if entries[0].HandoffID != "h_B" || entries[1].HandoffID != "h_A" || entries[2].HandoffID != "h_A" {
		t.Errorf("HandoffID FIFO mismatch: %v / %v / %v",
			entries[0].HandoffID, entries[1].HandoffID, entries[2].HandoffID)
	}
	if entries[1].Comment.Body != "thanks for the brief" {
		t.Errorf("payload not round-tripped: got %q", entries[1].Comment.Body)
	}

	ClearUnread(entries)

	again, err := ListUnread(root)
	if err != nil {
		t.Fatalf("ListUnread after clear: %v", err)
	}
	if len(again) != 0 {
		t.Errorf("expected 0 entries after clear, got %d", len(again))
	}

	// Tolerate clearing already-cleared entries (idempotent / safe re-clear).
	ClearUnread(entries)
}

func TestListUnreadMissingDirReturnsNil(t *testing.T) {
	got, err := ListUnread(filepath.Join(t.TempDir(), "does-not-exist"))
	if err != nil {
		t.Fatalf("expected nil error for missing dir, got %v", err)
	}
	if got != nil {
		t.Errorf("expected nil entries, got %v", got)
	}
}
