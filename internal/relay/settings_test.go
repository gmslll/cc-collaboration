package relay_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
)

func TestPutSettingRejectsOversizedBody(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	mkUser(t, st, "alice@x", "alicepass1")

	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)
	token := loginToken(t, srv.URL, "alice@x", "alicepass1")

	if code, body := putRawJSON(t, srv.URL+"/v1/settings/todo.view", token, `{"value":{"scope":"project"}}`); code != http.StatusOK {
		t.Fatalf("put setting = %d %s", code, body)
	}
	oversized := `{"value":"` + strings.Repeat("x", 70<<10) + `"}`
	if code, _ := putRawJSON(t, srv.URL+"/v1/settings/todo.view", token, oversized); code != http.StatusBadRequest {
		t.Fatalf("oversized put setting = %d, want 400", code)
	}

	value, found, err := st.GetSetting(context.Background(), "alice@x", "todo.view")
	if err != nil {
		t.Fatal(err)
	}
	if !found || value != `{"scope":"project"}` {
		t.Fatalf("oversized request changed setting: found=%v value=%s", found, value)
	}
}

func putRawJSON(t *testing.T, url, bearer, payload string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPut, url, strings.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	return do(t, req)
}
