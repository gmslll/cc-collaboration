package relay_test

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
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

// TestSessionRegistryAndMessage exercises the cross-user path end to end: alice
// publishes her open sessions, bob fetches them, alice sends a message targeting
// one of bob's sessions, and bob's SSE stream receives a message.deliver event
// with the sender stamped server-side.
func TestSessionRegistryAndMessage(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
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

	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)

	// alice publishes her open sessions.
	if code, body := postJSON(t, srv.URL+"/v1/sessions", "tok-alice", map[string]any{
		"sessions": []map[string]string{
			{"id": "ts0", "label": "api", "project": "backend", "workdir": "/x"},
			{"id": "ts1", "label": "web", "project": "frontend"},
		},
	}); code != http.StatusOK {
		t.Fatalf("publish sessions: status=%d body=%s", code, body)
	}

	// bob fetches alice's sessions.
	code, body := getAuth(t, srv.URL+"/v1/users/"+url.PathEscape("alice@backend")+"/sessions", "tok-bob")
	if code != http.StatusOK {
		t.Fatalf("get sessions: status=%d", code)
	}
	var got struct {
		Sessions []handoffschema.SessionInfo `json:"sessions"`
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Sessions) != 2 || got.Sessions[0].ID != "ts0" || got.Sessions[1].Label != "web" {
		t.Fatalf("alice sessions mismatch: %+v", got.Sessions)
	}

	// bob publishes the session alice will target, then opens an SSE stream to receive it.
	if code, body := postJSON(t, srv.URL+"/v1/sessions", "tok-bob", map[string]any{
		"sessions": []map[string]string{
			{"id": "ts3", "label": "review", "project": "frontend", "project_id": "project-frontend"},
		},
	}); code != http.StatusOK {
		t.Fatalf("publish bob sessions: status=%d body=%s", code, body)
	}

	streamCtx, cancelStream := context.WithCancel(context.Background())
	t.Cleanup(cancelStream)
	streamReq, _ := http.NewRequestWithContext(streamCtx, http.MethodGet, srv.URL+"/v1/events", nil)
	streamReq.Header.Set("Authorization", "Bearer tok-bob")
	streamResp, err := http.DefaultClient.Do(streamReq)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = streamResp.Body.Close() })
	if streamResp.StatusCode != http.StatusOK {
		t.Fatalf("bob subscribe: status=%d", streamResp.StatusCode)
	}
	buf := make([]byte, 64)
	if _, err := streamResp.Body.Read(buf); err != nil && err != io.EOF {
		t.Fatalf("read initial SSE frame: %v", err)
	}
	lines := make(chan string, 64)
	go func() {
		sc := bufio.NewScanner(streamResp.Body)
		for sc.Scan() {
			lines <- sc.Text()
		}
		close(lines)
	}()

	if code, _ := postJSON(t, srv.URL+"/v1/messages", "tok-alice", map[string]any{
		"recipient": "bob@frontend", "session_id": "missing", "body": "wrong target",
	}); code != http.StatusNotFound {
		t.Fatalf("post message to unknown session: status=%d, want 404", code)
	}

	// alice sends a message targeting bob's session ts3.
	if code, body := postJSON(t, srv.URL+"/v1/messages", "tok-alice", map[string]any{
		"recipient":  "bob@frontend",
		"session_id": "ts3",
		"body":       "看下这段",
		"project":    " forged-backend ",
		"project_id": " forged-project ",
	}); code != http.StatusAccepted {
		t.Fatalf("post message: status=%d body=%s", code, body)
	}

	msg, ok := awaitMessageEvent(t, lines, 3*time.Second)
	if !ok {
		t.Fatal("timed out waiting for message.deliver on bob's stream")
	}
	if msg.From != "alice@backend" {
		t.Errorf("from = %q, want alice@backend (server-stamped)", msg.From)
	}
	if msg.SessionID != "ts3" || msg.Body != "看下这段" {
		t.Errorf("payload mismatch: %+v", msg)
	}
	if msg.Project != "frontend" || msg.ProjectID != "project-frontend" {
		t.Errorf("project context = (%q, %q), want (frontend, project-frontend)", msg.Project, msg.ProjectID)
	}
}

