package relay_test

import (
	"context"
	"encoding/json"
	"errors"
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
	qaTok := loginToken(t, srv.URL, "qa@backend", "qapass1234")

	// Admin gate: non-admin 403, admin 200.
	if code, _ := getAuthed(t, srv.URL+"/v1/users", devTok); code != http.StatusForbidden {
		t.Fatalf("non-admin /v1/users = %d", code)
	}
	if code, _ := getAuthed(t, srv.URL+"/v1/users", aliceTok); code != http.StatusOK {
		t.Fatalf("admin /v1/users = %d", code)
	}

	// Self-service: dev creates a team, then a project inside that team.
	code, body := postJSON(t, srv.URL+"/v1/orgs", devTok, map[string]string{"name": "Dev Team"})
	if code != http.StatusCreated {
		t.Fatalf("create org = %d %s", code, body)
	}
	var devOrg store.Organization
	_ = json.Unmarshal(body, &devOrg)
	if code, body := postJSON(t, srv.URL+"/v1/projects", devTok,
		map[string]string{"name": "No Team"}); code != http.StatusBadRequest {
		t.Fatalf("create project without org_id = %d %s", code, body)
	}
	code, body = postJSON(t, srv.URL+"/v1/projects", devTok,
		map[string]string{"name": "Kunlun", "org_id": devOrg.ID})
	if code != http.StatusCreated {
		t.Fatalf("create project = %d %s", code, body)
	}
	var proj struct {
		ID    string `json:"id"`
		OrgID string `json:"org_id"`
		Role  string `json:"role"`
	}
	_ = json.Unmarshal(body, &proj)
	if proj.ID == "" || proj.OrgID == "" || proj.Role != "owner" {
		t.Fatalf("created project response = %+v", proj)
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
	assertOrganizationListRole(t, srv.URL, devTok, proj.OrgID, "owner")
	assertOrganizationListRole(t, srv.URL, aliceTok, proj.OrgID, "admin")

	// Owner maps a repo + adds a member.
	if code, body := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/repos", devTok,
		map[string]string{
			"repo_name": "kunlun-backend",
			"clone_url": "https://github.com/kunlun/kunlun-backend",
		}); code != http.StatusOK {
		t.Fatalf("map repo = %d %s", code, body)
	}
	// Simulate a pre-clone_url row. It must remain visible in both the legacy
	// names array and the new bindings array without becoming cloneable.
	if err := st.MapRepo(context.Background(), "legacy-name-only", proj.ID); err != nil {
		t.Fatal(err)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/repos", devTok,
		map[string]string{"repo_name": "missing-url"}); code != http.StatusBadRequest {
		t.Fatalf("map repo without clone_url = %d, want 400", code)
	}
	for _, cloneURL := range []string{
		"file:///tmp/private",
		"https://token@github.com/kunlun/private.git",
		"https://github.com/kunlun/private.git?token=secret",
		"ssh://git:password@github.com/kunlun/private.git",
	} {
		if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/repos", devTok,
			map[string]string{"repo_name": "unsafe", "clone_url": cloneURL}); code != http.StatusBadRequest {
			t.Fatalf("map unsafe repo URL %q = %d, want 400", cloneURL, code)
		}
	}
	if _, ok, err := st.RepoProjectID(context.Background(), "unsafe"); err != nil || ok {
		t.Fatalf("unsafe credential URL was persisted: ok=%v err=%v", ok, err)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", devTok,
		map[string]string{"identity": "ghost@backend", "role": "viewer"}); code != http.StatusNotFound {
		t.Fatalf("add missing member = %d", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", devTok,
		map[string]string{"identity": "qa@backend", "role": "viewer"}); code != http.StatusOK {
		t.Fatalf("add member = %d", code)
	}
	if code, body := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", devTok,
		map[string]string{"identity": "z@y", "role": " member "}); code != http.StatusOK {
		t.Fatalf("add member with padded role = %d %s", code, body)
	}
	if role, ok, err := st.MemberRole(context.Background(), proj.ID, "z@y"); err != nil || !ok || role != store.RoleMember {
		t.Fatalf("padded project member role = role:%q ok:%v err:%v", role, ok, err)
	}
	code, body = postJSON(t, srv.URL+"/v1/orgs", malTok, map[string]string{"name": "Mallory Team"})
	if code != http.StatusCreated {
		t.Fatalf("mallory create org = %d %s", code, body)
	}
	var malloryOrg store.Organization
	_ = json.Unmarshal(body, &malloryOrg)
	code, body = postJSON(t, srv.URL+"/v1/projects", malTok,
		map[string]string{"name": "Mallory Project", "org_id": malloryOrg.ID})
	if code != http.StatusCreated {
		t.Fatalf("mallory create project = %d %s", code, body)
	}
	var otherProj struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(body, &otherProj)
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+otherProj.ID+"/repos", malTok,
		map[string]string{
			"repo_name": "mallory-repo",
			"clone_url": "git@github.com:mallory/mallory-repo.git",
		}); code != http.StatusOK {
		t.Fatalf("mallory map repo = %d", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/repos", devTok,
		map[string]string{
			"repo_name": "mallory-repo",
			"clone_url": "https://github.com/mallory/mallory-repo.git",
		}); code != http.StatusForbidden {
		t.Fatalf("owner remap other project repo = %d, want 403", code)
	}
	if code, _ := deleteAuthed(t, srv.URL+"/v1/projects/"+proj.ID+"/repos?repo_name=mallory-repo", devTok); code != http.StatusNotFound {
		t.Fatalf("owner unmap other project repo = %d, want 404", code)
	}
	code, body = getAuthed(t, srv.URL+"/v1/projects/"+otherProj.ID, malTok)
	if code != http.StatusOK {
		t.Fatalf("mallory get project = %d %s", code, body)
	}
	var otherDetail struct {
		Repos []string `json:"repos"`
	}
	_ = json.Unmarshal(body, &otherDetail)
	if len(otherDetail.Repos) != 1 || otherDetail.Repos[0] != "mallory-repo" {
		t.Fatalf("cross-project unmap removed repo: %+v", otherDetail.Repos)
	}

	assertProjectListRole(t, srv.URL, devTok, proj.ID, "owner")
	assertProjectListRole(t, srv.URL, qaTok, proj.ID, "viewer")
	assertProjectListRole(t, srv.URL, aliceTok, proj.ID, "admin")
	assertProjectDetailRole(t, srv.URL, devTok, proj.ID, "owner")
	assertProjectDetailRole(t, srv.URL, qaTok, proj.ID, "viewer")
	assertProjectDetailRole(t, srv.URL, aliceTok, proj.ID, "admin")

	// A non-owner, non-member, non-admin can neither manage nor view the project.
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", malTok,
		map[string]string{"identity": "x@y", "role": "member"}); code != http.StatusForbidden {
		t.Fatalf("non-owner manage = %d (want 403)", code)
	}
	if code, _ := getAuthed(t, srv.URL+"/v1/projects/"+proj.ID, malTok); code != http.StatusForbidden {
		t.Fatalf("non-member GET = %d (want 403)", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/repos", qaTok,
		map[string]string{
			"repo_name": "viewer-write",
			"clone_url": "https://github.com/kunlun/viewer-write.git",
		}); code != http.StatusForbidden {
		t.Fatalf("viewer map repo = %d (want 403)", code)
	}

	// Admin can manage any project.
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", aliceTok,
		map[string]string{"identity": "z@y", "role": "member"}); code != http.StatusOK {
		t.Fatalf("admin manage = %d", code)
	}
	code, body = postJSON(t, srv.URL+"/v1/projects", aliceTok,
		map[string]string{"name": "Admin Project", "org_id": proj.OrgID})
	if code != http.StatusCreated {
		t.Fatalf("admin create org project = %d %s", code, body)
	}
	var adminProj struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(body, &adminProj)

	// /v1/me reflects direct ownership and team-manager project access.
	_, meBody := getAuthed(t, srv.URL+"/v1/me", devTok)
	var me struct {
		Projects []struct {
			ID   string `json:"id"`
			Role string `json:"role"`
		} `json:"projects"`
	}
	_ = json.Unmarshal(meBody, &me)
	meRoles := map[string]string{}
	for _, p := range me.Projects {
		meRoles[p.ID] = p.Role
	}
	if meRoles[proj.ID] != "owner" || meRoles[adminProj.ID] != "admin" {
		t.Fatalf("me.projects = %+v", me.Projects)
	}

	// A member can GET the project detail (repos + members).
	if code, _ := getAuthed(t, srv.URL+"/v1/projects/"+proj.ID, devTok); code != http.StatusOK {
		t.Fatalf("owner GET project = %d", code)
	}
	code, body = getAuthed(t, srv.URL+"/v1/projects/"+proj.ID, qaTok)
	if code != http.StatusOK {
		t.Fatalf("viewer GET project repos = %d %s", code, body)
	}
	var repoDetail struct {
		Repos        []string            `json:"repos"`
		RepoBindings []store.ProjectRepo `json:"repo_bindings"`
	}
	if err := json.Unmarshal(body, &repoDetail); err != nil {
		t.Fatal(err)
	}
	if len(repoDetail.Repos) != 2 || repoDetail.Repos[0] != "kunlun-backend" || repoDetail.Repos[1] != "legacy-name-only" {
		t.Fatalf("legacy repos response = %+v", repoDetail.Repos)
	}
	if len(repoDetail.RepoBindings) != 2 ||
		repoDetail.RepoBindings[0].CloneURL != "https://github.com/kunlun/kunlun-backend.git" ||
		repoDetail.RepoBindings[1].RepoName != "legacy-name-only" ||
		repoDetail.RepoBindings[1].CloneURL != "" {
		t.Fatalf("viewer repo bindings = %+v", repoDetail.RepoBindings)
	}
}

