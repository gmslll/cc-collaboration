package relay_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
)

// TestWSUpgradeAndBroker verifies /v1/ws actually upgrades through the full
// Handler stack — including the logging middleware that wraps the
// ResponseWriter in statusRecorder. Regression guard: without statusRecorder
// forwarding Hijack, websocket.Accept returns 501 and both ends fail to connect.
// It also checks a client frame is brokered to the same identity's host.
func TestWSUpgradeAndBroker(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[{"token":"tok-a","identity":"a@x"}]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)

	wsURL := "ws" + srv.URL[len("http"):] // http(s)://… -> ws(s)://…
	opts := &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": {"Bearer tok-a"}},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	host, _, err := websocket.Dial(ctx, wsURL+"/v1/ws?role=host", opts)
	if err != nil {
		t.Fatalf("host ws upgrade failed (regression: statusRecorder.Hijack missing?): %v", err)
	}
	defer host.CloseNow()

	client, _, err := websocket.Dial(ctx, wsURL+"/v1/ws?role=client", opts)
	if err != nil {
		t.Fatalf("client ws upgrade failed: %v", err)
	}
	defer client.CloseNow()
	_, hello, err := client.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var clientHello struct {
		ConnID uint64 `json:"connId"`
	}
	if err := json.Unmarshal(hello, &clientHello); err != nil || clientHello.ConnID == 0 {
		t.Fatalf("invalid client hello %q: %v", hello, err)
	}

	if err := client.Write(ctx, websocket.MessageText, []byte(`{"t":"hi","from":999999}`)); err != nil {
		t.Fatal(err)
	}
	// The host receives relay control frames (_hello/_peer) first, then the frame.
	hi, ok := readTextContaining(ctx, host, `"t":"hi"`)
	if !ok {
		t.Fatal("host never received the client's brokered frame")
	}
	var stamped struct {
		From uint64 `json:"from"`
	}
	if err := json.Unmarshal(hi, &stamped); err != nil || stamped.From != clientHello.ConnID {
		t.Fatalf("brokered from = %d, want authenticated connId %d (frame %q, err %v)", stamped.From, clientHello.ConnID, hi, err)
	}
	if err := client.Write(ctx, websocket.MessageText, []byte(`{"t":"pty.signal","kind":"mode","mode":"p2p"}`)); err != nil {
		t.Fatal(err)
	}
	if !waitForText(ctx, host, `"t":"pty.signal"`) {
		t.Fatal("host never received the PTY WebRTC signaling frame")
	}

	otherClient, _, err := websocket.Dial(ctx, wsURL+"/v1/ws?role=client", opts)
	if err != nil {
		t.Fatalf("second client ws upgrade failed: %v", err)
	}
	defer otherClient.CloseNow()
	_, otherHello, err := otherClient.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var other struct {
		ConnID uint64 `json:"connId"`
	}
	if err := json.Unmarshal(otherHello, &other); err != nil || other.ConnID == 0 {
		t.Fatalf("invalid second client hello %q: %v", otherHello, err)
	}
	if err := client.Write(ctx, websocket.MessageText, []byte(fmt.Sprintf(`{"t":"same-role","to":%d}`, other.ConnID))); err != nil {
		t.Fatal(err)
	}
	shortCtx, cancelShort := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancelShort()
	if waitForText(shortCtx, otherClient, `"t":"same-role"`) {
		t.Fatal("directed client frame reached another client")
	}
}

func TestWSStopsForwardingAfterUserDisabled(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if err := st.CreateUser(context.Background(), store.User{Identity: "a@x"}, time.Now()); err != nil {
		t.Fatal(err)
	}

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[{"token":"tok-a","identity":"a@x"}]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)

	wsURL := "ws" + srv.URL[len("http"):]
	opts := &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer tok-a"}}}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	host, _, err := websocket.Dial(ctx, wsURL+"/v1/ws?role=host", opts)
	if err != nil {
		t.Fatal(err)
	}
	defer host.CloseNow()
	client, _, err := websocket.Dial(ctx, wsURL+"/v1/ws?role=client", opts)
	if err != nil {
		t.Fatal(err)
	}
	defer client.CloseNow()
	if !waitForText(ctx, host, `"event":"connect"`) {
		t.Fatal("host never saw client connect")
	}

	if err := st.SetDisabled(context.Background(), "a@x", true); err != nil {
		t.Fatal(err)
	}
	if err := client.Write(ctx, websocket.MessageText, []byte(`{"t":"after-disable"}`)); err != nil {
		t.Fatal(err)
	}
	shortCtx, cancelShort := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancelShort()
	if waitForText(shortCtx, host, `"t":"after-disable"`) {
		t.Fatal("disabled user's ws frame was forwarded")
	}
}

func waitForText(ctx context.Context, c *websocket.Conn, want string) bool {
	_, ok := readTextContaining(ctx, c, want)
	return ok
}

func readTextContaining(ctx context.Context, c *websocket.Conn, want string) ([]byte, bool) {
	for i := 0; i < 10; i++ {
		_, data, err := c.Read(ctx)
		if err != nil {
			return nil, false
		}
		if strings.Contains(string(data), want) {
			return data, true
		}
	}
	return nil, false
}
