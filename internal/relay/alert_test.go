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
	"strings"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// TestPostAlert verifies the push-log path end to end at the relay: alice POSTs
// a log alert addressed to bob, and bob's SSE stream receives a log.alert event
// carrying the payload with the sender stamped server-side.
func TestPostAlert(t *testing.T) {
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

	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)

	// bob opens an SSE stream.
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
	// Drain the initial ": connected" frame so the subscription is live before
	// we publish.
	buf := make([]byte, 64)
	if _, err := streamResp.Body.Read(buf); err != nil && err != io.EOF {
		t.Fatalf("read initial SSE frame: %v", err)
	}

	// Collect SSE lines off the stream in the background.
	lines := make(chan string, 64)
	go func() {
		sc := bufio.NewScanner(streamResp.Body)
		for sc.Scan() {
			lines <- sc.Text()
		}
		close(lines)
	}()

	// alice forwards an alert addressed to bob.
	body := `{"recipient":"bob@frontend","project":"svc","level":"error","message":"ERROR kaboom"}`
	postReq, _ := http.NewRequest(http.MethodPost, srv.URL+"/v1/alerts", strings.NewReader(body))
	postReq.Header.Set("Authorization", "Bearer tok-alice")
	postReq.Header.Set("Content-Type", "application/json")
	postResp, err := http.DefaultClient.Do(postReq)
	if err != nil {
		t.Fatal(err)
	}
	_ = postResp.Body.Close()
	if postResp.StatusCode != http.StatusAccepted {
		t.Fatalf("POST /v1/alerts: status=%d, want 202", postResp.StatusCode)
	}

	alert, ok := awaitAlertEvent(t, lines, 3*time.Second)
	if !ok {
		t.Fatal("timed out waiting for log.alert event on bob's stream")
	}
	if alert.Recipient != "bob@frontend" {
		t.Errorf("recipient = %q, want bob@frontend", alert.Recipient)
	}
	if alert.Sender != "alice@backend" {
		t.Errorf("sender = %q, want alice@backend (server-stamped)", alert.Sender)
	}
	if alert.Project != "svc" || alert.Message != "ERROR kaboom" {
		t.Errorf("payload mismatch: %+v", alert)
	}
}

// awaitAlertEvent scans SSE lines for an `event: log.alert` frame and returns
// the decoded payload from its `data:` line.
func awaitAlertEvent(t *testing.T, lines <-chan string, timeout time.Duration) (handoffschema.LogAlert, bool) {
	t.Helper()
	deadline := time.After(timeout)
	sawEvent := false
	for {
		select {
		case ln, open := <-lines:
			if !open {
				return handoffschema.LogAlert{}, false
			}
			if strings.HasPrefix(ln, "event:") {
				sawEvent = strings.TrimSpace(strings.TrimPrefix(ln, "event:")) == sse.EventTypeLogAlert
				continue
			}
			if sawEvent && strings.HasPrefix(ln, "data:") {
				var a handoffschema.LogAlert
				if err := json.Unmarshal([]byte(strings.TrimSpace(strings.TrimPrefix(ln, "data:"))), &a); err != nil {
					t.Fatalf("decode log.alert data: %v", err)
				}
				return a, true
			}
		case <-deadline:
			return handoffschema.LogAlert{}, false
		}
	}
}