func TestProjectNamesAreTrimmed(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	mkUser(t, st, "owner@demo", "ownerpass1")

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
	}).Handler())
	t.Cleanup(srv.Close)

	ownerTok := loginToken(t, srv.URL, "owner@demo", "ownerpass1")

	org := createOrganizationHTTP(t, srv.URL, ownerTok, "Owner Team")
	proj := createProjectInOrgHTTP(t, srv.URL, ownerTok, "  Trimmed Project  ", org.ID)
	if proj.Name != "Trimmed Project" {
		t.Fatalf("created project name = %q, want trimmed", proj.Name)
	}

	code, body := patchJSON(t, srv.URL+"/v1/projects/"+proj.ID, ownerTok,
		map[string]string{"name": "  Renamed Project  "})
	if code != http.StatusOK {
		t.Fatalf("rename project = %d %s", code, body)
	}

	code, body = getAuthed(t, srv.URL+"/v1/projects/"+proj.ID, ownerTok)
	if code != http.StatusOK {
		t.Fatalf("get project = %d %s", code, body)
	}
	var detail struct {
		Project store.Project `json:"project"`
	}
	if err := json.Unmarshal(body, &detail); err != nil {
		t.Fatal(err)
	}
	if detail.Project.Name != "Renamed Project" {
		t.Fatalf("renamed project name = %q, want trimmed", detail.Project.Name)
	}
}

