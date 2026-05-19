package relay_test

import (
	"bytes"
	"context"
	"io"
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
	"github.com/cc-collaboration/pkg/handoffschema"
)

// attachmentTestRig spins up the bare-minimum relay (store + tokens + server)
// for attachment-route tests. Returns the URL plus a cleanup-aware store
// handle so callers can inject handoffs directly.
func attachmentTestRig(t *testing.T) (string, *store.Store) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[
		{"token":"tok-tester",  "identity":"tester"},
		{"token":"tok-backend", "identity":"backend"},
		{"token":"tok-frontend","identity":"frontend"},
		{"token":"tok-outsider","identity":"outsider"}
	]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)
	return srv.URL, st
}

// seedBugHandoff inserts a multi-recipient bug handoff directly via the store.
// Returns the id so the caller can hit its attachment route.
func seedBugHandoff(t *testing.T, st *store.Store, id, sender string, recipients []string) {
	t.Helper()
	pkg := &handoffschema.Package{
		ID:            id,
		SchemaVersion: handoffschema.SchemaVersion,
		Kind:          handoffschema.KindBug,
		Sender:        sender,
		Recipients:    recipients,
		Urgency:       handoffschema.UrgencyNormal,
		CreatedAt:     time.Now().UTC(),
		Repo:          handoffschema.Repo{Name: "demo"},
		SummaryMD:     "## Symptom\n broken\n",
	}
	if err := st.Insert(context.Background(), pkg); err != nil {
		t.Fatalf("insert: %v", err)
	}
}

func putAttachment(t *testing.T, baseURL, token, id, name string, body []byte) int {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost,
		baseURL+"/v1/handoffs/"+id+"/attachments/"+name,
		bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/octet-stream")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode
}

// TestPutAttachment_RecipientCanUpload: post-simplify, attachment upload is
// open to any handoff participant — not just the sender. This is what lets
// a backend dev reply to a bug with a network-tab screenshot.
func TestPutAttachment_RecipientCanUpload(t *testing.T) {
	url, st := attachmentTestRig(t)
	seedBugHandoff(t, st, "b_recip", "tester", []string{"backend", "frontend"})

	// recipient backend uploads — should be allowed now.
	if code := putAttachment(t, url, "tok-backend", "b_recip", "network.har", []byte("har-data")); code != http.StatusCreated {
		t.Errorf("recipient upload: status = %d, want 201", code)
	}

	// non-participant outsider must still be blocked.
	if code := putAttachment(t, url, "tok-outsider", "b_recip", "evil.png", []byte("x")); code != http.StatusForbidden {
		t.Errorf("outsider upload: status = %d, want 403", code)
	}
}

// TestPutAttachment_RejectsPathTraversal: the {name} path segment flows into
// the receiver-side filesystem path, so anything that isn't a bare basename
// must be rejected with 400 — not 500, not a write to the wrong location.
func TestPutAttachment_RejectsPathTraversal(t *testing.T) {
	url, st := attachmentTestRig(t)
	seedBugHandoff(t, st, "b_path", "tester", []string{"backend"})

	// Cases that reach the handler in decoded form — handler must respond 400.
	// http.ServeMux %-decodes path segments before matching, so we pass them
	// URL-encoded here. Bare ".." and "." are handled by the mux's path
	// cleanup (307/404 before our handler runs) — the defense-in-depth check
	// in putAttachment still rejects them if the handler is ever called
	// directly, but they're not testable over the HTTP wire.
	for _, name := range []string{
		"..%2Fetc%2Fpasswd", // ../etc/passwd
		"%2Fetc%2Fpasswd",   // /etc/passwd
		"..%5Cwin",          // ..\win
	} {
		code := putAttachment(t, url, "tok-tester", "b_path", name, []byte("x"))
		if code != http.StatusBadRequest {
			t.Errorf("name %q: status = %d, want 400", name, code)
		}
	}
}

// TestPutAttachment_SenderStillWorks: sanity — the original sender flow
// (used by /handoff with swagger snapshot) still goes through.
func TestPutAttachment_SenderStillWorks(t *testing.T) {
	url, st := attachmentTestRig(t)
	seedBugHandoff(t, st, "b_sender", "tester", []string{"backend"})

	if code := putAttachment(t, url, "tok-tester", "b_sender", "screen.png", []byte("png")); code != http.StatusCreated {
		t.Errorf("sender upload: status = %d, want 201", code)
	}
}
