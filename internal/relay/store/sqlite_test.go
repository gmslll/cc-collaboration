package store

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/cc-collaboration/pkg/handoffschema"
)

func openTestStore(t *testing.T) *Store {
	t.Helper()
	st, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func mustInsertHandoff(t *testing.T, st *Store, id, sender, recipient string) {
	t.Helper()
	pkg := &handoffschema.Package{
		ID:            id,
		SchemaVersion: handoffschema.SchemaVersion,
		Sender:        sender,
		Recipient:     recipient,
		Urgency:       handoffschema.UrgencyNormal,
		CreatedAt:     time.Now().UTC(),
		Repo:          handoffschema.Repo{Name: "demo"},
	}
	if err := st.Insert(context.Background(), pkg); err != nil {
		t.Fatalf("insert handoff %s: %v", id, err)
	}
}

func mustInsertComment(t *testing.T, st *Store, handoffID, sender, body string) handoffschema.Comment {
	t.Helper()
	c, err := st.InsertComment(context.Background(), handoffID, sender, body)
	if err != nil {
		t.Fatalf("insert comment on %s: %v", handoffID, err)
	}
	return c
}

// TestListCommentsSinceVisibility verifies the inbox-comment query only
// surfaces comments where the caller participates AND didn't author themselves.
func TestListCommentsSinceVisibility(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	// Two handoffs alice<->bob, one carl<->dave (alice not involved).
	mustInsertHandoff(t, st, "h1", "alice", "bob")
	mustInsertHandoff(t, st, "h2", "bob", "alice")
	mustInsertHandoff(t, st, "h3", "carl", "dave")

	// Comments in chronological order (autoincrement id).
	mustInsertComment(t, st, "h1", "bob", "hi alice")        // alice should see (participant, not author)
	mustInsertComment(t, st, "h1", "alice", "hi bob")        // alice should NOT see (own)
	mustInsertComment(t, st, "h2", "bob", "ping")            // alice should see
	mustInsertComment(t, st, "h3", "carl", "irrelevant")     // alice should NOT see (not participant)
	cLast := mustInsertComment(t, st, "h2", "alice", "pong") // own, alice should NOT see

	got, maxID, err := st.ListCommentsSince(ctx, "alice", 0, 10)
	if err != nil {
		t.Fatalf("ListCommentsSince: %v", err)
	}
	if maxID != cLast.ID {
		t.Errorf("max_id: got %d want %d (last inserted)", maxID, cLast.ID)
	}
	if len(got) != 2 {
		t.Fatalf("got %d comments, want 2: %+v", len(got), got)
	}
	// Order: id ASC.
	if got[0].HandoffID != "h1" || got[0].Body != "hi alice" {
		t.Errorf("comment[0] = %+v", got[0])
	}
	if got[1].HandoffID != "h2" || got[1].Body != "ping" {
		t.Errorf("comment[1] = %+v", got[1])
	}
}

// TestListCommentsSinceCursor verifies the since cutoff: only comments with
// id strictly greater than `since` come back.
func TestListCommentsSinceCursor(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	mustInsertHandoff(t, st, "h1", "alice", "bob")
	c1 := mustInsertComment(t, st, "h1", "bob", "first")
	c2 := mustInsertComment(t, st, "h1", "bob", "second")

	got, _, err := st.ListCommentsSince(ctx, "alice", c1.ID, 10)
	if err != nil {
		t.Fatalf("ListCommentsSince: %v", err)
	}
	if len(got) != 1 || got[0].ID != c2.ID {
		t.Fatalf("expected only c2, got %+v", got)
	}

	got, _, err = st.ListCommentsSince(ctx, "alice", c2.ID, 10)
	if err != nil {
		t.Fatalf("ListCommentsSince after last: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected empty after cursor=last, got %+v", got)
	}
}

// TestListCommentsSinceLimitZero verifies bootstrap mode: limit=0 returns
// max_id without any rows.
func TestListCommentsSinceLimitZero(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	mustInsertHandoff(t, st, "h1", "alice", "bob")
	mustInsertComment(t, st, "h1", "bob", "hi")
	cLast := mustInsertComment(t, st, "h1", "bob", "again")

	got, maxID, err := st.ListCommentsSince(ctx, "alice", 0, 0)
	if err != nil {
		t.Fatalf("ListCommentsSince: %v", err)
	}
	if got != nil {
		t.Errorf("expected nil rows on limit=0, got %+v", got)
	}
	if maxID != cLast.ID {
		t.Errorf("max_id: got %d want %d", maxID, cLast.ID)
	}
}

// TestListCommentsSinceEmpty makes sure the relay returns max_id=0 (not an
// error) when the comments table is empty — bootstrap on a fresh relay.
func TestListCommentsSinceEmpty(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	got, maxID, err := st.ListCommentsSince(ctx, "alice", 0, 10)
	if err != nil {
		t.Fatalf("ListCommentsSince: %v", err)
	}
	if len(got) != 0 || maxID != 0 {
		t.Errorf("expected (nil, 0); got (%+v, %d)", got, maxID)
	}
}
