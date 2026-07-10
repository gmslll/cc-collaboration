package relay_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
)

func TestScreenShareStopsForwardingAfterUserDisabled(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
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

	host, _, err := websocket.Dial(ctx, wsURL+"/v1/screen-share/ws?role=host&room=room1", opts)
	if err != nil {
		t.Fatal(err)
	}
	defer host.CloseNow()
	viewer, _, err := websocket.Dial(ctx, wsURL+"/v1/screen-share/ws?role=viewer&room=room1", opts)
	if err != nil {
		t.Fatal(err)
	}
	defer viewer.CloseNow()
	if !waitForText(ctx, host, `"event":"connect"`) {
		t.Fatal("host never saw viewer connect")
	}

	if err := st.SetDisabled(context.Background(), "a@x", true); err != nil {
		t.Fatal(err)
	}
	if err := host.Write(ctx, websocket.MessageText, []byte(`{"t":"offer","sdp":"after-disable"}`)); err != nil {
		t.Fatal(err)
	}
	shortCtx, cancelShort := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancelShort()
	if waitForText(shortCtx, viewer, `"sdp":"after-disable"`) {
		t.Fatal("disabled user's screen-share frame was forwarded")
	}
}
