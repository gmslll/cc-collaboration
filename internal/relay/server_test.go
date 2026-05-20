package relay_test

import (
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
