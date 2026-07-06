package store

import (
	"context"
	"testing"
	"time"

	"github.com/cc-collaboration/pkg/handoffschema"
)

func mustInsertCapsule(t *testing.T, st *Store, id, owner string, vis handoffschema.CapsuleVisibility) {
	t.Helper()
	pkg := &handoffschema.Package{
		ID:            id,
		SchemaVersion: handoffschema.SchemaVersion,
		Kind:          handoffschema.KindCapsule,
		Sender:        owner,
		Urgency:       handoffschema.UrgencyNormal,
		CreatedAt:     time.Now().UTC(),
		Repo:          handoffschema.Repo{Name: "demo"},
		SummaryMD:     "capsule " + id,
		Capsule: &handoffschema.Capsule{
			SourceAgent: "claude",
			Visibility:  vis,
			HasPersona:  true,
		},
	}
	if err := st.Insert(context.Background(), pkg); err != nil {
		t.Fatalf("insert capsule %s: %v", id, err)
	}
}

// TestListCapsules_VisibilityScoping locks the plaza rule: a viewer sees every
// public capsule plus their own private ones, never someone else's private one.
func TestListCapsules_VisibilityScoping(t *testing.T) {
	st := openTestStore(t)
	mustInsertCapsule(t, st, "c-ap", "alice", handoffschema.CapsulePublic)
	mustInsertCapsule(t, st, "c-apr", "alice", handoffschema.CapsulePrivate)
	mustInsertCapsule(t, st, "c-bp", "bob", handoffschema.CapsulePublic)
	mustInsertCapsule(t, st, "c-bpr", "bob", handoffschema.CapsulePrivate)

	items, err := st.ListCapsules(context.Background(), "alice", 0)
	if err != nil {
		t.Fatalf("ListCapsules: %v", err)
	}
	got := map[string]handoffschema.CapsuleListItem{}
	for _, it := range items {
		got[it.ID] = it
	}
	for _, id := range []string{"c-ap", "c-apr", "c-bp"} {
		if _, ok := got[id]; !ok {
			t.Errorf("alice should see capsule %s", id)
		}
	}
	if _, ok := got["c-bpr"]; ok {
		t.Error("alice must not see bob's private capsule c-bpr")
	}
	// Projection carries the fields the plaza renders.
	if it := got["c-ap"]; it.Owner != "alice" || it.Visibility != handoffschema.CapsulePublic || it.SourceAgent != "claude" || !it.HasPersona {
		t.Errorf("capsule list item projection wrong: %+v", it)
	}
}

// TestListCapsules_IgnoresNonCapsules confirms ordinary handoffs never leak into
// the plaza.
func TestListCapsules_IgnoresNonCapsules(t *testing.T) {
	st := openTestStore(t)
	mustInsertHandoff(t, st, "h1", "alice", "bob")
	mustInsertCapsule(t, st, "c1", "alice", handoffschema.CapsulePublic)

	items, err := st.ListCapsules(context.Background(), "carol", 0)
	if err != nil {
		t.Fatalf("ListCapsules: %v", err)
	}
	if len(items) != 1 || items[0].ID != "c1" {
		t.Errorf("plaza should contain only the capsule c1, got %+v", items)
	}
}
