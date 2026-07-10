package relay

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
)

func TestHasOtherAvailableAdminProtectsLastAdmin(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ctx := context.Background()
	now := time.Now()
	if err := st.CreateUser(ctx, store.User{Identity: "only@x", IsAdmin: true}, now); err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: st}
	if other, err := s.hasOtherAvailableAdmin(ctx, "only@x"); err != nil || other {
		t.Fatalf("only admin: other=%v err=%v", other, err)
	}
	if err := st.CreateUser(ctx, store.User{Identity: "other@x", IsAdmin: true}, now); err != nil {
		t.Fatal(err)
	}
	if other, err := s.hasOtherAvailableAdmin(ctx, "only@x"); err != nil || !other {
		t.Fatalf("active second admin: other=%v err=%v", other, err)
	}
	if err := st.SetDisabled(ctx, "other@x", true); err != nil {
		t.Fatal(err)
	}
	if other, err := s.hasOtherAvailableAdmin(ctx, "only@x"); err != nil || other {
		t.Fatalf("disabled second admin: other=%v err=%v", other, err)
	}

	// Operator-seeded admins are part of the effective admin set even without
	// a users row, matching Server.isAdmin's lockout-prevention semantics.
	s.SeedAdmins = []string{"seed@ops"}
	if other, err := s.hasOtherAvailableAdmin(ctx, "only@x"); err != nil || !other {
		t.Fatalf("seed admin: other=%v err=%v", other, err)
	}
}

func TestConcurrentAdminDeleteAndDisablePreservesAvailableAdmin(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ctx := context.Background()
	now := time.Now()
	for _, identity := range []string{"admin-a@x", "admin-b@x"} {
		if err := st.CreateUser(ctx, store.User{Identity: identity, IsAdmin: true}, now); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.CreateMachineToken(ctx, auth.HashToken("token-a"), "admin-a@x", "test", now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateMachineToken(ctx, auth.HashToken("token-b"), "admin-b@x", "test", now); err != nil {
		t.Fatal(err)
	}

	s := &Server{Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub()}
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)

	// Hold the mutation lock until both authenticated requests have entered
	// their handlers. Whichever mutation wins must invalidate the loser's
	// second admin check, leaving one effective administrator.
	s.accountMu.Lock()
	statuses := make(chan int, 2)
	start := make(chan struct{})
	request := func(method, path, token, body string) {
		<-start
		req, err := http.NewRequest(method, srv.URL+path, strings.NewReader(body))
		if err != nil {
			statuses <- 0
			return
		}
		req.Header.Set("Authorization", "Bearer "+token)
		if body != "" {
			req.Header.Set("Content-Type", "application/json")
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			statuses <- 0
			return
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		statuses <- resp.StatusCode
	}
	go request(http.MethodDelete, "/v1/users/admin-b@x", "token-a", "")
	go request(http.MethodPost, "/v1/users/admin-a@x/disable", "token-b", `{"disabled":true}`)
	close(start)
	time.Sleep(50 * time.Millisecond)
	s.accountMu.Unlock()

	got := []int{<-statuses, <-statuses}
	successes := 0
	for _, status := range got {
		if status == http.StatusOK {
			successes++
		}
	}
	if successes != 1 {
		t.Fatalf("concurrent admin mutations statuses=%v, want exactly one success", got)
	}
	available := 0
	for _, identity := range []string{"admin-a@x", "admin-b@x"} {
		if admin, err := st.UserIsAdmin(ctx, identity); err != nil {
			t.Fatal(err)
		} else if admin {
			available++
		}
	}
	if available != 1 {
		t.Fatalf("available admins=%d after concurrent mutations, statuses=%v; want 1", available, got)
	}
}
