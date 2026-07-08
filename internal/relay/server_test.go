package relay_test

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
	"github.com/cc-collaboration/pkg/handoffschema"
)

func TestListOnlineUsers(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[
		{"token":"tok-alice","identity":"alice@backend"},
		{"token":"tok-bob",  "identity":"bob@frontend"}
	]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}

	hub := sse.NewHub()
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: hub}).Handler())
	t.Cleanup(srv.Close)

	// --- baseline: nobody subscribed yet, both should be offline ---
	got := fetchOnline(t, srv.URL, "tok-bob")
	wantBaseline := []handoffschema.OnlineUser{
		{Identity: "alice@backend", Online: false},
		{Identity: "bob@frontend", Online: false},
	}
	if !sameUsers(got, wantBaseline) {
		t.Fatalf("baseline online list = %+v, want %+v", got, wantBaseline)
	}

	// --- alice opens an SSE stream ---
	streamCtx, cancelStream := context.WithCancel(context.Background())
	t.Cleanup(cancelStream)
	streamReq, _ := http.NewRequestWithContext(streamCtx, http.MethodGet, srv.URL+"/v1/events", nil)
	streamReq.Header.Set("Authorization", "Bearer tok-alice")
	streamResp, err := http.DefaultClient.Do(streamReq)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = streamResp.Body.Close() })
	if streamResp.StatusCode != http.StatusOK {
		t.Fatalf("alice subscribe: status=%d", streamResp.StatusCode)
	}
	// Drain the initial ": connected" frame so the request body is flowing
	// before we observe Hub state.
	buf := make([]byte, 64)
	if _, err := streamResp.Body.Read(buf); err != nil && err != io.EOF {
		t.Fatalf("read initial SSE frame: %v", err)
	}

	waitForHub(t, hub, func(ids []string) bool { return slices.Contains(ids, "alice@backend") })

	got = fetchOnline(t, srv.URL, "tok-bob")
	wantSubscribed := []handoffschema.OnlineUser{
		{Identity: "alice@backend", Online: true},
		{Identity: "bob@frontend", Online: false},
	}
	if !sameUsers(got, wantSubscribed) {
		t.Fatalf("after alice subscribed, online list = %+v, want %+v", got, wantSubscribed)
	}

	// --- alice disconnects; she should drop back to offline ---
	cancelStream()
	_ = streamResp.Body.Close()
	waitForHub(t, hub, func(ids []string) bool { return !slices.Contains(ids, "alice@backend") })

	got = fetchOnline(t, srv.URL, "tok-bob")
	if !sameUsers(got, wantBaseline) {
		t.Fatalf("after alice disconnect, online list = %+v, want %+v", got, wantBaseline)
	}
}

