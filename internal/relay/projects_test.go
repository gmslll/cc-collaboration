package relay_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
)

func TestProjectSelfServiceAndAdminGate(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	mkUser(t, st, "alice@backend", "alicepass1") // seed admin
	mkUser(t, st, "dev@backend", "devpass1234")
	mkUser(t, st, "mallory@x", "mallorypass1")
	mkUser(t, st, "qa@backend", "qapass1234")
	mkUser(t, st, "z@y", "zpass1234")

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
		SeedAdmins: []string{"alice@backend"},
	}).Handler())
	t.Cleanup(srv.Close)

	devTok := loginToken(t, srv.URL, "dev@backend", "devpass1234")
	aliceTok := loginToken(t, srv.URL, "alice@backend", "alicepass1")
	malTok := loginToken(t, srv.URL, "mallory@x", "mallorypass1")

	// Admin gate: non-admin 403, admin 200.
	if code, _ := getAuthed(t, srv.URL+"/v1/users", devTok); code != http.StatusForbidden {
		t.Fatalf("non-admin /v1/users = %d", code)
	}
	if code, _ := getAuthed(t, srv.URL+"/v1/users", aliceTok); code != http.StatusOK {
		t.Fatalf("admin /v1/users = %d", code)
	}

	// Self-service: dev creates a project and becomes its owner.
	code, body := postJSON(t, srv.URL+"/v1/projects", devTok, map[string]string{"name": "Kunlun"})
	if code != http.StatusCreated {
		t.Fatalf("create project = %d %s", code, body)
	}
	var proj struct {
		ID    string `json:"id"`
		OrgID string `json:"org_id"`
	}
	_ = json.Unmarshal(body, &proj)
	if proj.ID == "" || proj.OrgID == "" {
		t.Fatal("no project id")
	}
	var meAfterCreate struct {
		Organizations []struct {
			ID string `json:"id"`
		} `json:"organizations"`
	}
	_, body = getAuthed(t, srv.URL+"/v1/me", devTok)
	_ = json.Unmarshal(body, &meAfterCreate)
	if len(meAfterCreate.Organizations) != 1 {
		t.Fatalf("dev organizations = %+v", meAfterCreate.Organizations)
	}

	// Owner maps a repo + adds a member.
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/repos", devTok,
		map[string]string{"repo_name": "kunlun-backend"}); code != http.StatusOK {
		t.Fatalf("map repo = %d", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", devTok,
		map[string]string{"identity": "ghost@backend", "role": "viewer"}); code != http.StatusNotFound {
		t.Fatalf("add missing member = %d", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", devTok,
		map[string]string{"identity": "qa@backend", "role": "viewer"}); code != http.StatusOK {
		t.Fatalf("add member = %d", code)
	}

	// A non-owner, non-member, non-admin can neither manage nor view the project.
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", malTok,
		map[string]string{"identity": "x@y", "role": "member"}); code != http.StatusForbidden {
		t.Fatalf("non-owner manage = %d (want 403)", code)
	}
	if code, _ := getAuthed(t, srv.URL+"/v1/projects/"+proj.ID, malTok); code != http.StatusForbidden {
		t.Fatalf("non-member GET = %d (want 403)", code)
	}

	// Admin can manage any project.
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", aliceTok,
		map[string]string{"identity": "z@y", "role": "member"}); code != http.StatusOK {
		t.Fatalf("admin manage = %d", code)
	}
	if code, body := postJSON(t, srv.URL+"/v1/projects", aliceTok,
		map[string]string{"name": "Admin Project", "org_id": proj.OrgID}); code != http.StatusCreated {
		t.Fatalf("admin create org project = %d %s", code, body)
	}

	// /v1/me reflects dev's ownership.
	_, meBody := getAuthed(t, srv.URL+"/v1/me", devTok)
	var me struct {
		Projects []struct {
			ID   string `json:"id"`
			Role string `json:"role"`
		} `json:"projects"`
	}
	_ = json.Unmarshal(meBody, &me)
	if len(me.Projects) != 1 || me.Projects[0].Role != "owner" {
		t.Fatalf("me.projects = %+v", me.Projects)
	}

	// A member can GET the project detail (repos + members).
	if code, _ := getAuthed(t, srv.URL+"/v1/projects/"+proj.ID, devTok); code != http.StatusOK {
		t.Fatalf("owner GET project = %d", code)
	}
}

func TestOrganizationSaaSFlow(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	mkUser(t, st, "owner@demo", "ownerpass1")
	mkUser(t, st, "teammate@demo", "teampass1")

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
	}).Handler())
	t.Cleanup(srv.Close)

	ownerTok := loginToken(t, srv.URL, "owner@demo", "ownerpass1")
	teamTok := loginToken(t, srv.URL, "teammate@demo", "teampass1")

	code, body := postJSON(t, srv.URL+"/v1/orgs", ownerTok, map[string]string{"name": "Acme"})
	if code != http.StatusCreated {
		t.Fatalf("create org = %d %s", code, body)
	}
	var org store.Organization
	_ = json.Unmarshal(body, &org)
	if org.ID == "" || org.OwnerIdentity != "owner@demo" {
		t.Fatalf("org = %+v", org)
	}

	if code, _ := postJSON(t, srv.URL+"/v1/orgs/"+org.ID+"/members", teamTok,
		map[string]string{"identity": "owner@demo", "role": "member"}); code != http.StatusForbidden {
		t.Fatalf("non-manager add org member = %d", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/orgs/"+org.ID+"/members", ownerTok,
		map[string]string{"identity": "teammate@demo", "role": "owner"}); code != http.StatusOK {
		t.Fatalf("owner add org member = %d", code)
	}

	code, body = postJSON(t, srv.URL+"/v1/projects", teamTok,
		map[string]string{"name": "Team Project", "org_id": org.ID})
	if code != http.StatusCreated {
		t.Fatalf("org admin create project = %d %s", code, body)
	}
	var proj store.Project
	_ = json.Unmarshal(body, &proj)
	if proj.OrgID != org.ID || proj.OwnerIdentity != "teammate@demo" {
		t.Fatalf("project = %+v", proj)
	}

	if code, _ := deleteAuthed(t, srv.URL+"/v1/orgs/"+org.ID+"/members/owner@demo", ownerTok); code != http.StatusOK {
		t.Fatalf("remove owner with another owner/admin present = %d", code)
	}
}

func mkUser(t *testing.T, st *store.Store, identity, pw string) {
	t.Helper()
	hash, err := auth.HashPassword(pw)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.CreateUser(context.Background(), store.User{Identity: identity, PasswordHash: hash}, time.Now()); err != nil {
		t.Fatal(err)
	}
}

func loginToken(t *testing.T, base, identity, pw string) string {
	t.Helper()
	code, body := postJSON(t, base+"/v1/login", "", map[string]string{"identity": identity, "password": pw})
	if code != http.StatusOK {
		t.Fatalf("login %s: status=%d", identity, code)
	}
	var lr struct {
		Token string `json:"token"`
	}
	_ = json.Unmarshal(body, &lr)
	if lr.Token == "" {
		t.Fatalf("no token for %s", identity)
	}
	return lr.Token
}
