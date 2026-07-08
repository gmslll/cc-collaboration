package relay_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
)

func TestLoginFlow(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	hash, _ := auth.HashPassword("correct horse battery")
	if err := st.CreateUser(context.Background(),
		store.User{Identity: "alice@backend", PasswordHash: hash}, time.Now()); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
		SeedAdmins: []string{"alice@backend"},
	}).Handler())
	t.Cleanup(srv.Close)

	// Wrong password → 401.
	if code, _ := postJSON(t, srv.URL+"/v1/login", "",
		map[string]string{"identity": "alice@backend", "password": "nope"}); code != http.StatusUnauthorized {
		t.Fatalf("wrong password: status=%d", code)
	}

	// Correct → 200 + session token; seed admin flagged is_admin.
	code, body := postJSON(t, srv.URL+"/v1/login", "",
		map[string]string{"identity": "alice@backend", "password": "correct horse battery"})
	if code != http.StatusOK {
		t.Fatalf("login status=%d body=%s", code, body)
	}
	var lr struct {
		Token   string `json:"token"`
		IsAdmin bool   `json:"is_admin"`
	}
	if err := json.Unmarshal(body, &lr); err != nil {
		t.Fatal(err)
	}
	if lr.Token == "" {
		t.Fatal("no session token returned")
	}
	if !lr.IsAdmin {
		t.Error("seed admin should be is_admin")
	}

	// /v1/me with the session bearer.
	code, body = getAuthed(t, srv.URL+"/v1/me", lr.Token)
	if code != http.StatusOK {
		t.Fatalf("me status=%d", code)
	}
	var me struct {
		Identity string `json:"identity"`
		IsAdmin  bool   `json:"is_admin"`
	}
	_ = json.Unmarshal(body, &me)
	if me.Identity != "alice@backend" || !me.IsAdmin {
		t.Fatalf("me=%+v", me)
	}

	// No token → 401.
	if code, _ := getAuthed(t, srv.URL+"/v1/me", ""); code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated me: status=%d", code)
	}

	// Logout revokes the session.
	if code, _ := postJSON(t, srv.URL+"/v1/logout", lr.Token, nil); code != http.StatusOK {
		t.Fatalf("logout status=%d", code)
	}
	if code, _ := getAuthed(t, srv.URL+"/v1/me", lr.Token); code != http.StatusUnauthorized {
		t.Fatalf("me after logout: status=%d", code)
	}
}

// TestRegisterFlow exercises open self-registration: a brand-new account is
// created from {identity, password}, gets an immediately-usable session, is a
// non-admin, rejects a duplicate identity, requires a password, and can then
// log in normally.
func TestRegisterFlow(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
	}).Handler())
	t.Cleanup(srv.Close)

	// Register a fresh account → 201 + session token, non-admin.
	code, body := postJSON(t, srv.URL+"/v1/register", "",
		map[string]string{"identity": "carol@demo", "password": "secret pass"})
	if code != http.StatusCreated {
		t.Fatalf("register status=%d body=%s", code, body)
	}
	var rr struct {
		Token   string `json:"token"`
		IsAdmin bool   `json:"is_admin"`
	}
	if err := json.Unmarshal(body, &rr); err != nil {
		t.Fatal(err)
	}
	if rr.Token == "" {
		t.Fatal("no session token returned")
	}
	if rr.IsAdmin {
		t.Error("self-registered account must not be admin")
	}

	// The returned token is immediately usable (auto-login).
	code, body = getAuthed(t, srv.URL+"/v1/me", rr.Token)
	if code != http.StatusOK {
		t.Fatalf("me status=%d", code)
	}
	var me struct {
		Identity string `json:"identity"`
		IsAdmin  bool   `json:"is_admin"`
	}
	_ = json.Unmarshal(body, &me)
	if me.Identity != "carol@demo" || me.IsAdmin {
		t.Fatalf("me=%+v", me)
	}

	// Duplicate identity → 409.
	if code, _ := postJSON(t, srv.URL+"/v1/register", "",
		map[string]string{"identity": "carol@demo", "password": "other"}); code != http.StatusConflict {
		t.Fatalf("duplicate register: status=%d", code)
	}

	// Missing password → 400.
	if code, _ := postJSON(t, srv.URL+"/v1/register", "",
		map[string]string{"identity": "dave@demo", "password": ""}); code != http.StatusBadRequest {
		t.Fatalf("missing password: status=%d", code)
	}

	// The registered account can log in with its credentials.
	if code, _ := postJSON(t, srv.URL+"/v1/login", "",
		map[string]string{"identity": "carol@demo", "password": "secret pass"}); code != http.StatusOK {
		t.Fatalf("login after register: status=%d", code)
	}
}

