package relay_test

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

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
