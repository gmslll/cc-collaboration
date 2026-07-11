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
	mustInsertCapsuleAt(t, st, id, owner, vis, time.Now().UTC())
}

func mustInsertCapsuleAt(t *testing.T, st *Store, id, owner string, vis handoffschema.CapsuleVisibility, createdAt time.Time) {
	t.Helper()
	pkg := &handoffschema.Package{
		ID:            id,
		SchemaVersion: handoffschema.SchemaVersion,
		Kind:          handoffschema.KindCapsule,
		Sender:        owner,
		Urgency:       handoffschema.UrgencyNormal,
		CreatedAt:     createdAt,
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

func TestListCapsules_PublicScopedToSharedTeam(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()
	if err := st.CreateOrganization(ctx, "org-shared", "Shared", "alice", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org-shared", "bob", OrgRoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateProjectInOrg(ctx, "project-shared", "org-shared", "Shared project", "alice", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "project-shared", "bob", RoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateOrganization(ctx, "org-other", "Other", "mallory", now); err != nil {
		t.Fatal(err)
	}

	pkg := &handoffschema.Package{
		ID: "c-public", SchemaVersion: handoffschema.SchemaVersion,
		Kind: handoffschema.KindCapsule, Sender: "alice",
		Urgency: handoffschema.UrgencyNormal, CreatedAt: now,
		Capsule: &handoffschema.Capsule{
			SourceAgent: "claude", Visibility: handoffschema.CapsulePublic,
			ProjectID: "project-shared", HasPersona: true,
		},
	}
	if err := st.Insert(ctx, pkg); err != nil {
		t.Fatal(err)
	}
	mustInsertCapsule(t, st, "c-private", "alice", handoffschema.CapsulePrivate)

	bob, err := st.ListCapsules(ctx, "bob", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(bob) != 1 || bob[0].ID != "c-public" {
		t.Fatalf("shared teammate capsules = %+v, want only c-public", bob)
	}
	mallory, err := st.ListCapsules(ctx, "mallory", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(mallory) != 0 {
		t.Fatalf("cross-team public capsule leaked: %+v", mallory)
	}
}

func TestListCapsules_UnscopedPublicFailsClosedForAccountTeams(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	if err := st.CreateOrganization(ctx, "org", "Team", "alice", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org", "bob", OrgRoleMember); err != nil {
		t.Fatal(err)
	}
	mustInsertCapsule(t, st, "legacy-public", "alice", handoffschema.CapsulePublic)
	if got, err := st.ListCapsules(ctx, "bob", 0); err != nil || len(got) != 0 {
		t.Fatalf("unscoped public capsule leaked to account team: %+v, err=%v", got, err)
	}
}

func TestListCapsules_ProjectScopeDoesNotLeakAcrossOwnersTeams(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	if err := st.CreateOrganization(ctx, "org-a", "A", "alice", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org-a", "bob", OrgRoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateProjectInOrg(ctx, "project-a", "org-a", "A project", "alice", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "project-a", "bob", RoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateOrganization(ctx, "org-b", "B", "dave", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org-b", "alice", OrgRoleMember); err != nil {
		t.Fatal(err)
	}

	pkg := &handoffschema.Package{
		ID: "scoped", SchemaVersion: handoffschema.SchemaVersion,
		Kind: handoffschema.KindCapsule, Sender: "alice",
		Urgency: handoffschema.UrgencyNormal, CreatedAt: now,
		Capsule: &handoffschema.Capsule{
			SourceAgent: "claude", Visibility: handoffschema.CapsulePublic,
			ProjectID: "project-a", HasPersona: true,
		},
	}
	if err := st.Insert(ctx, pkg); err != nil {
		t.Fatal(err)
	}
	if got, err := st.ListCapsules(ctx, "bob", 0); err != nil || len(got) != 1 {
		t.Fatalf("project member capsules = %+v, err=%v", got, err)
	}
	if got, err := st.ListCapsules(ctx, "dave", 0); err != nil || len(got) != 0 {
		t.Fatalf("capsule leaked through a different shared team: %+v, err=%v", got, err)
	}
}

func TestListCapsules_LimitAppliesAfterVisibility(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	if err := st.CreateOrganization(ctx, "org-shared", "Shared", "alice", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org-shared", "bob", OrgRoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateProjectInOrg(ctx, "project-shared", "org-shared", "Shared project", "alice", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "project-shared", "bob", RoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateOrganization(ctx, "org-other", "Other", "mallory", now); err != nil {
		t.Fatal(err)
	}

	visible := &handoffschema.Package{
		ID: "visible-old", SchemaVersion: handoffschema.SchemaVersion,
		Kind: handoffschema.KindCapsule, Sender: "alice",
		Urgency: handoffschema.UrgencyNormal, CreatedAt: now.Add(-3 * time.Minute),
		Capsule: &handoffschema.Capsule{
			SourceAgent: "claude", Visibility: handoffschema.CapsulePublic,
			ProjectID: "project-shared", HasPersona: true,
		},
	}
	if err := st.Insert(ctx, visible); err != nil {
		t.Fatal(err)
	}
	mustInsertCapsuleAt(t, st, "hidden-new-1", "mallory", handoffschema.CapsulePublic, now.Add(-2*time.Minute))
	mustInsertCapsuleAt(t, st, "hidden-new-2", "mallory", handoffschema.CapsulePublic, now.Add(-1*time.Minute))

	items, err := st.ListCapsules(ctx, "bob", 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].ID != "visible-old" {
		t.Fatalf("limit should apply after visibility filtering, got %+v", items)
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

func TestHandoffListsExcludeCapsules(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertHandoff(t, st, "h1", "alice", "bob")
	mustInsertCapsule(t, st, "c-private", "alice", handoffschema.CapsulePrivate)

	byRepo, err := st.ListByRepos(ctx, []string{"demo"}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(byRepo) != 1 || byRepo[0].ID != "h1" {
		t.Fatalf("project handoff list leaked capsules: %+v", byRepo)
	}

	sent, err := st.ListSent(ctx, "alice", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(sent) != 1 || sent[0].ID != "h1" {
		t.Fatalf("sent handoff list leaked capsules: %+v", sent)
	}

	all, err := st.ListAll(ctx, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 1 || all[0].ID != "h1" {
		t.Fatalf("admin handoff list leaked capsules: %+v", all)
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
	beforeEdit := time.Now().UTC()
	if err := st.UpdateCapsuleMeta(context.Background(), "c1", "alice", &priv, &sum); err != nil {
		t.Fatalf("owner edit: %v", err)
	}
	// Flipped to private → a teammate no longer sees it; the owner does, with the new headline.
	if items, _ := st.ListCapsules(context.Background(), "bob", 0); len(items) != 0 {
		t.Errorf("private capsule leaked to teammate: %+v", items)
	}
	own, _ := st.ListCapsules(context.Background(), "alice", 0)
	if len(own) != 1 || own[0].Visibility != handoffschema.CapsulePrivate || own[0].Headline != "改过的说明" || own[0].Summary != sum {
		t.Errorf("owner view after edit wrong: %+v", own)
	}
	if own[0].UpdatedAt.Before(beforeEdit) {
		t.Errorf("owner view did not receive metadata update time: %+v", own[0])
	}
}