func TestRegisterCanBeDisabled(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
		DisableRegistration: true,
	}).Handler())
	t.Cleanup(srv.Close)

	code, body := postJSON(t, srv.URL+"/v1/register", "",
		map[string]string{"identity": "carol@demo", "password": "secret pass"})
	if code != http.StatusForbidden {
		t.Fatalf("register when disabled: status=%d body=%s", code, body)
	}
}

func TestDisabledUserInvalidatesAllBearerSources(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	hash, _ := auth.HashPassword("pw-12345678")
	if err := st.CreateUser(context.Background(),
		store.User{Identity: "alice@backend", PasswordHash: hash}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateMachineToken(context.Background(),
		auth.HashToken("machine-alice"), "alice@backend", "laptop", time.Now()); err != nil {
		t.Fatal(err)
	}

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[{"token":"file-alice","identity":"alice@backend"}]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: tokens, Hub: sse.NewHub(),
	}).Handler())
	t.Cleanup(srv.Close)

	code, body := postJSON(t, srv.URL+"/v1/login", "",
		map[string]string{"identity": "alice@backend", "password": "pw-12345678"})
	if code != http.StatusOK {
		t.Fatalf("login status=%d body=%s", code, body)
	}
	var lr struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(body, &lr); err != nil {
		t.Fatal(err)
	}
	for name, token := range map[string]string{
		"session": lr.Token,
		"machine": "machine-alice",
		"file":    "file-alice",
	} {
		if code, _ := getAuthed(t, srv.URL+"/v1/me", token); code != http.StatusOK {
			t.Fatalf("%s token before disable: status=%d", name, code)
		}
	}

	if err := st.SetDisabled(context.Background(), "alice@backend", true); err != nil {
		t.Fatal(err)
	}
	for name, token := range map[string]string{
		"session": lr.Token,
		"machine": "machine-alice",
		"file":    "file-alice",
	} {
		if code, _ := getAuthed(t, srv.URL+"/v1/me", token); code != http.StatusUnauthorized {
			t.Fatalf("%s token after disable: status=%d", name, code)
		}
	}
}

// TestBackCompatFileToken pins that a legacy tokens.json bearer still
// authenticates via the seed resolver after the multi-source refactor.
func TestBackCompatFileToken(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[{"token":"tok-bob","identity":"bob@frontend"}]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens := auth.NewTokens()
	if err := tokens.LoadFile(tokensPath); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer((&relay.Server{Store: st, Tokens: tokens, Hub: sse.NewHub()}).Handler())
	t.Cleanup(srv.Close)

	code, body := getAuthed(t, srv.URL+"/v1/me", "tok-bob")
	if code != http.StatusOK {
		t.Fatalf("file token me: status=%d", code)
	}
	var me struct {
		Identity string `json:"identity"`
	}
	_ = json.Unmarshal(body, &me)
	if me.Identity != "bob@frontend" {
		t.Fatalf("got identity %q", me.Identity)
	}
}

func postJSON(t *testing.T, url, bearer string, payload any) (int, []byte) {
	t.Helper()
	var body io.Reader
	if payload != nil {
		b, _ := json.Marshal(payload)
		body = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(http.MethodPost, url, body)
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	return do(t, req)
}

func getAuthed(t *testing.T, url, bearer string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	return do(t, req)
}

func do(t *testing.T, req *http.Request) (int, []byte) {
	t.Helper()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}
