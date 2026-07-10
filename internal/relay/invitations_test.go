package relay_test

import (
	"context"
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
	code, body := postJSON(t, srv.URL+"/v1/orgs", ownerTok, map[string]string{"name": "Owner Team"})
	if code != http.StatusCreated {
		t.Fatalf("create org = %d %s", code, body)
	}
	var org store.Organization
	if err := json.Unmarshal(body, &org); err != nil {
		t.Fatal(err)
	}
	orgID := org.ID

	code, body = postJSON(t, srv.URL+"/v1/orgs/"+orgID+"/invitations", ownerTok,
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
	mkUser(t, st, "lead@x", "leadpass1")

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
	}).Handler())
	t.Cleanup(srv.Close)

	ownerTok := loginToken(t, srv.URL, "owner@x", "ownerpass1")
	leadTok := loginToken(t, srv.URL, "lead@x", "leadpass1")
	code, body := postJSON(t, srv.URL+"/v1/orgs", ownerTok, map[string]string{"name": "Owner Team"})
	if code != http.StatusCreated {
		t.Fatalf("create org = %d %s", code, body)
	}
	var org store.Organization
	if err := json.Unmarshal(body, &org); err != nil {
		t.Fatal(err)
	}
	code, body = postJSON(t, srv.URL+"/v1/projects", ownerTok,
		map[string]string{"name": "Backend", "org_id": org.ID})
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

	if code, body := postJSON(t, srv.URL+"/v1/orgs/"+org.ID+"/members", ownerTok,
		map[string]string{"identity": "lead@x", "role": "member"}); code != http.StatusOK {
		t.Fatalf("add project lead to org = %d %s", code, body)
	}
	if code, body := postJSON(t, srv.URL+"/v1/projects/"+project.ID+"/members", ownerTok,
		map[string]string{"identity": "lead@x", "role": "owner"}); code != http.StatusOK {
		t.Fatalf("make lead project owner = %d %s", code, body)
	}
	code, body = postJSON(t, srv.URL+"/v1/projects/"+project.ID+"/invitations", leadTok,
		map[string]string{"identity": "lead-invitee@x", "role": "viewer"})
	if code != http.StatusCreated {
		t.Fatalf("project owner create outside-team invitation = %d %s", code, body)
	}
	leadInviteeTok := registerToken(t, srv.URL, "lead-invitee@x", "invitepass123")
	var leadInviteeMe struct {
		Invitations []struct {
			ID string `json:"id"`
		} `json:"invitations"`
	}
	if code, body := getAuthed(t, srv.URL+"/v1/me", leadInviteeTok); code != http.StatusOK {
		t.Fatalf("lead invitee me = %d %s", code, body)
	} else if err := json.Unmarshal(body, &leadInviteeMe); err != nil {
		t.Fatal(err)
	}
	if len(leadInviteeMe.Invitations) != 1 {
		t.Fatalf("lead invitee invitations = %+v", leadInviteeMe.Invitations)
	}
	if code, body := postJSON(t, srv.URL+"/v1/invitations/"+leadInviteeMe.Invitations[0].ID+"/accept", leadInviteeTok, nil); code != http.StatusOK {
		t.Fatalf("accept lead project invitation = %d %s", code, body)
	}
	if role, ok, err := st.OrganizationMemberRole(context.Background(), org.ID, "lead-invitee@x"); err != nil || !ok || role != store.OrgRoleMember {
		t.Fatalf("lead invitee team role = %q ok=%v err=%v", role, ok, err)
	}
	if role, ok, err := st.MemberRole(context.Background(), project.ID, "lead-invitee@x"); err != nil || !ok || role != store.RoleViewer {
		t.Fatalf("lead invitee project role = %q ok=%v err=%v", role, ok, err)
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
