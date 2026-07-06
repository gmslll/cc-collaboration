package store

import (
	"context"
	"errors"
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

// TestDeleteCapsule_OwnerOnly pins owner-only delete: a teammate can't delete it,
// a non-capsule id isn't reachable, and the owner's delete removes it.
func TestDeleteCapsule_OwnerOnly(t *testing.T) {
	st := openTestStore(t)
	mustInsertCapsule(t, st, "c1", "alice", handoffschema.CapsulePublic)
	mustInsertHandoff(t, st, "h1", "alice", "bob") // a normal handoff, not a capsule

	if err := st.DeleteCapsule(context.Background(), "c1", "bob"); !errors.Is(err, ErrForbidden) {
		t.Errorf("non-owner delete = %v, want ErrForbidden", err)
	}
	if err := st.DeleteCapsule(context.Background(), "h1", "alice"); !errors.Is(err, ErrNotFound) {
		t.Errorf("delete non-capsule = %v, want ErrNotFound", err)
	}
	if err := st.DeleteCapsule(context.Background(), "c1", "alice"); err != nil {
		t.Fatalf("owner delete: %v", err)
	}
	if items, _ := st.ListCapsules(context.Background(), "alice", 0); len(items) != 0 {
		t.Errorf("capsule still listed after delete: %+v", items)
	}
}

// TestUpdateCapsuleMeta_OwnerEdits pins owner-only edit of visibility + summary.
func TestUpdateCapsuleMeta_OwnerEdits(t *testing.T) {
	st := openTestStore(t)
	mustInsertCapsule(t, st, "c1", "alice", handoffschema.CapsulePublic)

	pub := string(handoffschema.CapsulePublic)
	if err := st.UpdateCapsuleMeta(context.Background(), "c1", "bob", &pub, nil); !errors.Is(err, ErrForbidden) {
		t.Errorf("non-owner edit = %v, want ErrForbidden", err)
	}

	priv := string(handoffschema.CapsulePrivate)
	sum := "改过的说明"
	if err := st.UpdateCapsuleMeta(context.Background(), "c1", "alice", &priv, &sum); err != nil {
		t.Fatalf("owner edit: %v", err)
	}
	// Flipped to private → a teammate no longer sees it; the owner does, with the new headline.
	if items, _ := st.ListCapsules(context.Background(), "bob", 0); len(items) != 0 {
		t.Errorf("private capsule leaked to teammate: %+v", items)
	}
	own, _ := st.ListCapsules(context.Background(), "alice", 0)
	if len(own) != 1 || own[0].Visibility != handoffschema.CapsulePrivate || own[0].Headline != "改过的说明" {
		t.Errorf("owner view after edit wrong: %+v", own)
	}
}