func TestSessionRegistryNormalizesPublishedSessions(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[
		{"token":"tok-alice","identity":"alice@backend"}
	]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)

	sessions := []map[string]string{
		{"id": "   ", "label": "drop me"},
		{"id": " ts0 ", "label": "   ", "project": " Team ", "project_id": " relay-team ", "workdir": " /tmp/work "},
		{
			"id":      strings.Repeat("x", 120),
			"label":   strings.Repeat("l", 200),
			"project": strings.Repeat("p", 200),
			"workdir": strings.Repeat("w", 700),
		},
	}
	for i := 0; i < 80; i++ {
		sessions = append(sessions, map[string]string{
			"id":    fmt.Sprintf("bulk-%02d", i),
			"label": fmt.Sprintf("bulk %02d", i),
		})
	}

	if code, body := postJSON(t, srv.URL+"/v1/sessions", "tok-alice", map[string]any{
		"sessions": sessions,
	}); code != http.StatusOK {
		t.Fatalf("publish sessions: status=%d body=%s", code, body)
	}

	code, body := getAuth(t, srv.URL+"/v1/users/"+url.PathEscape("alice@backend")+"/sessions", "tok-alice")
	if code != http.StatusOK {
		t.Fatalf("get sessions: status=%d", code)
	}
	var got struct {
		Sessions []handoffschema.SessionInfo `json:"sessions"`
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Sessions) != 64 {
		t.Fatalf("session count = %d, want 64", len(got.Sessions))
	}
	if got.Sessions[0].ID != "ts0" || got.Sessions[0].Label != "Session ts0" ||
		got.Sessions[0].Project != "Team" || got.Sessions[0].ProjectID != "relay-team" ||
		got.Sessions[0].Workdir != "/tmp/work" {
		t.Fatalf("trim/default mismatch: %+v", got.Sessions[0])
	}
	if len(got.Sessions[1].ID) != 96 || len(got.Sessions[1].Label) != 160 ||
		len(got.Sessions[1].Project) != 160 || len(got.Sessions[1].Workdir) != 512 {
		t.Fatalf("truncate mismatch: %+v", got.Sessions[1])
	}
}

func TestSessionRegistryRejectsTrailingJSON(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	mkUser(t, st, "alice@backend", "alicepass1")

	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)
	token := loginToken(t, srv.URL, "alice@backend", "alicepass1")

	if code, body := postJSON(t, srv.URL+"/v1/sessions", token, map[string]any{
		"sessions": []map[string]string{{"id": "ts0", "label": "api"}},
	}); code != http.StatusOK {
		t.Fatalf("publish sessions = %d %s", code, body)
	}
	if code, body := postRawJSON(t, srv.URL+"/v1/sessions", token,
		`{"sessions":[{"id":"ts1","label":"bad"}]} {"sessions":[]}`); code != http.StatusBadRequest {
		t.Fatalf("publish trailing json = %d %s", code, body)
	}

	code, body := getAuthed(t, srv.URL+"/v1/users/"+url.PathEscape("alice@backend")+"/sessions", token)
	if code != http.StatusOK {
		t.Fatalf("get sessions = %d %s", code, body)
	}
	var got struct {
		Sessions []handoffschema.SessionInfo `json:"sessions"`
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Sessions) != 1 || got.Sessions[0].ID != "ts0" {
		t.Fatalf("trailing json changed published sessions: %+v", got.Sessions)
	}
}

func TestPostMessageRejectsTrailingJSON(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	mkUser(t, st, "alice@backend", "alicepass1")

	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)
	token := loginToken(t, srv.URL, "alice@backend", "alicepass1")
	if code, body := postJSON(t, srv.URL+"/v1/sessions", token, map[string]any{
		"sessions": []map[string]string{{"id": "ts0", "label": "api"}},
	}); code != http.StatusOK {
		t.Fatalf("publish sessions = %d %s", code, body)
	}

	if code, body := postRawJSON(t, srv.URL+"/v1/messages", token,
		`{"recipient":"alice@backend","session_id":"ts0","body":"first"} {"recipient":"alice@backend","session_id":"ts0","body":"second"}`); code != http.StatusBadRequest {
		t.Fatalf("message trailing json = %d %s", code, body)
	}
}

