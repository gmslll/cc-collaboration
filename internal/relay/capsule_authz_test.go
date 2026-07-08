package relay_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// TestCapsuleViewVisibility pins the plaza-load authz: GET /v1/handoffs/{id}
// (used to fetch a capsule's package + attachments) follows the capsule's
// visibility, not the recipient rule — a public capsule is viewable by any
// teammate, a private one only by its owner.
func TestCapsuleViewVisibility(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	for _, id := range []string{"owner@t", "mate@t", "outsider@t"} {
		mkUser(t, st, id, "pw-"+id+"-12345")
	}
	if err := st.CreateOrganization(context.Background(), "org-shared", "Shared", "owner@t", time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(context.Background(), "org-shared", "mate@t", store.OrgRoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateOrganization(context.Background(), "org-other", "Other", "outsider@t", time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
	}).Handler())
	t.Cleanup(srv.Close)

	mkCapsule := func(id string, vis handoffschema.CapsuleVisibility) {
		if err := st.Insert(context.Background(), &handoffschema.Package{
			ID: id, SchemaVersion: handoffschema.SchemaVersion,
			Kind: handoffschema.KindCapsule, Sender: "owner@t",
			Urgency: handoffschema.UrgencyNormal, CreatedAt: time.Now().UTC(),
			Repo:    handoffschema.Repo{Name: "demo"},
			Capsule: &handoffschema.Capsule{SourceAgent: "claude", Visibility: vis, HasPersona: true},
		}); err != nil {
			t.Fatal(err)
		}
	}
	mkCapsule("cap-pub", handoffschema.CapsulePublic)
	mkCapsule("cap-priv", handoffschema.CapsulePrivate)

	mate := loginToken(t, srv.URL, "mate@t", "pw-mate@t-12345")
	owner := loginToken(t, srv.URL, "owner@t", "pw-owner@t-12345")
	outsider := loginToken(t, srv.URL, "outsider@t", "pw-outsider@t-12345")

	getStatus := func(id, token string) int {
		req, _ := http.NewRequest(http.MethodGet, srv.URL+"/v1/handoffs/"+id, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		return resp.StatusCode
	}

	if got := getStatus("cap-pub", mate); got != http.StatusOK {
		t.Errorf("public capsule GET by teammate = %d, want 200", got)
	}
	if got := getStatus("cap-pub", outsider); got != http.StatusForbidden {
		t.Errorf("public capsule GET by cross-team user = %d, want 403", got)
	}
	if got := getStatus("cap-priv", mate); got != http.StatusForbidden {
		t.Errorf("private capsule GET by teammate = %d, want 403", got)
	}
	if got := getStatus("cap-priv", owner); got != http.StatusOK {
		t.Errorf("private capsule GET by owner = %d, want 200", got)
	}
}
