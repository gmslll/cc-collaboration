package store

import (
	"context"
	"errors"
	"path/filepath"
	"reflect"
	"strings"
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

func TestOpenKeepsTeamlessAccountTeamless(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	ctx := context.Background()
	st, err := Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.CreateUser(ctx, User{Identity: "teamless@x"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	st, err = Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	orgs, err := st.ListOrganizationsForIdentity(ctx, "teamless@x")
	if err != nil {
		t.Fatal(err)
	}
	if len(orgs) != 0 {
		t.Fatalf("teamless account gained organizations after reopen: %+v", orgs)
	}
}

func TestOpenDoesNotRecreateDeletedOrganization(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	ctx := context.Background()
	now := time.Now()
	st, err := Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.CreateUser(ctx, User{Identity: "owner@x"}, now); err != nil {
		t.Fatal(err)
	}
	orgID := defaultOrganizationID("owner@x")
	if err := st.CreateOrganization(ctx, orgID, "Deleted Personal Team", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.DeleteOrganization(ctx, orgID); err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	st, err = Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if _, err := st.GetOrganization(ctx, orgID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleted organization was recreated after reopen: %v", err)
	}
}

func TestOpenMigratesOnlyUnassignedLegacyProjects(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	ctx := context.Background()
	now := time.Now()
	st, err := Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, identity := range []string{"legacy-owner@x", "legacy-member@x", "teamless@x", "current-owner@x", "current-member@x"} {
		if err := st.CreateUser(ctx, User{Identity: identity}, now); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.CreateOrganization(ctx, "current-org", "Current Team", "current-owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateProjectInOrg(ctx, "current-project", "current-org", "Current Project", "current-owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "current-project", "current-member@x", RoleMember); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx,
		`INSERT INTO projects(id, org_id, name, owner_identity, created_at) VALUES(?, '', ?, ?, ?);`,
		"legacy-project", "Legacy Project", "legacy-owner@x", now.UnixMilli()); err != nil {
		t.Fatal(err)
	}
	for _, member := range []struct {
		identity string
		role     string
	}{
		{identity: "legacy-owner@x", role: RoleOwner},
		{identity: "legacy-member@x", role: RoleMember},
	} {
		if _, err := st.db.ExecContext(ctx,
			`INSERT INTO project_members(project_id, identity, role) VALUES(?, ?, ?)`,
			"legacy-project", member.identity, member.role); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	st, err = Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	legacyOrgID := defaultOrganizationID("legacy-owner@x")
	legacyProject, err := st.GetProject(ctx, "legacy-project")
	if err != nil {
		t.Fatal(err)
	}
	if legacyProject.OrgID != legacyOrgID {
		t.Fatalf("legacy project org_id = %q, want %q", legacyProject.OrgID, legacyOrgID)
	}
	if role, ok, err := st.OrganizationMemberRole(ctx, legacyOrgID, "legacy-owner@x"); err != nil || !ok || role != OrgRoleOwner {
		t.Fatalf("legacy owner organization role = %q ok=%v err=%v", role, ok, err)
	}
	if role, ok, err := st.OrganizationMemberRole(ctx, legacyOrgID, "legacy-member@x"); err != nil || !ok || role != OrgRoleMember {
		t.Fatalf("legacy member organization role = %q ok=%v err=%v", role, ok, err)
	}
	if orgs, err := st.ListOrganizationsForIdentity(ctx, "teamless@x"); err != nil || len(orgs) != 0 {
		t.Fatalf("unrelated teamless account organizations = %+v err=%v", orgs, err)
	}
	if _, ok, err := st.OrganizationMemberRole(ctx, "current-org", "current-member@x"); err != nil || ok {
		t.Fatalf("current project membership was replayed into organization: ok=%v err=%v", ok, err)
	}

	// Once the legacy project has an organization, subsequent opens must not
	// replay its project membership into organization_members.
	if _, err := st.db.ExecContext(ctx,
		`DELETE FROM organization_members WHERE org_id = ? AND identity = ?`,
		legacyOrgID, "legacy-member@x"); err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	st, err = Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if _, ok, err := st.OrganizationMemberRole(ctx, legacyOrgID, "legacy-member@x"); err != nil || ok {
		t.Fatalf("second open replayed migrated membership: ok=%v err=%v", ok, err)
	}
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
	if err := st.CreateUser(ctx, User{Identity: "disabled@x", Disabled: true}, time.Now()); err != nil {
		t.Fatal(err)
	}
	mustInsertHandoff(t, st, "h4", "sender@x", "disabled@x")
	mustInsertComment(t, st, "h4", "sender@x", "blocked")
	if _, _, err := st.ListCommentsSince(ctx, "disabled@x", 0, 10); !errors.Is(err, ErrForbidden) {
		t.Fatalf("disabled ListCommentsSince: want ErrForbidden, got %v", err)
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

func TestRetractPendingHandoff(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertHandoff(t, st, "h1", "alice", "bob")

	if recipients, err := st.Retract(ctx, "h1", "alice"); err != nil {
		t.Fatalf("first retract: %v", err)
	} else if len(recipients) != 1 || recipients[0] != "bob" {
		t.Errorf("retract recipients: got %v, want [bob]", recipients)
	}
	// State is now retracted; ListPending should NOT return it.
	pending, err := st.ListPending(ctx, "bob", 10)
	if err != nil {
		t.Fatalf("ListPending: %v", err)
	}
	if len(pending) != 0 {
		t.Errorf("retracted handoff still pending: %+v", pending)
	}
}

func TestRetractRejectsNonSender(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertHandoff(t, st, "h1", "alice", "bob")

	_, err := st.Retract(ctx, "h1", "carl")
	if !errors.Is(err, ErrForbidden) {
		t.Errorf("non-sender retract: want ErrForbidden, got %v", err)
	}
}

func TestRetractRejectsAfterAck(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertHandoff(t, st, "h1", "alice", "bob")
	if err := st.Ack(ctx, "h1", "bob"); err != nil {
		t.Fatalf("ack: %v", err)
	}
	_, err := st.Retract(ctx, "h1", "alice")
	if !errors.Is(err, ErrConflict) {
		t.Errorf("retract-after-ack: want ErrConflict, got %v", err)
	}
}

func TestRetractMissingHandoff(t *testing.T) {
	st := openTestStore(t)
	_, err := st.Retract(context.Background(), "nope", "alice")
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("missing handoff: want ErrNotFound, got %v", err)
	}
}

// mustInsertBug inserts a multi-recipient bug handoff. Mirrors mustInsertHandoff
// but exercises the Recipients []string path through Insert + handoff_recipients.
func mustInsertBug(t *testing.T, st *Store, id, sender string, recipients []string) {
	t.Helper()
	pkg := &handoffschema.Package{
		ID:             id,
		SchemaVersion:  handoffschema.SchemaVersion,
		Kind:           handoffschema.KindBug,
		Sender:         sender,
		Recipients:     recipients,
		Urgency:        handoffschema.UrgencyNormal,
		CreatedAt:      time.Now().UTC(),
		Repo:           handoffschema.Repo{Name: "demo"},
		SummaryMD:      "## Symptom\n broken thing",
		OriginalSender: sender,
	}
	if err := st.Insert(context.Background(), pkg); err != nil {
		t.Fatalf("insert bug %s: %v", id, err)
	}
}

// TestInsertMultiRecipientListPendingShowsBoth verifies a bug handoff with
// Recipients=[backend, frontend] appears in BOTH recipients' inboxes.
func TestInsertMultiRecipientListPendingShowsBoth(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertBug(t, st, "b1", "tester", []string{"backend", "frontend"})

	for _, who := range []string{"backend", "frontend"} {
		items, err := st.ListPending(ctx, who, 10)
		if err != nil {
			t.Fatalf("ListPending(%s): %v", who, err)
		}
		if len(items) != 1 || items[0].ID != "b1" {
			t.Errorf("%s inbox: want [b1], got %+v", who, items)
		}
		if items[0].Kind != handoffschema.KindBug {
			t.Errorf("%s inbox kind: got %q, want bug", who, items[0].Kind)
		}
		if len(items[0].Recipients) != 2 {
			t.Errorf("%s inbox recipients: got %v, want [backend frontend]", who, items[0].Recipients)
		}
	}
}

func TestInsertNormalizesRecipientsAndDeliveryTarget(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	pkg := &handoffschema.Package{
		ID:            "h-normalized",
		SchemaVersion: handoffschema.SchemaVersion,
		Kind:          handoffschema.KindBug,
		Sender:        " tester ",
		Recipients:    []string{" backend ", "backend", " frontend ", " "},
		Urgency:       handoffschema.UrgencyNormal,
		CreatedAt:     time.Now().UTC(),
		Repo:          handoffschema.Repo{Name: "demo"},
		SummaryMD:     "## Symptom\n spaced recipients",
		DeliveryTarget: &handoffschema.DeliveryTarget{
			ProjectID: " p1 ",
			OrgID:     " org1 ",
			Member:    " backend ",
		},
	}
	if err := st.Insert(ctx, pkg); err != nil {
		t.Fatal(err)
	}

	if items, err := st.ListPending(ctx, "backend", 10); err != nil || len(items) != 1 || items[0].ID != "h-normalized" {
		t.Fatalf("trimmed backend inbox = %+v err=%v", items, err)
	}
	if items, err := st.ListPending(ctx, " backend ", 10); err != nil || len(items) != 1 || items[0].ID != "h-normalized" {
		t.Fatalf("padded backend inbox = %+v err=%v", items, err)
	}
	if items, err := st.ListPending(ctx, "frontend", 10); err != nil || len(items) != 1 || items[0].ID != "h-normalized" {
		t.Fatalf("frontend inbox = %+v err=%v", items, err)
	} else if got := items[0].Recipients; !reflect.DeepEqual(got, []string{"backend", "frontend"}) {
		t.Fatalf("list recipients = %#v", got)
	}

	got, _, err := st.Get(ctx, "h-normalized")
	if err != nil {
		t.Fatal(err)
	}
	if got.Sender != "tester" || !reflect.DeepEqual(got.Recipients, []string{"backend", "frontend"}) {
		t.Fatalf("payload identities not normalized: sender=%q recipients=%#v", got.Sender, got.Recipients)
	}
	if got.DeliveryTarget == nil ||
		got.DeliveryTarget.ProjectID != "p1" ||
		got.DeliveryTarget.OrgID != "org1" ||
		got.DeliveryTarget.Member != "backend" {
		t.Fatalf("delivery target not normalized: %+v", got.DeliveryTarget)
	}
}

// TestAckOnlyMarksCallerSlot verifies that ack on a multi-recipient bug only
// closes the caller's slot; the other recipient still sees it as pending.
// Parent handoff state stays pending until all slots are closed.
func TestAckOnlyMarksCallerSlot(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertBug(t, st, "b1", "tester", []string{"backend", "frontend"})

	if err := st.Ack(ctx, "b1", "backend"); err != nil {
		t.Fatalf("backend ack: %v", err)
	}

	// backend's inbox is empty now; frontend still sees it.
	if items, _ := st.ListPending(ctx, "backend", 10); len(items) != 0 {
		t.Errorf("backend inbox after ack: want empty, got %+v", items)
	}
	if items, _ := st.ListPending(ctx, "frontend", 10); len(items) != 1 {
		t.Errorf("frontend inbox after backend ack: want [b1], got %+v", items)
	}

	// Parent handoff still pending (one slot open).
	st2, err := st.Status(ctx, "b1")
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if st2.State != handoffschema.StatePending {
		t.Errorf("parent state after partial ack: got %q, want pending", st2.State)
	}
	if got := st2.PickupBy["backend"].State; got != "picked" {
		t.Errorf("backend slot state: got %q, want picked", got)
	}
	if got := st2.PickupBy["frontend"].State; got != "pending" {
		t.Errorf("frontend slot state: got %q, want pending", got)
	}

	// Now frontend acks → parent moves to picked.
	if err := st.Ack(ctx, "b1", "frontend"); err != nil {
		t.Fatalf("frontend ack: %v", err)
	}
	st3, _ := st.Status(ctx, "b1")
	if st3.State != handoffschema.StatePicked {
		t.Errorf("parent state after both acks: got %q, want picked", st3.State)
	}
}

// TestAckForbiddenForNonRecipient verifies a third party can't ack a bug
// they're not on.
func TestAckForbiddenForNonRecipient(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertBug(t, st, "b1", "tester", []string{"backend", "frontend"})

	err := st.Ack(ctx, "b1", "stranger")
	if !errors.Is(err, ErrForbidden) {
		t.Errorf("non-recipient ack: want ErrForbidden, got %v", err)
	}
}

// TestReassignCreatesNewBugAndClosesSlot covers the happy path: backend
// reassigns its slot to frontend; backend's slot becomes "reassigned", a new
// bug handoff lands in frontend's inbox sharing the same bug_group_id.
func TestReassignCreatesNewBugAndClosesSlot(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertBug(t, st, "b1", "tester", []string{"backend"})

	newPkg := &handoffschema.Package{
		ID:             "b2",
		SchemaVersion:  handoffschema.SchemaVersion,
		Kind:           handoffschema.KindBug,
		Sender:         "backend",
		Recipients:     []string{"frontend"},
		Urgency:        handoffschema.UrgencyNormal,
		CreatedAt:      time.Now().UTC(),
		Repo:           handoffschema.Repo{Name: "demo"},
		SummaryMD:      "## Symptom\n broken thing",
		OriginalSender: "tester",
	}
	if err := st.Reassign(ctx, "b1", "backend", newPkg, "字段在前端拼装"); err != nil {
		t.Fatalf("reassign: %v", err)
	}

	// backend's slot on b1 → reassigned; b1's overall state → picked
	// (only one slot, now terminal).
	st1, err := st.Status(ctx, "b1")
	if err != nil {
		t.Fatalf("status b1: %v", err)
	}
	if got := st1.PickupBy["backend"].State; got != "reassigned" {
		t.Errorf("backend slot after reassign: got %q, want reassigned", got)
	}
	if st1.BugGroupID == "" {
		t.Error("bug_group_id should have been assigned on first reassign, got empty")
	}

	// frontend sees b2 in its inbox.
	items, _ := st.ListPending(ctx, "frontend", 10)
	if len(items) != 1 || items[0].ID != "b2" {
		t.Fatalf("frontend inbox after reassign: want [b2], got %+v", items)
	}
	if items[0].BugGroupID != st1.BugGroupID {
		t.Errorf("b2 bug_group_id %q != b1 %q", items[0].BugGroupID, st1.BugGroupID)
	}
	if items[0].Kind != handoffschema.KindBug {
		t.Errorf("b2 kind: got %q, want bug", items[0].Kind)
	}
}

// TestReassignLoopDetection verifies a reassign that would put `to` back into
// an already-active slot in the same bug group gets rejected with ErrConflict.
func TestReassignLoopDetection(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertBug(t, st, "b1", "tester", []string{"backend"})

	// backend → frontend (legitimate).
	newPkg := &handoffschema.Package{
		ID:            "b2",
		SchemaVersion: handoffschema.SchemaVersion,
		Kind:          handoffschema.KindBug,
		Sender:        "backend",
		Recipients:    []string{"frontend"},
		Urgency:       handoffschema.UrgencyNormal,
		CreatedAt:     time.Now().UTC(),
		Repo:          handoffschema.Repo{Name: "demo"},
		SummaryMD:     "## Symptom\n broken",
	}
	if err := st.Reassign(ctx, "b1", "backend", newPkg, "reason1"); err != nil {
		t.Fatalf("reassign 1: %v", err)
	}

	// frontend → backend (loop).
	loopPkg := &handoffschema.Package{
		ID:            "b3",
		SchemaVersion: handoffschema.SchemaVersion,
		Kind:          handoffschema.KindBug,
		Sender:        "frontend",
		Recipients:    []string{"backend"},
		Urgency:       handoffschema.UrgencyNormal,
		CreatedAt:     time.Now().UTC(),
		Repo:          handoffschema.Repo{Name: "demo"},
		SummaryMD:     "## Symptom\n broken",
	}
	err := st.Reassign(ctx, "b2", "frontend", loopPkg, "no it's yours")
	if !errors.Is(err, ErrConflict) {
		t.Errorf("loop reassign: want ErrConflict, got %v", err)
	}
}

// TestReassignNonBugRejected verifies you can't reassign a delivery/request
// handoff — only kind=bug.
func TestReassignNonBugRejected(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertHandoff(t, st, "h1", "alice", "bob") // kind=delivery (empty → default)

	newPkg := &handoffschema.Package{
		ID:            "h2",
		SchemaVersion: handoffschema.SchemaVersion,
		Kind:          handoffschema.KindBug,
		Sender:        "bob",
		Recipients:    []string{"carl"},
		Urgency:       handoffschema.UrgencyNormal,
		CreatedAt:     time.Now().UTC(),
		Repo:          handoffschema.Repo{Name: "demo"},
		SummaryMD:     "## Symptom",
	}
	err := st.Reassign(ctx, "h1", "bob", newPkg, "not mine")
	if !errors.Is(err, ErrConflict) {
		t.Errorf("reassign non-bug: want ErrConflict, got %v", err)
	}
}

// TestListCommentsSinceBugGroupParticipant verifies that comments on a
// reassigned child handoff are visible to participants from the original
// (e.g. tester filed the bug, backend reassigned to frontend, frontend
// commented — tester sees the comment via the bug_group join).
func TestListCommentsSinceBugGroupParticipant(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	// tester → backend; backend reassigns to frontend.
	mustInsertBug(t, st, "b1", "tester", []string{"backend"})
	newPkg := &handoffschema.Package{
		ID:             "b2",
		SchemaVersion:  handoffschema.SchemaVersion,
		Kind:           handoffschema.KindBug,
		Sender:         "backend",
		Recipients:     []string{"frontend"},
		Urgency:        handoffschema.UrgencyNormal,
		CreatedAt:      time.Now().UTC(),
		Repo:           handoffschema.Repo{Name: "demo"},
		SummaryMD:      "## Symptom",
		OriginalSender: "tester",
	}
	if err := st.Reassign(ctx, "b1", "backend", newPkg, "front-end issue"); err != nil {
		t.Fatalf("reassign: %v", err)
	}

	// frontend comments on b2; tester should see it via bug-group join.
	mustInsertComment(t, st, "b2", "frontend", "looking into it")

	got, _, err := st.ListCommentsSince(ctx, "tester", 0, 10)
	if err != nil {
		t.Fatalf("ListCommentsSince(tester): %v", err)
	}
	if len(got) != 1 || got[0].HandoffID != "b2" {
		t.Errorf("tester should see frontend's comment on b2 via bug_group: got %+v", got)
	}

	// backend (now in reassigned state) should still see comments on b2
	// because they're a participant in the same bug group.
	got, _, err = st.ListCommentsSince(ctx, "backend", 0, 10)
	if err != nil {
		t.Fatalf("ListCommentsSince(backend): %v", err)
	}
	if len(got) != 1 || got[0].HandoffID != "b2" {
		t.Errorf("backend (reassigned, still in group) should see b2 comments: got %+v", got)
	}
}

// TestBugGroupParticipants verifies the participant query returns the full
// union of senders and recipients across every handoff in the group.
func TestBugGroupParticipants(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	mustInsertBug(t, st, "b1", "tester", []string{"backend"})
	newPkg := &handoffschema.Package{
		ID:            "b2",
		SchemaVersion: handoffschema.SchemaVersion,
		Kind:          handoffschema.KindBug,
		Sender:        "backend",
		Recipients:    []string{"frontend"},
		Urgency:       handoffschema.UrgencyNormal,
		CreatedAt:     time.Now().UTC(),
		Repo:          handoffschema.Repo{Name: "demo"},
		SummaryMD:     "## Symptom",
	}
	if err := st.Reassign(ctx, "b1", "backend", newPkg, "x"); err != nil {
		t.Fatalf("reassign: %v", err)
	}

	// Pick the bug_group_id off b1.
	st1, _ := st.Status(ctx, "b1")
	parts, err := st.BugGroupParticipants(ctx, st1.BugGroupID)
	if err != nil {
		t.Fatalf("BugGroupParticipants: %v", err)
	}
	want := map[string]bool{"tester": true, "backend": true, "frontend": true}
	if len(parts) != 3 {
		t.Errorf("participants: want 3 (tester/backend/frontend), got %v", parts)
	}
	for _, p := range parts {
		if !want[p] {
			t.Errorf("unexpected participant %q in %v", p, parts)
		}
	}
}

// TestRetractCascadesToOpenRecipients verifies sender retracting a
// multi-recipient bug returns every still-pending recipient so the relay can
// fan SSE events out.
func TestRetractCascadesToOpenRecipients(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertBug(t, st, "b1", "tester", []string{"backend", "frontend"})

	recipients, err := st.Retract(ctx, "b1", "tester")
	if err != nil {
		t.Fatalf("retract: %v", err)
	}
	if len(recipients) != 2 {
		t.Errorf("retract recipients: want 2, got %v", recipients)
	}
	seen := map[string]bool{}
	for _, r := range recipients {
		seen[r] = true
	}
	if !seen["backend"] || !seen["frontend"] {
		t.Errorf("retract should cover both recipients, got %v", recipients)
	}
}

func TestListHistory(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertHandoff(t, st, "h1", "alice", "bob")  // pending — must NOT show
	mustInsertHandoff(t, st, "h2", "alice", "bob")  // will be picked
	time.Sleep(2 * time.Millisecond)                // ensure h3.created_at > h2.created_at at ms granularity
	mustInsertHandoff(t, st, "h3", "alice", "bob")  // will be picked
	mustInsertHandoff(t, st, "h4", "alice", "carl") // bob is not recipient
	if err := st.Ack(ctx, "h2", "bob"); err != nil {
		t.Fatalf("ack h2: %v", err)
	}
	if err := st.Ack(ctx, "h3", "bob"); err != nil {
		t.Fatalf("ack h3: %v", err)
	}

	got, err := st.ListHistory(ctx, "bob", 10)
	if err != nil {
		t.Fatalf("ListHistory: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 picked items for bob, got %d: %+v", len(got), got)
	}
	if got[0].ID != "h3" || got[1].ID != "h2" {
		t.Errorf("want newest-first order [h3, h2], got [%s, %s]", got[0].ID, got[1].ID)
	}
	for _, it := range got {
		if it.State != handoffschema.StatePicked {
			t.Errorf("%s: want state=picked, got %s", it.ID, it.State)
		}
		if it.ID == "h1" || it.ID == "h4" {
			t.Errorf("unexpected id %s in history (should be filtered)", it.ID)
		}
	}

	// alice has not received anything → empty.
	got, err = st.ListHistory(ctx, "alice", 10)
	if err != nil {
		t.Fatalf("ListHistory(alice): %v", err)
	}
	if len(got) != 0 {
		t.Errorf("alice has no receipts; got %+v", got)
	}
}

func TestListHistoryExcludesRetracted(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertHandoff(t, st, "h1", "alice", "bob")
	if _, err := st.Retract(ctx, "h1", "alice"); err != nil {
		t.Fatalf("retract: %v", err)
	}
	got, err := st.ListHistory(ctx, "bob", 10)
	if err != nil {
		t.Fatalf("ListHistory: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("retracted handoff appeared in history: %+v", got)
	}
}

func TestListSent(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertHandoff(t, st, "h1", "alice", "bob")
	mustInsertHandoff(t, st, "h2", "alice", "carl")
	mustInsertHandoff(t, st, "h3", "bob", "alice") // not alice's send
	if err := st.Ack(ctx, "h2", "carl"); err != nil {
		t.Fatalf("ack h2: %v", err)
	}

	got, err := st.ListSent(ctx, "alice", 10)
	if err != nil {
		t.Fatalf("ListSent: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 alice-sent handoffs, got %d: %+v", len(got), got)
	}
	// State of each — h2 should be picked, h1 pending.
	stateByID := map[string]handoffschema.State{}
	for _, it := range got {
		stateByID[it.ID] = it.State
	}
	if stateByID["h1"] != handoffschema.StatePending {
		t.Errorf("h1 state: %v", stateByID["h1"])
	}
	if stateByID["h2"] != handoffschema.StatePicked {
		t.Errorf("h2 state: %v", stateByID["h2"])
	}
}

func TestStatusReportsCommentSummary(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertHandoff(t, st, "h1", "alice", "bob")
	mustInsertComment(t, st, "h1", "bob", "first")
	last := mustInsertComment(t, st, "h1", "alice", "second")

	got, err := st.Status(ctx, "h1")
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if got.State != handoffschema.StatePending {
		t.Errorf("state: %v", got.State)
	}
	if got.PickedAt != nil {
		t.Errorf("picked_at not nil before ack: %v", got.PickedAt)
	}
	if got.CommentCount != 2 {
		t.Errorf("comment count: %d", got.CommentCount)
	}
	if got.LastComment == nil || got.LastComment.ID != last.ID {
		t.Errorf("last comment id: %+v", got.LastComment)
	}
}

func TestStatusAfterAckHasPickedAt(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertHandoff(t, st, "h1", "alice", "bob")
	if err := st.Ack(ctx, "h1", "bob"); err != nil {
		t.Fatalf("ack: %v", err)
	}
	got, err := st.Status(ctx, "h1")
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if got.State != handoffschema.StatePicked {
		t.Errorf("state: %v", got.State)
	}
	if got.PickedAt == nil {
		t.Errorf("picked_at nil after ack")
	}
}

func TestStatusTruncatesLongLastCommentBody(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	mustInsertHandoff(t, st, "h1", "alice", "bob")
	mustInsertComment(t, st, "h1", "bob", strings.Repeat("x", 100))

	got, err := st.Status(ctx, "h1")
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if got.LastComment == nil {
		t.Fatalf("last comment nil")
	}
	// Truncated to 80 runes plus ellipsis.
	if want := 81; len([]rune(got.LastComment.Body)) != want {
		t.Errorf("truncated body length: got %d, want %d", len([]rune(got.LastComment.Body)), want)
	}
}