func TestListOnlineUsersIncludesDBUsersAndFiltersDisabled(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	now := time.Now()
	if err := st.CreateUser(context.Background(), store.User{Identity: "active@team"}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateUser(context.Background(), store.User{Identity: "db@team"}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateUser(context.Background(), store.User{Identity: "disabled@team", Disabled: true}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateOrganization(context.Background(), "org-active", "Active", "active@team", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(context.Background(), "org-active", "db@team", store.OrgRoleMember); err != nil {
		t.Fatal(err)
	}

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[
		{"token":"tok-active","identity":"active@team"},
		{"token":"tok-disabled","identity":"disabled@team"}
	]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)

	got := fetchOnline(t, srv.URL, "tok-active")
	want := []handoffschema.OnlineUser{
		{Identity: "active@team", Online: false},
		{Identity: "db@team", Online: false},
	}
	if !sameUsers(got, want) {
		t.Fatalf("online list = %+v, want %+v", got, want)
	}
}

func TestListOnlineUsersScopedBySharedTeam(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ctx := context.Background()
	now := time.Now()
	mkUser(t, st, "alice@backend", "alicepass1")
	mkUser(t, st, "bob@frontend", "bobpass123")
	mkUser(t, st, "mallory@other", "mallorypass1")
	if err := st.CreateOrganization(ctx, "org-shared", "Shared", "alice@backend", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org-shared", "bob@frontend", store.OrgRoleMember); err != nil {
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

	got := fetchOnline(t, srv.URL, "tok-alice")
	want := []handoffschema.OnlineUser{
		{Identity: "alice@backend", Online: false},
		{Identity: "bob@frontend", Online: false},
	}
	if !sameUsers(got, want) {
		t.Fatalf("scoped online list = %+v, want %+v", got, want)
	}
}

func TestPresenceEventsScopedBySharedTeam(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ctx := context.Background()
	now := time.Now()
	mkUser(t, st, "alice@backend", "alicepass1")
	mkUser(t, st, "bob@frontend", "bobpass123")
	mkUser(t, st, "mallory@other", "mallorypass1")
	if err := st.CreateOrganization(ctx, "org-shared", "Shared", "alice@backend", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org-shared", "bob@frontend", store.OrgRoleMember); err != nil {
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

	hub := sse.NewHub()
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: hub}).Handler())
	t.Cleanup(srv.Close)

	bobLines, closeBob := openEventLines(t, srv.URL, "tok-bob")
	t.Cleanup(closeBob)
	malloryLines, closeMallory := openEventLines(t, srv.URL, "tok-mallory")
	t.Cleanup(closeMallory)
	waitForHub(t, hub, func(ids []string) bool {
		return slices.Contains(ids, "bob@frontend") && slices.Contains(ids, "mallory@other")
	})

	_, closeAlice := openEventLines(t, srv.URL, "tok-alice")
	t.Cleanup(closeAlice)
	waitForHub(t, hub, func(ids []string) bool { return slices.Contains(ids, "alice@backend") })

	if !awaitPresence(t, bobLines, "alice@backend", true, 2*time.Second) {
		t.Fatal("shared teammate did not receive alice online presence")
	}
	if awaitPresence(t, malloryLines, "alice@backend", true, 200*time.Millisecond) {
		t.Fatal("cross-team subscriber received alice online presence")
	}
}

func TestDisabledSeedAdminDoesNotReceivePresenceAfterDisable(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	now := time.Now()
	mkUser(t, st, "seed@ops", "seedpass1")
	mkUser(t, st, "alice@team", "alicepass1")
	if err := st.CreateOrganization(context.Background(), "org-alice", "Alice", "alice@team", now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateOrganization(context.Background(), "org-seed", "Seed", "seed@ops", now); err != nil {
		t.Fatal(err)
	}

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[
		{"token":"tok-seed","identity":"seed@ops"},
		{"token":"tok-alice","identity":"alice@team"}
	]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}

	hub := sse.NewHub()
	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: tokens, Hub: hub, SeedAdmins: []string{"seed@ops"},
	}).Handler())
	t.Cleanup(srv.Close)

	seedLines, closeSeed := openEventLines(t, srv.URL, "tok-seed")
	t.Cleanup(closeSeed)
	waitForHub(t, hub, func(ids []string) bool { return slices.Contains(ids, "seed@ops") })
	if err := st.SetDisabled(context.Background(), "seed@ops", true); err != nil {
		t.Fatal(err)
	}

	_, closeAlice := openEventLines(t, srv.URL, "tok-alice")
	t.Cleanup(closeAlice)
	waitForHub(t, hub, func(ids []string) bool { return slices.Contains(ids, "alice@team") })

	if awaitPresence(t, seedLines, "alice@team", true, 200*time.Millisecond) {
		t.Fatal("disabled seed admin received cross-team presence after disable")
	}
}

func TestDisabledRecipientDoesNotReceiveCommentEventsAfterDisable(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ctx := context.Background()
	now := time.Now()
	mkUser(t, st, "alice@backend", "alicepass1")
	mkUser(t, st, "bob@frontend", "bobpass123")
	if err := st.CreateOrganization(ctx, "org-shared", "Shared", "alice@backend", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org-shared", "bob@frontend", store.OrgRoleMember); err != nil {
		t.Fatal(err)
	}

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[
		{"token":"tok-alice","identity":"alice@backend"},
		{"token":"tok-bob",  "identity":"bob@frontend"}
	]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}

	hub := sse.NewHub()
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: hub}).Handler())
	t.Cleanup(srv.Close)

	bobLines, closeBob := openEventLines(t, srv.URL, "tok-bob")
	t.Cleanup(closeBob)
	waitForHub(t, hub, func(ids []string) bool { return slices.Contains(ids, "bob@frontend") })

	code, body := postJSON(t, srv.URL+"/v1/handoffs", "tok-alice", handoffschema.Package{
		SchemaVersion: handoffschema.SchemaVersion,
		Recipient:     "bob@frontend",
		Urgency:       handoffschema.UrgencyNormal,
		SummaryMD:     "please review",
	})
	if code != http.StatusCreated {
		t.Fatalf("submit handoff = %d %s", code, body)
	}
	var created struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &created); err != nil {
		t.Fatal(err)
	}
	if created.ID == "" {
		t.Fatalf("submit handoff response missing id: %s", body)
	}

	if err := st.SetDisabled(context.Background(), "bob@frontend", true); err != nil {
		t.Fatal(err)
	}
	if code, body := postJSON(t, srv.URL+"/v1/handoffs/"+created.ID+"/comment", "tok-alice",
		map[string]string{"body": "follow-up after disable"}); code != http.StatusCreated {
		t.Fatalf("post comment = %d %s", code, body)
	}
	if awaitEventType(t, bobLines, sse.EventTypeCommentCreated, 200*time.Millisecond) {
		t.Fatal("disabled recipient received comment.created after disable")
	}
}

