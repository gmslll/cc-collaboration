package relay_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
)

func TestSelfServiceMachineTokens(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	mkUser(t, st, "dev@t", "devpass12345")
	mkUser(t, st, "other@t", "otherpass12345")

	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)

	devSession := loginToken(t, srv.URL, "dev@t", "devpass12345")

	// Mint a machine token (raw value returned once).
	code, body := postJSON(t, srv.URL+"/v1/tokens", devSession, map[string]string{"label": "laptop"})
	if code != http.StatusCreated {
		t.Fatalf("create token = %d %s", code, body)
	}
	var ct struct {
		Token string `json:"token"`
		ID    string `json:"id"`
	}
	_ = json.Unmarshal(body, &ct)
	if ct.Token == "" || ct.ID == "" {
		t.Fatalf("missing token/id: %s", body)
	}

	// The minted machine token authenticates as dev.
	c, mb := getAuthed(t, srv.URL+"/v1/me", ct.Token)
	if c != http.StatusOK {
		t.Fatalf("me with machine token = %d", c)
	}
	var me struct {
		Identity string `json:"identity"`
	}
	_ = json.Unmarshal(mb, &me)
	if me.Identity != "dev@t" {
		t.Fatalf("machine token identity = %q", me.Identity)
	}

	// It shows up in the owner's token list.
	if _, lb := getAuthed(t, srv.URL+"/v1/tokens", devSession); !strings.Contains(string(lb), "laptop") {
		t.Fatalf("token not listed: %s", lb)
	}

	// Another user cannot revoke dev's token (scoped to owner → 404); it keeps working.
	otherSession := loginToken(t, srv.URL, "other@t", "otherpass12345")
	if c, _ := deleteAuthed(t, srv.URL+"/v1/tokens/"+ct.ID, otherSession); c != http.StatusNotFound {
		t.Fatalf("cross-user revoke = %d, want 404", c)
	}
	if c, _ := getAuthed(t, srv.URL+"/v1/me", ct.Token); c != http.StatusOK {
		t.Fatalf("token should still work after cross-user revoke attempt = %d", c)
	}

	// Owner revokes; the token stops authenticating.
	if c, _ := deleteAuthed(t, srv.URL+"/v1/tokens/"+ct.ID, devSession); c != http.StatusOK {
		t.Fatalf("revoke = %d", c)
	}
	if c, _ := getAuthed(t, srv.URL+"/v1/me", ct.Token); c != http.StatusUnauthorized {
		t.Fatalf("revoked token still works = %d", c)
	}
}

func TestCreateMachineTokenRejectsInvalidJSON(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	mkUser(t, st, "dev@t", "devpass12345")
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)

	devSession := loginToken(t, srv.URL, "dev@t", "devpass12345")
	if code, body := postRawJSON(t, srv.URL+"/v1/tokens", devSession, "{"); code != http.StatusBadRequest {
		t.Fatalf("invalid token json = %d %s", code, body)
	}
	toks, err := st.ListMachineTokens(context.Background(), "dev@t")
	if err != nil {
		t.Fatal(err)
	}
	if len(toks) != 0 {
		t.Fatalf("invalid token json created tokens: %+v", toks)
	}
}

func deleteAuthed(t *testing.T, url, bearer string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodDelete, url, nil)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	return do(t, req)
}