func assertProjectListRole(t *testing.T, base, token, projectID, wantRole string) {
	t.Helper()
	code, body := getAuthed(t, base+"/v1/projects", token)
	if code != http.StatusOK {
		t.Fatalf("list projects = %d %s", code, body)
	}
	var resp struct {
		Projects []struct {
			ID   string `json:"id"`
			Role string `json:"role"`
		} `json:"projects"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("decode projects: %v", err)
	}
	for _, p := range resp.Projects {
		if p.ID == projectID {
			if p.Role != wantRole {
				t.Fatalf("project %s role = %q, want %q; projects=%+v", projectID, p.Role, wantRole, resp.Projects)
			}
			return
		}
	}
	t.Fatalf("project %s not found in list: %+v", projectID, resp.Projects)
}

func assertProjectDetailRole(t *testing.T, base, token, projectID, wantRole string) {
	t.Helper()
	code, body := getAuthed(t, base+"/v1/projects/"+projectID, token)
	if code != http.StatusOK {
		t.Fatalf("get project detail = %d %s", code, body)
	}
	var resp struct {
		Project struct {
			Role string `json:"role"`
		} `json:"project"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("decode project detail: %v", err)
	}
	if resp.Project.Role != wantRole {
		t.Fatalf("project detail role = %q, want %q", resp.Project.Role, wantRole)
	}
}

