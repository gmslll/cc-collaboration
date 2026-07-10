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
	"strings"
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
		Identity      string `json:"identity"`
		IsAdmin       bool   `json:"is_admin"`
		Organizations []struct {
			Name string `json:"name"`
			Role string `json:"role"`
		} `json:"organizations"`
	}
	_ = json.Unmarshal(body, &me)
	if me.Identity != "alice@backend" || !me.IsAdmin {
		t.Fatalf("me=%+v", me)
	}
	if len(me.Organizations) != 0 {
		t.Fatalf("login should not create default organization: %+v", me.Organizations)
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
		Token          string `json:"token"`
		MachineToken   string `json:"machine_token"`
		MachineTokenID string `json:"machine_token_id"`
		IsAdmin        bool   `json:"is_admin"`
	}
	if err := json.Unmarshal(body, &rr); err != nil {
		t.Fatal(err)
	}
	if rr.Token == "" {
		t.Fatal("no session token returned")
	}
	if rr.MachineToken == "" || rr.MachineTokenID == "" {
		t.Fatalf("no default machine token returned: %+v", rr)
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
	if len(me.Organizations) != 0 {
		t.Fatalf("registered account should start without organizations: %+v", me.Organizations)
	}
	if code, body = getAuthed(t, srv.URL+"/v1/me", rr.MachineToken); code != http.StatusOK {
		t.Fatalf("default machine token should authenticate: status=%d body=%s", code, body)
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

func TestRegisterRejectsReservedTokenIdentities(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if err := st.SeedMachineToken(context.Background(), "hash-cli", "cli@demo", time.Now()); err != nil {
		t.Fatal(err)
	}

	tokensPath := filepath.Join(t.TempDir(), "tokens.json")
	if err := os.WriteFile(tokensPath, []byte(`[{"token":"tok-legacy","identity":"legacy@demo"}]`), 0o600); err != nil {
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

	if code, _ := postJSON(t, srv.URL+"/v1/register", "",
		map[string]string{"identity": "legacy@demo", "password": "secret pass"}); code != http.StatusConflict {
		t.Fatalf("register legacy token identity: status=%d, want 409", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/register", "",
		map[string]string{"identity": "cli@demo", "password": "secret pass"}); code != http.StatusConflict {
		t.Fatalf("register machine token identity: status=%d, want 409", code)
	}
	if code, body := getAuthed(t, srv.URL+"/v1/me", "tok-legacy"); code != http.StatusOK {
		t.Fatalf("legacy token should still authenticate: status=%d body=%s", code, body)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/orgs", "tok-legacy",
		map[string]string{"name": "Legacy Team"}); code != http.StatusUnauthorized {
		t.Fatalf("legacy token create org: status=%d, want 401", code)
	}
	if code, _ := getAuthed(t, srv.URL+"/v1/projects", "tok-legacy"); code != http.StatusUnauthorized {
		t.Fatalf("legacy token list projects: status=%d, want 401", code)
	}
	if code, _ := getAuthed(t, srv.URL+"/v1/tokens", "tok-legacy"); code != http.StatusUnauthorized {
		t.Fatalf("legacy token list machine tokens: status=%d, want 401", code)
	}
}

func TestRegisterRejectsTrailingJSON(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
	}).Handler())
	t.Cleanup(srv.Close)

	if code, body := postRawJSON(t, srv.URL+"/v1/register", "",
		`{"identity":"tail@demo","password":"secret pass"} {"identity":"tail2@demo","password":"secret pass"}`); code != http.StatusBadRequest {
		t.Fatalf("register trailing json = %d %s", code, body)
	}
	if _, err := st.GetUser(context.Background(), "tail@demo"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("trailing register created first account: err=%v", err)
	}
	if _, err := st.GetUser(context.Background(), "tail2@demo"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("trailing register created second account: err=%v", err)
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

func TestUserBooleanMutationsRejectInvalidJSON(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	mkUser(t, st, "admin@demo", "adminpass1")
	mkUser(t, st, "admin-target@demo", "targetpass1")
	mkUser(t, st, "disabled-target@demo", "targetpass2")
	if err := st.SetAdmin(context.Background(), "admin-target@demo", true); err != nil {
		t.Fatal(err)
	}
	if err := st.SetDisabled(context.Background(), "disabled-target@demo", true); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
		SeedAdmins: []string{"admin@demo"},
	}).Handler())
	t.Cleanup(srv.Close)

	adminTok := loginToken(t, srv.URL, "admin@demo", "adminpass1")
	if code, body := postRawJSON(t, srv.URL+"/v1/users/admin-target@demo/admin", adminTok, "{"); code != http.StatusBadRequest {
		t.Fatalf("invalid admin json = %d %s", code, body)
	}
	if ok, err := st.UserIsAdmin(context.Background(), "admin-target@demo"); err != nil || !ok {
		t.Fatalf("invalid admin json changed admin state: ok=%v err=%v", ok, err)
	}

	if code, body := postRawJSON(t, srv.URL+"/v1/users/disabled-target@demo/disable", adminTok, "{"); code != http.StatusBadRequest {
		t.Fatalf("invalid disable json = %d %s", code, body)
	}
	u, err := st.GetUser(context.Background(), "disabled-target@demo")
	if err != nil {
		t.Fatal(err)
	}
	if !u.Disabled {
		t.Fatal("invalid disable json changed disabled state")
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
	users, err := st.ListUsers(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, user := range users {
		if user.Identity == "  member@demo  " {
			t.Fatalf("untrimmed account should not exist in stored users: %+v", users)
		}
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
	if len(me.Organizations) != 0 {
		t.Fatalf("admin-created account should start without organizations: %+v", me.Organizations)
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

func postRawJSON(t *testing.T, url, bearer, payload string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader(payload))
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
