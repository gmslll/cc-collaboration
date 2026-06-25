package relay_test

import (
	"bufio"
	"context"
	"encoding/json"
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

	// bob opens an SSE stream to receive the message.
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

	// alice sends a message targeting bob's session ts3.
	if code, body := postJSON(t, srv.URL+"/v1/messages", "tok-alice", map[string]any{
		"recipient": "bob@frontend", "session_id": "ts3", "body": "看下这段",
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