func TestSessionRegistryRequiresSharedTeam(t *testing.T) {
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
	mkUser(t, st, "solo-a@x", "soloapass1")
	mkUser(t, st, "solo-b@x", "solobpass1")
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
		{"token":"tok-mallory",  "identity":"mallory@other"},
		{"token":"tok-solo-a",  "identity":"solo-a@x"},
		{"token":"tok-solo-b",  "identity":"solo-b@x"}
	]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)

	if code, body := postJSON(t, srv.URL+"/v1/sessions", "tok-alice", map[string]any{
		"sessions": []map[string]string{{"id": "ts0", "label": "api"}},
	}); code != http.StatusOK {
		t.Fatalf("publish sessions: status=%d body=%s", code, body)
	}

	if code, _ := getAuth(t, srv.URL+"/v1/users/"+url.PathEscape("alice@backend")+"/sessions", "tok-bob"); code != http.StatusOK {
		t.Fatalf("shared teammate get sessions = %d", code)
	}
	if code, _ := getAuth(t, srv.URL+"/v1/users/"+url.PathEscape("alice@backend")+"/sessions", "tok-mallory"); code != http.StatusForbidden {
		t.Fatalf("cross-team get sessions = %d, want 403", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/messages", "tok-mallory", map[string]any{
		"recipient": "alice@backend", "session_id": "ts0", "body": "cross tenant",
	}); code != http.StatusForbidden {
		t.Fatalf("cross-team message = %d, want 403", code)
	}
	if code, body := postJSON(t, srv.URL+"/v1/sessions", "tok-solo-a", map[string]any{
		"sessions": []map[string]string{{"id": "solo", "label": "solo"}},
	}); code != http.StatusOK {
		t.Fatalf("solo publish sessions: status=%d body=%s", code, body)
	}
	if code, _ := getAuth(t, srv.URL+"/v1/users/"+url.PathEscape("solo-a@x")+"/sessions", "tok-solo-b"); code != http.StatusForbidden {
		t.Fatalf("registered users without teams get sessions = %d, want 403", code)
	}
}

func TestDisableUserClearsPublishedSessions(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ctx := context.Background()
	now := time.Now()
	mkUser(t, st, "admin@ops", "adminpass1")
	mkUser(t, st, "alice@backend", "alicepass1")
	mkUser(t, st, "bob@frontend", "bobpass123")
	if err := st.SetAdmin(ctx, "admin@ops", true); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateOrganization(ctx, "org-shared", "Shared", "alice@backend", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, "org-shared", "bob@frontend", store.OrgRoleOwner); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)
	adminToken := loginToken(t, srv.URL, "admin@ops", "adminpass1")
	aliceToken := loginToken(t, srv.URL, "alice@backend", "alicepass1")
	bobToken := loginToken(t, srv.URL, "bob@frontend", "bobpass123")

	if code, body := postJSON(t, srv.URL+"/v1/sessions", aliceToken, map[string]any{
		"sessions": []map[string]string{{"id": "ts0", "label": "api"}},
	}); code != http.StatusOK {
		t.Fatalf("publish sessions = %d %s", code, body)
	}
	code, body := getAuth(t, srv.URL+"/v1/users/"+url.PathEscape("alice@backend")+"/sessions", bobToken)
	if code != http.StatusOK {
		t.Fatalf("baseline get sessions = %d %s", code, body)
	}
	var got struct {
		Sessions []handoffschema.SessionInfo `json:"sessions"`
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Sessions) != 1 || got.Sessions[0].ID != "ts0" {
		t.Fatalf("baseline sessions = %+v, want ts0", got.Sessions)
	}

	disableURL := srv.URL + "/v1/users/" + url.PathEscape("alice@backend") + "/disable"
	if code, body := postJSON(t, disableURL, adminToken, map[string]any{"disabled": true}); code != http.StatusOK {
		t.Fatalf("disable user = %d %s", code, body)
	}
	if code, body := postJSON(t, disableURL, adminToken, map[string]any{"disabled": false}); code != http.StatusOK {
		t.Fatalf("reenable user = %d %s", code, body)
	}

	code, body = getAuth(t, srv.URL+"/v1/users/"+url.PathEscape("alice@backend")+"/sessions", bobToken)
	if code != http.StatusOK {
		t.Fatalf("after reenable get sessions = %d %s", code, body)
	}
	got.Sessions = nil
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Sessions) != 0 {
		t.Fatalf("sessions survived disable/reenable: %+v", got.Sessions)
	}
}

func getAuth(t *testing.T, u, bearer string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, u, nil)
	req.Header.Set("Authorization", "Bearer "+bearer)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

// awaitMessageEvent scans SSE lines for an `event: message.deliver` frame and
// returns the decoded payload from its `data:` line.
func awaitMessageEvent(t *testing.T, lines <-chan string, timeout time.Duration) (handoffschema.Message, bool) {
	t.Helper()
	deadline := time.After(timeout)
	sawEvent := false
	for {
		select {
		case ln, open := <-lines:
			if !open {
				return handoffschema.Message{}, false
			}
			if strings.HasPrefix(ln, "event:") {
				sawEvent = strings.TrimSpace(strings.TrimPrefix(ln, "event:")) == sse.EventTypeMessageDeliver
				continue
			}
			if sawEvent && strings.HasPrefix(ln, "data:") {
				var m handoffschema.Message
				if err := json.Unmarshal([]byte(strings.TrimSpace(strings.TrimPrefix(ln, "data:"))), &m); err != nil {
					t.Fatalf("decode message data: %v", err)
				}
				return m, true
			}
		case <-deadline:
			return handoffschema.Message{}, false
		}
	}
}
