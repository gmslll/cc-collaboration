package main

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/inbox"
	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// TestCatchUpHandoffsAndComments simulates "frontend was offline, came back":
// sender pushes handoffs + comments via the in-process relay, the receiver
// then runs catchUp() and we verify inbox files + comment.md + cursor end up
// where the SSE handler would have put them.
func TestCatchUpHandoffsAndComments(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[
		{"token":"tok-back","identity":"user@backend"},
		{"token":"tok-front","identity":"alex@frontend"}
	]`), 0o644); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}
	hub := sse.NewHub()
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: hub}).Handler())
	t.Cleanup(srv.Close)

	ctx := context.Background()

	// Sender submits two handoffs while frontend is "offline".
	backClient := transport.New(srv.URL, "tok-back")
	pkg1 := newPkg("alex@frontend", "demo", "first handoff")
	pkg2 := newPkg("alex@frontend", "demo", "second handoff")
	r1, err := backClient.Submit(ctx, pkg1, nil)
	if err != nil {
		t.Fatalf("submit 1: %v", err)
	}
	r2, err := backClient.Submit(ctx, pkg2, nil)
	if err != nil {
		t.Fatalf("submit 2: %v", err)
	}

	// Sender also drops a comment on the first handoff.
	if _, err := backClient.Comment(ctx, r1.ID, "early thoughts on first"); err != nil {
		t.Fatalf("comment: %v", err)
	}

	// Receiver had run watch before (cursor exists at 0) — this simulates a
	// prior session that has now reconnected. Without an existing cursor,
	// catchUp would bootstrap and skip the comment instead of replaying it.
	repoRoot := t.TempDir()
	if err := inbox.SaveCursor(inbox.InboxDir(repoRoot, ""), inbox.WatchCursor{LastCommentID: 0}); err != nil {
		t.Fatalf("seed cursor: %v", err)
	}
	h := &watchHandler{
		client:   transport.New(srv.URL, "tok-front"),
		repoRoot: repoRoot,
		inboxDir: inbox.InboxDir(repoRoot, ""),
		res: &config.Resolved{
			RelayURL: srv.URL,
			Token:    "tok-front",
			Me:       "alex@frontend",
		},
		noNotify: true,
		noLaunch: true,
		seen:     map[string]bool{},
	}
	if err := h.catchUp(ctx); err != nil {
		t.Fatalf("catchUp: %v", err)
	}

	// Both handoffs materialized.
	for _, id := range []string{r1.ID, r2.ID} {
		for _, f := range []string{"package.json", "summary.md", "prompt.md"} {
			path := filepath.Join(repoRoot, ".cc-handoff/inbox", id, f)
			if _, err := os.Stat(path); err != nil {
				t.Errorf("expected materialized %s for %s: %v", f, id, err)
			}
		}
	}

	// Comment appended to first handoff's comments.md.
	commentsFile := filepath.Join(repoRoot, ".cc-handoff/inbox", r1.ID, "comments.md")
	body, err := os.ReadFile(commentsFile)
	if err != nil {
		t.Fatalf("read comments.md: %v", err)
	}
	if !strings.Contains(string(body), "early thoughts on first") {
		t.Errorf("comments.md missing comment body, got:\n%s", body)
	}

	// Cursor file exists and points past the comment we just consumed.
	cur, exists, err := inbox.LoadCursor(inbox.InboxDir(repoRoot, ""))
	if err != nil {
		t.Fatalf("LoadCursor: %v", err)
	}
	if !exists {
		t.Fatal("expected cursor file to exist after catch-up")
	}
	if cur.LastCommentID == 0 {
		t.Errorf("cursor not advanced: %+v", cur)
	}

	// Re-running catchUp must be a no-op (no duplicate notifications, cursor steady).
	prev := cur.LastCommentID
	if err := h.catchUp(ctx); err != nil {
		t.Fatalf("second catchUp: %v", err)
	}
	cur2, _, _ := inbox.LoadCursor(inbox.InboxDir(repoRoot, ""))
	if cur2.LastCommentID != prev {
		t.Errorf("cursor moved on idempotent re-run: %d -> %d", prev, cur2.LastCommentID)
	}
}

// TestCatchUpFirstRunSkipsHistory verifies bootstrap mode: when the cursor
// file is absent, existing comments are NOT replayed; the cursor is set to
// the relay's current max id so subsequent runs only see new traffic.
func TestCatchUpFirstRunSkipsHistory(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[
		{"token":"tok-back","identity":"user@backend"},
		{"token":"tok-front","identity":"alex@frontend"}
	]`), 0o644); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}
	hub := sse.NewHub()
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: hub}).Handler())
	t.Cleanup(srv.Close)

	ctx := context.Background()
	back := transport.New(srv.URL, "tok-back")

	// Submit a handoff and an old comment on it BEFORE frontend ever ran watch.
	pkg := newPkg("alex@frontend", "demo", "old handoff")
	res, err := back.Submit(ctx, pkg, nil)
	if err != nil {
		t.Fatalf("submit: %v", err)
	}
	// Pre-pickup it so list won't return it during catch-up — we want to
	// isolate the comment-history behavior here.
	front := transport.New(srv.URL, "tok-front")
	if err := front.Ack(ctx, res.ID); err != nil {
		t.Fatalf("ack: %v", err)
	}
	if _, err := back.Comment(ctx, res.ID, "ancient comment"); err != nil {
		t.Fatalf("comment: %v", err)
	}

	repoRoot := t.TempDir()
	h := &watchHandler{
		client:   front,
		repoRoot: repoRoot,
		inboxDir: inbox.InboxDir(repoRoot, ""),
		res:      &config.Resolved{RelayURL: srv.URL, Token: "tok-front", Me: "alex@frontend"},
		noNotify: true,
		noLaunch: true,
		seen:     map[string]bool{},
	}
	if err := h.catchUp(ctx); err != nil {
		t.Fatalf("catchUp: %v", err)
	}

	// Old comment must NOT have been materialized — first-run bootstrap skips history.
	commentsFile := filepath.Join(repoRoot, ".cc-handoff/inbox", res.ID, "comments.md")
	if _, err := os.Stat(commentsFile); err == nil {
		t.Errorf("expected comments.md to NOT exist on first-run bootstrap")
	}

	// Cursor must be set to the bootstrap max id (>0).
	cur, exists, err := inbox.LoadCursor(inbox.InboxDir(repoRoot, ""))
	if err != nil {
		t.Fatal(err)
	}
	if !exists || cur.LastCommentID == 0 {
		t.Errorf("expected bootstrapped cursor, got exists=%v cur=%+v", exists, cur)
	}

	// A NEW comment after bootstrap must be picked up on the next catchUp.
	if _, err := back.Comment(ctx, res.ID, "fresh comment"); err != nil {
		t.Fatalf("fresh comment: %v", err)
	}
	if err := h.catchUp(ctx); err != nil {
		t.Fatalf("second catchUp: %v", err)
	}
	body, err := os.ReadFile(commentsFile)
	if err != nil {
		t.Fatalf("read comments.md after fresh comment: %v", err)
	}
	if !strings.Contains(string(body), "fresh comment") {
		t.Errorf("comments.md should contain fresh comment, got:\n%s", body)
	}
	if strings.Contains(string(body), "ancient comment") {
		t.Errorf("ancient comment should not have been replayed")
	}
}

func newPkg(recipient, repoName, summary string) *handoffschema.Package {
	return &handoffschema.Package{
		Recipient: recipient,
		Repo:      handoffschema.Repo{Name: repoName},
		SummaryMD: summary,
		CreatedAt: time.Now().UTC(),
	}
}