func assertOrganizationListRole(t *testing.T, base, token, orgID, wantRole string) {
	t.Helper()
	code, body := getAuthed(t, base+"/v1/orgs", token)
	if code != http.StatusOK {
		t.Fatalf("list organizations = %d %s", code, body)
	}
	var resp struct {
		Organizations []struct {
			ID   string `json:"id"`
			Role string `json:"role"`
		} `json:"organizations"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("decode organizations: %v", err)
	}
	for _, org := range resp.Organizations {
		if org.ID == orgID {
			if org.Role != wantRole {
				t.Fatalf("organization %s role = %q, want %q; organizations=%+v", orgID, org.Role, wantRole, resp.Organizations)
			}
			return
		}
	}
	t.Fatalf("organization %s not found in list: %+v", orgID, resp.Organizations)
}

func createOrganizationHTTP(t *testing.T, base, token, name string) store.Organization {
	t.Helper()
	code, body := postJSON(t, base+"/v1/orgs", token, map[string]string{"name": name})
	if code != http.StatusCreated {
		t.Fatalf("create organization %q = %d %s", name, code, body)
	}
	var org store.Organization
	if err := json.Unmarshal(body, &org); err != nil {
		t.Fatalf("decode organization %q: %v", name, err)
	}
	return org
}

func createProjectInOrgHTTP(t *testing.T, base, token, name, orgID string) store.Project {
	t.Helper()
	code, body := postJSON(t, base+"/v1/projects", token, map[string]string{"name": name, "org_id": orgID})
	if code != http.StatusCreated {
		t.Fatalf("create project %q = %d %s", name, code, body)
	}
	var project store.Project
	if err := json.Unmarshal(body, &project); err != nil {
		t.Fatalf("decode project %q: %v", name, err)
	}
	return project
}

func createProjectHTTP(t *testing.T, base, token, name string) store.Project {
	t.Helper()
	org := createOrganizationHTTP(t, base, token, name+" Team")
	return createProjectInOrgHTTP(t, base, token, name, org.ID)
}

func TestOrganizationSaaSFlow(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	mkUser(t, st, "owner@demo", "ownerpass1")
	mkUser(t, st, "teammate@demo", "teampass1")
	if err := st.CreateUser(context.Background(), store.User{Identity: "disabled@demo", Disabled: true}, time.Now()); err != nil {
		t.Fatal(err)
	}

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
	if org.ID == "" || org.OwnerIdentity != "owner@demo" || org.Role != "owner" {
		t.Fatalf("org = %+v", org)
	}

	if code, _ := postJSON(t, srv.URL+"/v1/orgs/"+org.ID+"/members", teamTok,
		map[string]string{"identity": "owner@demo", "role": "member"}); code != http.StatusForbidden {
		t.Fatalf("non-manager add org member = %d", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/orgs/"+org.ID+"/members", ownerTok,
		map[string]string{"identity": "disabled@demo", "role": "member"}); code != http.StatusBadRequest {
		t.Fatalf("owner add disabled org member = %d", code)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/orgs/"+org.ID+"/members", ownerTok,
		map[string]string{"identity": "teammate@demo", "role": "owner"}); code != http.StatusOK {
		t.Fatalf("owner add org member = %d", code)
	}
	assertOrganizationListRole(t, srv.URL, ownerTok, org.ID, "owner")
	assertOrganizationListRole(t, srv.URL, teamTok, org.ID, "owner")
	code, body = getAuthed(t, srv.URL+"/v1/orgs/"+org.ID, teamTok)
	if code != http.StatusOK {
		t.Fatalf("get org detail = %d %s", code, body)
	}
	var orgDetail struct {
		Organization store.Organization `json:"organization"`
	}
	_ = json.Unmarshal(body, &orgDetail)
	if orgDetail.Organization.Role != "owner" {
		t.Fatalf("org detail role = %+v", orgDetail.Organization)
	}

	code, body = postJSON(t, srv.URL+"/v1/projects", teamTok,
		map[string]string{"name": "Team Project", "org_id": org.ID})
	if code != http.StatusCreated {
		t.Fatalf("org admin create project = %d %s", code, body)
	}
	var proj store.Project
	_ = json.Unmarshal(body, &proj)
	if proj.OrgID != org.ID || proj.OwnerIdentity != "teammate@demo" || proj.Role != "owner" {
		t.Fatalf("project = %+v", proj)
	}
	assertProjectListRole(t, srv.URL, ownerTok, proj.ID, "admin")
	assertProjectDetailRole(t, srv.URL, ownerTok, proj.ID, "admin")
	_, body = getAuthed(t, srv.URL+"/v1/me", ownerTok)
	var ownerMe struct {
		Projects []struct {
			ID   string `json:"id"`
			Role string `json:"role"`
		} `json:"projects"`
	}
	_ = json.Unmarshal(body, &ownerMe)
	if len(ownerMe.Projects) != 1 || ownerMe.Projects[0].ID != proj.ID || ownerMe.Projects[0].Role != "admin" {
		t.Fatalf("org owner me.projects = %+v", ownerMe.Projects)
	}
	if code, body := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/repos", ownerTok,
		map[string]string{
			"repo_name": "team/repo",
			"clone_url": "https://github.com/team/repo.git",
		}); code != http.StatusOK {
		t.Fatalf("org owner map repo on team project = %d %s", code, body)
	}
	if code, body := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", ownerTok,
		map[string]string{"identity": "owner@demo", "role": "member"}); code != http.StatusOK {
		t.Fatalf("org owner add project member = %d %s", code, body)
	}
	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", ownerTok,
		map[string]string{"identity": "disabled@demo", "role": "member"}); code != http.StatusBadRequest {
		t.Fatalf("org owner add disabled project member = %d", code)
	}

	if code, _ := deleteAuthed(t, srv.URL+"/v1/orgs/"+org.ID+"/members/owner@demo", ownerTok); code != http.StatusOK {
		t.Fatalf("remove owner with another owner/admin present = %d", code)
	}
	if code, body := deleteAuthed(t, srv.URL+"/v1/orgs/"+org.ID, teamTok); code != http.StatusOK {
		t.Fatalf("delete org = %d %s", code, body)
	}
	if _, err := st.GetOrganization(context.Background(), org.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("deleted org: want ErrNotFound, got %v", err)
	}
	if _, err := st.GetProject(context.Background(), proj.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("project in deleted org: want ErrNotFound, got %v", err)
	}
}

func TestTeamAndProjectMembersRejectTrailingJSON(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	for _, id := range []string{"owner@demo", "team@demo", "project@demo"} {
		mkUser(t, st, id, "pw-"+id+"-12345")
	}

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
	}).Handler())
	t.Cleanup(srv.Close)

	ownerTok := loginToken(t, srv.URL, "owner@demo", "pw-owner@demo-12345")
	code, body := postJSON(t, srv.URL+"/v1/orgs", ownerTok, map[string]string{"name": "Acme"})
	if code != http.StatusCreated {
		t.Fatalf("create org = %d %s", code, body)
	}
	var org store.Organization
	if err := json.Unmarshal(body, &org); err != nil {
		t.Fatal(err)
	}

	if code, body := postRawJSON(t, srv.URL+"/v1/orgs/"+org.ID+"/members", ownerTok,
		`{"identity":"team@demo","role":"member"} {"identity":"project@demo","role":"owner"}`); code != http.StatusBadRequest {
		t.Fatalf("add org member trailing json = %d %s", code, body)
	}
	if role, found, err := st.OrganizationMemberRole(context.Background(), org.ID, "team@demo"); err != nil || found {
		t.Fatalf("trailing org member request added member: role=%q found=%v err=%v", role, found, err)
	}

	code, body = postJSON(t, srv.URL+"/v1/projects", ownerTok, map[string]string{"name": "Scoped", "org_id": org.ID})
	if code != http.StatusCreated {
		t.Fatalf("create project = %d %s", code, body)
	}
	var proj store.Project
	if err := json.Unmarshal(body, &proj); err != nil {
		t.Fatal(err)
	}
	if code, body := postRawJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", ownerTok,
		`{"identity":"project@demo","role":"viewer"} {"identity":"team@demo","role":"member"}`); code != http.StatusBadRequest {
		t.Fatalf("add project member trailing json = %d %s", code, body)
	}
	if role, found, err := st.MemberRole(context.Background(), proj.ID, "project@demo"); err != nil || found {
		t.Fatalf("trailing project member request added member: role=%q found=%v err=%v", role, found, err)
	}
}

func TestProjectOwnerCannotInviteOutsideTeamAfterOrgDemotion(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	for _, id := range []string{"owner@demo", "coowner@demo", "outsider@demo"} {
		mkUser(t, st, id, "pw-"+id+"-12345")
	}

	srv := httptest.NewServer((&relay.Server{
		Store: st, Tokens: auth.NewTokens(), Hub: sse.NewHub(),
	}).Handler())
	t.Cleanup(srv.Close)

	ownerTok := loginToken(t, srv.URL, "owner@demo", "pw-owner@demo-12345")
	coownerTok := loginToken(t, srv.URL, "coowner@demo", "pw-coowner@demo-12345")

	proj := createProjectHTTP(t, srv.URL, ownerTok, "Scoped Project")

	if code, body := postJSON(t, srv.URL+"/v1/orgs/"+proj.OrgID+"/members", ownerTok,
		map[string]string{"identity": "coowner@demo", "role": "owner"}); code != http.StatusOK {
		t.Fatalf("add coowner = %d %s", code, body)
	}
	if code, body := postJSON(t, srv.URL+"/v1/orgs/"+proj.OrgID+"/members", coownerTok,
		map[string]string{"identity": "owner@demo", "role": "member"}); code != http.StatusOK {
		t.Fatalf("demote owner in org = %d %s", code, body)
	}

	if code, _ := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", ownerTok,
		map[string]string{"identity": "outsider@demo", "role": "viewer"}); code != http.StatusForbidden {
		t.Fatalf("demoted project owner invited outside-team user = %d, want 403", code)
	}

	if code, body := postJSON(t, srv.URL+"/v1/orgs/"+proj.OrgID+"/members", coownerTok,
		map[string]string{"identity": "outsider@demo", "role": "member"}); code != http.StatusOK {
		t.Fatalf("org manager adds outsider to team = %d %s", code, body)
	}
	if code, body := postJSON(t, srv.URL+"/v1/projects/"+proj.ID+"/members", ownerTok,
		map[string]string{"identity": "outsider@demo", "role": "viewer"}); code != http.StatusOK {
		t.Fatalf("project owner adds existing team member = %d %s", code, body)
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
