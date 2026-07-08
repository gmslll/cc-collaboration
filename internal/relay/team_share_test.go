package relay_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

func TestDeliveryHandoffCanFanOutToTeamRecipients(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[
		{"token":"tok-sender","identity":"sender@x"},
		{"token":"tok-dev","identity":"dev@x"},
		{"token":"tok-ops","identity":"ops@x"}
	]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)

	pkg := &handoffschema.Package{
		SchemaVersion: handoffschema.SchemaVersion,
		Kind:          handoffschema.KindDelivery,
		Recipient:     "dev@x",
		Recipients:    []string{"dev@x", "ops@x"},
		Urgency:       handoffschema.UrgencyNormal,
		Repo:          handoffschema.Repo{Name: "demo"},
		SummaryMD:     "team delivery\n\nshared with project members",
	}
	if _, err := transport.New(srv.URL, "tok-sender").Submit(context.Background(), pkg, nil); err != nil {
		t.Fatalf("submit: %v", err)
	}

	for token, identity := range map[string]string{"tok-dev": "dev@x", "tok-ops": "ops@x"} {
		items, err := transport.New(srv.URL, token).List(context.Background(), identity)
		if err != nil {
			t.Fatalf("list %s: %v", identity, err)
		}
		if len(items) != 1 || len(items[0].Recipients) != 2 {
			t.Fatalf("%s items = %+v", identity, items)
		}
	}
}

func TestSubmitHandoffRequiresReachableRecipients(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ctx := context.Background()
	now := time.Now()
	mkUser(t, st, "alice@backend", "alicepass1")
	mkUser(t, st, "bob@frontend", "bobpass123")
	mkUser(t, st, "mallory@other", "mallorypass1")
	if err := st.CreateUser(ctx, store.User{Identity: "disabled@frontend", Disabled: true}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateOrganization(ctx, "org-shared", "Shared", "alice@backend", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org-shared", "bob@frontend", store.OrgRoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org-shared", "disabled@frontend", store.OrgRoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateOrganization(ctx, "org-other", "Other", "mallory@other", now); err != nil {
		t.Fatal(err)
	}

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[
		{"token":"tok-alice","identity":"alice@backend"},
		{"token":"tok-bob",  "identity":"bob@frontend"},
		{"token":"tok-mallory",  "identity":"mallory@other"}
	]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)

	pkg := handoffschema.Package{
		Kind:      handoffschema.KindDelivery,
		Recipient: "alice@backend",
		Urgency:   handoffschema.UrgencyNormal,
		Repo:      handoffschema.Repo{Name: "demo"},
		SummaryMD: "direct submit",
	}
	if code, body := postJSON(t, srv.URL+"/v1/handoffs", "tok-bob", pkg); code != http.StatusCreated {
		t.Fatalf("shared teammate submit = %d %s, want 201", code, body)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/handoffs", "tok-mallory", pkg); code != http.StatusForbidden {
		t.Fatalf("cross-team submit = %d, want 403", code)
	}
	pkg.Recipient = "disabled@frontend"
	if code, _ := postJSON(t, srv.URL+"/v1/handoffs", "tok-bob", pkg); code != http.StatusForbidden {
		t.Fatalf("disabled teammate submit = %d, want 403", code)
	}
}

func TestReassignRequiresReachableRecipient(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ctx := context.Background()
	now := time.Now()
	mkUser(t, st, "alice@backend", "alicepass1")
	mkUser(t, st, "bob@frontend", "bobpass123")
	mkUser(t, st, "charlie@qa", "charliepass1")
	mkUser(t, st, "mallory@other", "mallorypass1")
	if err := st.CreateUser(ctx, store.User{Identity: "disabled@frontend", Disabled: true}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateOrganization(ctx, "org-shared", "Shared", "alice@backend", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org-shared", "bob@frontend", store.OrgRoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org-shared", "charlie@qa", store.OrgRoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org-shared", "disabled@frontend", store.OrgRoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateOrganization(ctx, "org-other", "Other", "mallory@other", now); err != nil {
		t.Fatal(err)
	}

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[
		{"token":"tok-bob","identity":"bob@frontend"}
	]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)

	mkBug := func(id string) {
		t.Helper()
		if err := st.Insert(ctx, &handoffschema.Package{
			ID:            id,
			SchemaVersion: handoffschema.SchemaVersion,
			Kind:          handoffschema.KindBug,
			Sender:        "alice@backend",
			Recipient:     "bob@frontend",
			Urgency:       handoffschema.UrgencyNormal,
			CreatedAt:     now,
			Repo:          handoffschema.Repo{Name: "demo"},
			SummaryMD:     "not mine",
		}); err != nil {
			t.Fatal(err)
		}
	}
	mkBug("bug-cross")
	mkBug("bug-shared")
	mkBug("bug-disabled")

	if code, _ := postJSON(t, srv.URL+"/v1/handoffs/bug-cross/reassign", "tok-bob",
		map[string]string{"to": "mallory@other", "reason": "wrong team"}); code != http.StatusForbidden {
		t.Fatalf("cross-team reassign = %d, want 403", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/handoffs/bug-disabled/reassign", "tok-bob",
		map[string]string{"to": "disabled@frontend", "reason": "disabled"}); code != http.StatusForbidden {
		t.Fatalf("disabled teammate reassign = %d, want 403", code)
	}
	if code, body := postJSON(t, srv.URL+"/v1/handoffs/bug-shared/reassign", "tok-bob",
		map[string]string{"to": "charlie@qa", "reason": "qa owns this"}); code != http.StatusCreated {
		t.Fatalf("same-team reassign = %d %s, want 201", code, body)
	}
}
