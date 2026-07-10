package relay_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
)

func TestInvitationFlowForRegisteredAccount(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	mkUser(t, st, "owner@x", "ownerpass1")

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
	}).Handler())
	t.Cleanup(srv.Close)

	ownerTok := loginToken(t, srv.URL, "owner@x", "ownerpass1")
	var ownerMe struct {
		Organizations []struct {
			ID string `json:"id"`
		} `json:"organizations"`
	}
	if code, body := getAuthed(t, srv.URL+"/v1/me", ownerTok); code != http.StatusOK {
		t.Fatalf("owner me = %d %s", code, body)
	} else if err := json.Unmarshal(body, &ownerMe); err != nil {
		t.Fatal(err)
	}
	if len(ownerMe.Organizations) != 1 {
		t.Fatalf("owner organizations = %+v", ownerMe.Organizations)
	}
	orgID := ownerMe.Organizations[0].ID

	code, body := postJSON(t, srv.URL+"/v1/orgs/"+orgID+"/invitations", ownerTok,
		map[string]string{"identity": "new@x", "role": "member"})
	if code != http.StatusCreated {
		t.Fatalf("create org invitation = %d %s", code, body)
	}
	newTok := registerToken(t, srv.URL, "new@x", "newpass123")
	var newMe struct {
		Invitations []struct {
			ID    string `json:"id"`
			OrgID string `json:"org_id"`
			Scope string `json:"scope"`
		} `json:"invitations"`
	}
	if code, body := getAuthed(t, srv.URL+"/v1/me", newTok); code != http.StatusOK {
		t.Fatalf("new me = %d %s", code, body)
	} else if err := json.Unmarshal(body, &newMe); err != nil {
		t.Fatal(err)
	}
	if len(newMe.Invitations) != 1 || newMe.Invitations[0].OrgID != orgID || newMe.Invitations[0].Scope != "org" {
		t.Fatalf("new invitations = %+v", newMe.Invitations)
	}
	if code, body := postJSON(t, srv.URL+"/v1/invitations/"+newMe.Invitations[0].ID+"/accept", newTok, nil); code != http.StatusOK {
		t.Fatalf("accept org invitation = %d %s", code, body)
	}
	if code, body := getAuthed(t, srv.URL+"/v1/orgs/"+orgID, newTok); code != http.StatusOK {
		t.Fatalf("new get accepted org = %d %s", code, body)
	}
}

func TestProjectInvitationAcceptsIntoProjectAndTeam(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	mkUser(t, st, "owner@x", "ownerpass1")

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
	}).Handler())
	t.Cleanup(srv.Close)

	ownerTok := loginToken(t, srv.URL, "owner@x", "ownerpass1")
	code, body := postJSON(t, srv.URL+"/v1/projects", ownerTok, map[string]string{"name": "Backend"})
	if code != http.StatusCreated {
		t.Fatalf("create project = %d %s", code, body)
	}
	var project struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &project); err != nil {
		t.Fatal(err)
	}
	code, body = postJSON(t, srv.URL+"/v1/projects/"+project.ID+"/invitations", ownerTok,
		map[string]string{"identity": "project-new@x", "role": "member"})
	if code != http.StatusCreated {
		t.Fatalf("create project invitation = %d %s", code, body)
	}
	projectTok := registerToken(t, srv.URL, "project-new@x", "newpass123")
	var me struct {
		Invitations []struct {
			ID        string `json:"id"`
			ProjectID string `json:"project_id"`
			Scope     string `json:"scope"`
		} `json:"invitations"`
	}
	if code, body := getAuthed(t, srv.URL+"/v1/me", projectTok); code != http.StatusOK {
		t.Fatalf("project invitee me = %d %s", code, body)
	} else if err := json.Unmarshal(body, &me); err != nil {
		t.Fatal(err)
	}
	if len(me.Invitations) != 1 || me.Invitations[0].ProjectID != project.ID || me.Invitations[0].Scope != "project" {
		t.Fatalf("project invitee invitations = %+v", me.Invitations)
	}
	if code, body := postJSON(t, srv.URL+"/v1/invitations/"+me.Invitations[0].ID+"/accept", projectTok, nil); code != http.StatusOK {
		t.Fatalf("accept project invitation = %d %s", code, body)
	}
	if code, body := getAuthed(t, srv.URL+"/v1/projects/"+project.ID, projectTok); code != http.StatusOK {
		t.Fatalf("invitee get accepted project = %d %s", code, body)
	}
}

func registerToken(t *testing.T, base, identity, pw string) string {
	t.Helper()
	code, body := postJSON(t, base+"/v1/register", "", map[string]string{"identity": identity, "password": pw})
	if code != http.StatusCreated {
		t.Fatalf("register %s: status=%d body=%s", identity, code, body)
	}
	var lr struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(body, &lr); err != nil {
		t.Fatal(err)
	}
	if lr.Token == "" {
		t.Fatalf("no token for %s", identity)
	}
	return lr.Token
}
