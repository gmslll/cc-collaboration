package relay_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// TestProjectVisibility pins the Phase 3 read-authz change: project members see
// a project's handoffs (even when not a participant), viewers are read-only,
// strangers are denied, admins see all, and the legacy participant rule still
// holds — exercised through GET / status / comment / scope listing.
func TestProjectVisibility(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	for _, id := range []string{"admin@hq", "owner@t", "org-admin@t", "member@t", "viewer@t", "recipient@t", "stranger@t"} {
		mkUser(t, st, id, "pw-"+id+"-12345")
	}

	hub := sse.NewHub()
	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: hub,
		SeedAdmins: []string{"admin@hq"},
	}).Handler())
	t.Cleanup(srv.Close)

	tok := func(id string) string { return loginToken(t, srv.URL, id, "pw-"+id+"-12345") }
	owner, orgAdmin, member, viewer, recipient, stranger, admin :=
		tok("owner@t"), tok("org-admin@t"), tok("member@t"), tok("viewer@t"), tok("recipient@t"), tok("stranger@t"), tok("admin@hq")

	// A handoff in repo "kunlun-backend" between two parties; recipient@t is the
	// only project-outsider who is a participant.
	if err := st.Insert(context.Background(), &handoffschema.Package{
		ID: "h_x", SchemaVersion: handoffschema.SchemaVersion, Sender: "ext-sender",
		Recipient: "recipient@t", Urgency: handoffschema.UrgencyNormal,
		CreatedAt: time.Now().UTC(), Repo: handoffschema.Repo{Name: "kunlun-backend"},
	}); err != nil {
		t.Fatal(err)
	}

	// owner@t makes a project, maps the repo, seats member + viewer.
	proj := createProjectHTTP(t, srv.URL, owner, "K")
	if err := st.AddOrganizationMember(context.Background(), proj.OrgID, "org-admin@t", store.OrgRoleAdmin); err != nil {
		t.Fatal(err)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/repos", owner, map[string]string{"repo_name": "kunlun-backend", "clone_url": "https://github.com/kunlun/kunlun-backend.git"}); code != http.StatusOK {
		t.Fatalf("map repo = %d", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", owner, map[string]string{"identity": "member@t", "role": "member"}); code != http.StatusOK {
		t.Fatalf("add member = %d", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", owner, map[string]string{"identity": "viewer@t", "role": "viewer"}); code != http.StatusOK {
		t.Fatalf("add viewer = %d", code)
	}

	get := func(tk string) int { c, _ := getAuthed(t, srv.URL+"/v1/handoffs/h_x", tk); return c }
	// GET: project members + admin + the participant recipient all 200; stranger 403.
	for name, tk := range map[string]string{"owner": owner, "team admin": orgAdmin, "member": member, "viewer": viewer, "admin": admin, "recipient(participant)": recipient} {
		if code := get(tk); code != http.StatusOK {
			t.Errorf("GET handoff as %s = %d, want 200", name, code)
		}
	}
	if code := get(stranger); code != http.StatusForbidden {
		t.Errorf("GET handoff as stranger = %d, want 403", code)
	}

	// status de-dup regression: same gate applies.
	if code, _ := getAuthed(t, srv.URL+"/v1/handoffs/h_x/status", member); code != http.StatusOK {
		t.Errorf("status as member = %d, want 200", code)
	}
	if code, _ := getAuthed(t, srv.URL+"/v1/handoffs/h_x/status", stranger); code != http.StatusForbidden {
		t.Errorf("status as stranger = %d, want 403", code)
	}

	viewerSub, cancelViewerSub := hub.Subscribe("viewer@t")
	defer cancelViewerSub()

	// comment: member can, viewer cannot (read-only), stranger cannot.
	if code, _ := postJSON(t, srv.URL+"/v1/handoffs/h_x/comment", member, map[string]string{"body": "triaging"}); code != http.StatusCreated {
		t.Errorf("comment as member = %d, want 201", code)
	}
	if ev := waitForEventType(t, viewerSub, sse.EventTypeCommentCreated, 2*time.Second); len(ev.Data) == 0 {
		t.Fatal("viewer should receive project handoff comment event")
	}
	if code, _ := postJSON(t, srv.URL+"/v1/handoffs/h_x/comment", orgAdmin, map[string]string{"body": "coordinating"}); code != http.StatusCreated {
		t.Errorf("comment as team admin = %d, want 201", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/handoffs/h_x/comment", viewer, map[string]string{"body": "nope"}); code != http.StatusForbidden {
		t.Errorf("comment as viewer = %d, want 403", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/handoffs/h_x/comment", stranger, map[string]string{"body": "nope"}); code != http.StatusForbidden {
		t.Errorf("comment as stranger = %d, want 403", code)
	}
	code, lb := getAuthed(t, srv.URL+"/v1/comments?since=0", orgAdmin)
	if code != http.StatusOK || !strings.Contains(string(lb), "triaging") || strings.Contains(string(lb), "coordinating") {
		t.Errorf("project comment catch-up as team admin: code=%d body=%s", code, lb)
	}

	// scope=project: member sees the handoff they aren't a party to.
	code, lb = getAuthed(t, srv.URL+"/v1/handoffs?scope=project&project="+proj.ID, member)
	if code != http.StatusOK || !strings.Contains(string(lb), `"h_x"`) {
		t.Errorf("scope=project as member: code=%d body=%s", code, lb)
	}
	code, lb = getAuthed(t, srv.URL+"/v1/handoffs?scope=project&project="+proj.ID, orgAdmin)
	if code != http.StatusOK || !strings.Contains(string(lb), `"h_x"`) {
		t.Errorf("scope=project as team admin: code=%d body=%s", code, lb)
	}
	code, lb = getAuthed(t, srv.URL+"/v1/handoffs?scope=project", orgAdmin)
	if code != http.StatusOK || !strings.Contains(string(lb), `"h_x"`) {
		t.Errorf("scope=project union as team admin: code=%d body=%s", code, lb)
	}
	// scope=all: admin yes, member no.
	if code, _ := getAuthed(t, srv.URL+"/v1/handoffs?scope=all", admin); code != http.StatusOK {
		t.Errorf("scope=all as admin = %d, want 200", code)
	}
	if code, _ := getAuthed(t, srv.URL+"/v1/handoffs?scope=all", member); code != http.StatusForbidden {
		t.Errorf("scope=all as member = %d, want 403", code)
	}
}

func TestProjectHandoffListExcludesCapsules(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	for _, id := range []string{"owner@t", "member@t", "recipient@t"} {
		mkUser(t, st, id, "pw-"+id+"-12345")
	}

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
	}).Handler())
	t.Cleanup(srv.Close)

	owner := loginToken(t, srv.URL, "owner@t", "pw-owner@t-12345")
	member := loginToken(t, srv.URL, "member@t", "pw-member@t-12345")

	proj := createProjectHTTP(t, srv.URL, owner, "K")
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/repos", owner, map[string]string{"repo_name": "kunlun-backend", "clone_url": "https://github.com/kunlun/kunlun-backend.git"}); code != http.StatusOK {
		t.Fatalf("map repo = %d", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", owner, map[string]string{"identity": "member@t", "role": "member"}); code != http.StatusOK {
		t.Fatalf("add member = %d", code)
	}

	if err := st.Insert(context.Background(), &handoffschema.Package{
		ID: "h_project", SchemaVersion: handoffschema.SchemaVersion, Sender: "owner@t",
		Recipient: "recipient@t", Urgency: handoffschema.UrgencyNormal,
		CreatedAt: time.Now().UTC(), Repo: handoffschema.Repo{Name: "kunlun-backend"},
		SummaryMD: "ordinary handoff",
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.Insert(context.Background(), &handoffschema.Package{
		ID: "c_private", SchemaVersion: handoffschema.SchemaVersion, Kind: handoffschema.KindCapsule, Sender: "owner@t",
		Urgency: handoffschema.UrgencyNormal, CreatedAt: time.Now().UTC(), Repo: handoffschema.Repo{Name: "kunlun-backend"},
		SummaryMD: "private capsule", Capsule: &handoffschema.Capsule{Visibility: handoffschema.CapsulePrivate},
	}); err != nil {
		t.Fatal(err)
	}

	code, body := getAuthed(t, srv.URL+"/v1/handoffs?scope=project&project="+proj.ID, member)
	if code != http.StatusOK {
		t.Fatalf("project list = %d %s", code, body)
	}
	if !strings.Contains(string(body), `"h_project"`) {
		t.Fatalf("project list missing ordinary handoff: %s", body)
	}
	if strings.Contains(string(body), `"c_private"`) || strings.Contains(string(body), "private capsule") {
		t.Fatalf("project list leaked capsule: %s", body)
	}
}
