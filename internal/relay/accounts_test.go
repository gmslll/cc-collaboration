package relay_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
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
		Identity      string `json:"identity"`
		IsAdmin       bool   `json:"is_admin"`
		Organizations []struct {
			Role string `json:"role"`
		} `json:"organizations"`
	}
	_ = json.Unmarshal(body, &me)
	if me.Identity != "carol@demo" || me.IsAdmin {
		t.Fatalf("me=%+v", me)
	}
	if len(me.Organizations) != 1 || me.Organizations[0].Role != "owner" {
		t.Fatalf("registered default organization = %+v", me.Organizations)
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

func TestDisabledUserRevokesExistingAuth(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	mkUser(t, st, "admin@demo", "adminpass1")
	mkUser(t, st, "user@demo", "userpass1")

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
		SeedAdmins: []string{"admin@demo"},
	}).Handler())
	t.Cleanup(srv.Close)

	adminTok := loginToken(t, srv.URL, "admin@demo", "adminpass1")
	userTok := loginToken(t, srv.URL, "user@demo", "userpass1")
	if code, _ := getAuthed(t, srv.URL+"/v1/me", userTok); code != http.StatusOK {
		t.Fatalf("me before disable = %d", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/users/user@demo/disable", adminTok,
		map[string]bool{"disabled": true}); code != http.StatusOK {
		t.Fatalf("disable user = %d", code)
	}
	if code, _ := getAuthed(t, srv.URL+"/v1/me", userTok); code != http.StatusUnauthorized {
		t.Fatalf("me after disable = %d", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/login", "",
		map[string]string{"identity": "user@demo", "password": "userpass1"}); code != http.StatusUnauthorized {
		t.Fatalf("login disabled user = %d", code)
	}
}

func TestAdminCreateUserTrimsIdentity(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	mkUser(t, st, "admin@demo", "adminpass1")
	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
		SeedAdmins: []string{"admin@demo"},
	}).Handler())
	t.Cleanup(srv.Close)

	adminTok := loginToken(t, srv.URL, "admin@demo", "adminpass1")
	code, body := postJSON(t, srv.URL+"/v1/users", adminTok,
		map[string]any{"identity": "  member@demo  ", "password": "memberpass1"})
	if code != http.StatusCreated {
		t.Fatalf("create trimmed user = %d %s", code, body)
	}
	var created struct {
		Identity string `json:"identity"`
	}
	if err := json.Unmarshal(body, &created); err != nil {
		t.Fatal(err)
	}
	if created.Identity != "member@demo" {
		t.Fatalf("created identity = %q, want trimmed", created.Identity)
	}
	if _, err := st.GetUser(context.Background(), "  member@demo  "); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("untrimmed account should not exist, got err=%v", err)
	}

	memberTok := loginToken(t, srv.URL, "  member@demo  ", "memberpass1")
	code, body = getAuthed(t, srv.URL+"/v1/me", memberTok)
	if code != http.StatusOK {
		t.Fatalf("me for trimmed user = %d %s", code, body)
	}
	var me struct {
		Identity      string `json:"identity"`
		Organizations []struct {
			Name string `json:"name"`
		} `json:"organizations"`
	}
	if err := json.Unmarshal(body, &me); err != nil {
		t.Fatal(err)
	}
	if me.Identity != "member@demo" {
		t.Fatalf("me identity = %q, want trimmed", me.Identity)
	}
	if len(me.Organizations) != 1 || me.Organizations[0].Name != "member@demo's team" {
		t.Fatalf("default organization should use trimmed identity: %+v", me.Organizations)
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