func TestListOnlineUsersUnauthorized(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	tokens := auth.NewTokens()
	hub := sse.NewHub()
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: hub}).Handler())
	t.Cleanup(srv.Close)

	resp, err := http.Get(srv.URL + "/v1/users/online")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("missing-token GET /v1/users/online status=%d, want 401", resp.StatusCode)
	}
}

func TestUIServing(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	tokens := auth.NewTokens()
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)

	client := srv.Client()
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	}
	resp, err := client.Get(srv.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("GET / status=%d, want 302", resp.StatusCode)
	}
	if loc := resp.Header.Get("Location"); loc != "/ui/" {
		t.Fatalf("GET / Location=%q, want /ui/", loc)
	}

	uiResp, err := http.Get(srv.URL + "/ui/")
	if err != nil {
		t.Fatal(err)
	}
	defer uiResp.Body.Close()
	if uiResp.StatusCode != http.StatusOK {
		t.Fatalf("GET /ui/ status=%d, want 200", uiResp.StatusCode)
	}
	body, _ := io.ReadAll(uiResp.Body)
	if !strings.Contains(string(body), "cc-handoff") {
		t.Fatalf("GET /ui/ body does not look like the embedded UI")
	}

	apiResp, err := http.Get(srv.URL + "/v1/handoffs")
	if err != nil {
		t.Fatal(err)
	}
	defer apiResp.Body.Close()
	if apiResp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("GET /v1/handoffs without token status=%d, want 401", apiResp.StatusCode)
	}
}

func openEventLines(t *testing.T, baseURL, token string) (<-chan string, func()) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/v1/events", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		cancel()
		_ = resp.Body.Close()
		t.Fatalf("GET /v1/events status=%d", resp.StatusCode)
	}
	lines := make(chan string, 64)
	go func() {
		defer close(lines)
		sc := bufio.NewScanner(resp.Body)
		for sc.Scan() {
			lines <- sc.Text()
		}
	}()
	return lines, func() {
		cancel()
		_ = resp.Body.Close()
	}
}

func awaitPresence(t *testing.T, lines <-chan string, identity string, online bool, timeout time.Duration) bool {
	t.Helper()
	deadline := time.After(timeout)
	event := ""
	for {
		select {
		case ln, ok := <-lines:
			if !ok {
				return false
			}
			switch {
			case strings.HasPrefix(ln, "event: "):
				event = strings.TrimPrefix(ln, "event: ")
			case strings.HasPrefix(ln, "data: "):
				if event != sse.EventTypeUserOnline && event != sse.EventTypeUserOffline {
					continue
				}
				var user handoffschema.OnlineUser
				if err := json.Unmarshal([]byte(strings.TrimPrefix(ln, "data: ")), &user); err != nil {
					t.Fatalf("decode presence event: %v", err)
				}
				if user.Identity == identity && user.Online == online {
					return true
				}
			case ln == "":
				event = ""
			}
		case <-deadline:
			return false
		}
	}
}

func awaitEventType(t *testing.T, lines <-chan string, eventType string, timeout time.Duration) bool {
	t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case ln, ok := <-lines:
			if !ok {
				return false
			}
			if strings.TrimSpace(strings.TrimPrefix(ln, "event:")) == eventType && strings.HasPrefix(ln, "event:") {
				return true
			}
		case <-deadline:
			return false
		}
	}
}

func fetchOnline(t *testing.T, baseURL, token string) []handoffschema.OnlineUser {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, baseURL+"/v1/users/online", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("GET /v1/users/online status=%d body=%s", resp.StatusCode, body)
	}
	var out struct {
		Users []handoffschema.OnlineUser `json:"users"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	return out.Users
}

func sameUsers(got, want []handoffschema.OnlineUser) bool {
	gc := append([]handoffschema.OnlineUser(nil), got...)
	wc := append([]handoffschema.OnlineUser(nil), want...)
	sort.Slice(gc, func(i, j int) bool { return gc[i].Identity < gc[j].Identity })
	sort.Slice(wc, func(i, j int) bool { return wc[i].Identity < wc[j].Identity })
	return reflect.DeepEqual(gc, wc)
}

func waitForHub(t *testing.T, hub *sse.Hub, ok func([]string) bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		ids := hub.OnlineRecipients()
		if ok(ids) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("hub never converged; OnlineRecipients=%v", ids)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
