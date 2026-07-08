package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestProjectsAndMembers(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateProject(ctx, "p1", "Kunlun", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	// The owner is seated as a member with role=owner.
	if role, ok, _ := st.MemberRole(ctx, "p1", "owner@x"); !ok || role != RoleOwner {
		t.Fatalf("owner not seated: role=%q ok=%v", role, ok)
	}

	if err := st.MapRepo(ctx, "kunlun-backend", "p1"); err != nil {
		t.Fatal(err)
	}
	if err := st.MapRepo(ctx, "kunlun-frontend", "p1"); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "p1", "dev@x", RoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "p1", "qa@x", RoleViewer); err != nil {
		t.Fatal(err)
	}

	// AddMember upserts the role.
	if err := st.AddMember(ctx, "p1", "dev@x", RoleViewer); err != nil {
		t.Fatal(err)
	}
	if role, _, _ := st.MemberRole(ctx, "p1", "dev@x"); role != RoleViewer {
		t.Fatalf("role not updated on re-add: %q", role)
	}

	// Visibility: a member sees the project's repos with their role.
	if repos, _ := st.VisibleRepoNames(ctx, "qa@x"); len(repos) != 2 {
		t.Fatalf("visible repos = %v", repos)
	}
	if role, ok, _ := st.RepoVisibleTo(ctx, "kunlun-backend", "qa@x"); !ok || role != RoleViewer {
		t.Fatalf("repo-visible-to: role=%q ok=%v", role, ok)
	}
	if _, ok, _ := st.RepoVisibleTo(ctx, "kunlun-backend", "stranger@x"); ok {
		t.Error("stranger should not see the repo")
	}
	if _, ok, _ := st.RepoVisibleTo(ctx, "unmapped-repo", "owner@x"); ok {
		t.Error("unmapped repo should not be visible")
	}
	if err := st.CreateProject(ctx, "p2", "Other", "other@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.MapRepo(ctx, "other-repo", "p2"); err != nil {
		t.Fatal(err)
	}
	if err := st.UnmapRepo(ctx, "other-repo", "p1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("wrong-project unmap: want ErrNotFound, got %v", err)
	}
	if repos, _ := st.ListProjectRepos(ctx, "p2"); len(repos) != 1 || repos[0] != "other-repo" {
		t.Fatalf("wrong-project unmap removed repo: %v", repos)
	}
	if err := st.UnmapRepo(ctx, "other-repo", "p2"); err != nil {
		t.Fatalf("own-project unmap: %v", err)
	}

	// MemberProjects (for /v1/me).
	if prs, _ := st.MemberProjects(ctx, "dev@x"); len(prs) != 1 || prs[0].ID != "p1" || prs[0].Role != RoleViewer {
		t.Fatalf("member projects = %+v", prs)
	}
	p1, err := st.GetProject(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, p1.OrgID, "org-admin@x", OrgRoleAdmin); err != nil {
		t.Fatal(err)
	}
	if prs, _ := st.MemberProjects(ctx, "org-admin@x"); len(prs) != 1 || prs[0].ID != "p1" || prs[0].Role != RoleAdmin {
		t.Fatalf("org admin member projects = %+v", prs)
	}

	// List scope: all vs per-identity.
	if all, _ := st.ListProjects(ctx); len(all) != 2 {
		t.Fatalf("all projects = %d", len(all))
	}
	if mine, _ := st.ListProjectsForIdentity(ctx, "dev@x"); len(mine) != 1 {
		t.Fatalf("dev projects = %d", len(mine))
	}
	if none, _ := st.ListProjectsForIdentity(ctx, "stranger@x"); len(none) != 0 {
		t.Fatalf("stranger projects = %d", len(none))
	}

	if err := st.RemoveMember(ctx, "p1", "qa@x"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := st.MemberRole(ctx, "p1", "qa@x"); ok {
		t.Error("removed member still present")
	}

	// Deleting a project cascades its repos + members (foreign_keys=on).
	if err := st.DeleteProject(ctx, "p1"); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetProject(ctx, "p1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("project not deleted: %v", err)
	}
	if repos, _ := st.ListProjectRepos(ctx, "p1"); len(repos) != 0 {
		t.Fatalf("repos not cascaded: %v", repos)
	}
	if mem, _ := st.ListMembers(ctx, "p1"); len(mem) != 0 {
		t.Fatalf("members not cascaded: %v", mem)
	}
}

func TestListMembersHidesDisabledUsers(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateProject(ctx, "p1", "Kunlun", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateUser(ctx, User{Identity: "active@x"}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateUser(ctx, User{Identity: "disabled@x", Disabled: true}, now); err != nil {
		t.Fatal(err)
	}
	for _, identity := range []string{"active@x", "legacy@x"} {
		if err := st.AddMember(ctx, "p1", identity, RoleMember); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.CreateUser(ctx, User{Identity: "will-disable@x"}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "p1", "will-disable@x", RoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.SetDisabled(ctx, "will-disable@x", true); err != nil {
		t.Fatal(err)
	}

	members, err := st.ListMembers(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, m := range members {
		got[m.Identity] = true
	}
	for _, want := range []string{"owner@x", "active@x", "legacy@x"} {
		if !got[want] {
			t.Fatalf("project member %q missing from %+v", want, members)
		}
	}
	if got["disabled@x"] || got["will-disable@x"] {
		t.Fatalf("disabled project member leaked into list: %+v", members)
	}
}

func TestProjectWriteRejectsDisabledUsers(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateUser(ctx, User{Identity: "disabled@x", Disabled: true}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateProject(ctx, "disabled-project", "Blocked", "disabled@x", now); !errors.Is(err, ErrForbidden) {
		t.Fatalf("disabled owner create project: want ErrForbidden, got %v", err)
	}
	if err := st.CreateOrganization(ctx, "org1", "Acme", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateProjectInOrg(ctx, "p-disabled", "org1", "Blocked", "disabled@x", now); !errors.Is(err, ErrForbidden) {
		t.Fatalf("disabled owner create project in org: want ErrForbidden, got %v", err)
	}
	if err := st.CreateProjectInOrg(ctx, "p1", "org1", "App", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "p1", "disabled@x", RoleMember); !errors.Is(err, ErrForbidden) {
		t.Fatalf("add disabled project member: want ErrForbidden, got %v", err)
	}
	if err := st.AddMember(ctx, "p1", "legacy@x", RoleMember); err != nil {
		t.Fatalf("legacy project member should remain allowed: %v", err)
	}
}

func TestDisabledUsersHaveNoEffectiveTeamAccess(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateProject(ctx, "p1", "Kunlun", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	p, err := st.GetProject(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MapRepo(ctx, "kunlun-backend", "p1"); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateUser(ctx, User{Identity: "disabled@x"}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, p.OrgID, "disabled@x", OrgRoleAdmin); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "p1", "disabled@x", RoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.SetDisabled(ctx, "disabled@x", true); err != nil {
		t.Fatal(err)
	}

	if orgs, err := st.MemberOrganizations(ctx, "disabled@x"); err != nil || len(orgs) != 0 {
		t.Fatalf("disabled member organizations = %+v err=%v", orgs, err)
	}
	if orgs, err := st.ListOrganizationsForIdentity(ctx, "disabled@x"); err != nil || len(orgs) != 0 {
		t.Fatalf("disabled organizations = %+v err=%v", orgs, err)
	}
	if projects, err := st.MemberProjects(ctx, "disabled@x"); err != nil || len(projects) != 0 {
		t.Fatalf("disabled member projects = %+v err=%v", projects, err)
	}
	if projects, err := st.ListProjectsForIdentity(ctx, "disabled@x"); err != nil || len(projects) != 0 {
		t.Fatalf("disabled projects = %+v err=%v", projects, err)
	}
	if role, ok, err := st.EffectiveProjectRole(ctx, "p1", "disabled@x"); err != nil || ok {
		t.Fatalf("disabled effective project role = %q ok=%v err=%v", role, ok, err)
	}
	if role, ok, err := st.RepoVisibleTo(ctx, "kunlun-backend", "disabled@x"); err != nil || ok {
		t.Fatalf("disabled repo visibility = %q ok=%v err=%v", role, ok, err)
	}
	if repos, err := st.VisibleRepoNames(ctx, "disabled@x"); err != nil || len(repos) != 0 {
		t.Fatalf("disabled visible repos = %+v err=%v", repos, err)
	}
	if shared, err := st.IdentitiesShareTeam(ctx, "owner@x", "disabled@x"); err != nil || shared {
		t.Fatalf("disabled identity should not share team: shared=%v err=%v", shared, err)
	}
}

func TestIdentitiesShareTeamLegacyFallbackOnlyForLegacyUsers(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateUser(ctx, User{Identity: "registered-a@x"}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateUser(ctx, User{Identity: "registered-b@x"}, now); err != nil {
		t.Fatal(err)
	}

	if shared, err := st.IdentitiesShareTeam(ctx, "registered-a@x", "registered-b@x"); err != nil || shared {
		t.Fatalf("registered users without teams should not share team: shared=%v err=%v", shared, err)
	}
	if shared, err := st.IdentitiesShareTeam(ctx, "registered-a@x", "legacy@x"); err != nil || shared {
		t.Fatalf("registered user should not share legacy fallback: shared=%v err=%v", shared, err)
	}
	if shared, err := st.IdentitiesShareTeam(ctx, "legacy-a@x", "legacy-b@x"); err != nil || !shared {
		t.Fatalf("legacy users without rows should retain flat-roster fallback: shared=%v err=%v", shared, err)
	}
}

func TestProjectOwnerInvariant(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateProject(ctx, "p1", "Kunlun", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "p1", "other@x", RoleOwner); err != nil {
		t.Fatal(err)
	}
	if err := st.RemoveMember(ctx, "p1", "owner@x"); err != nil {
		t.Fatal(err)
	}
	p, err := st.GetProject(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if p.OwnerIdentity != "other@x" {
		t.Fatalf("owner_identity = %q", p.OwnerIdentity)
	}
	if err := st.AddMember(ctx, "p1", "other@x", RoleMember); !errors.Is(err, ErrLastOwner) {
		t.Fatalf("demote last owner: want ErrLastOwner, got %v", err)
	}
	if err := st.RemoveMember(ctx, "p1", "other@x"); !errors.Is(err, ErrLastOwner) {
		t.Fatalf("remove last owner: want ErrLastOwner, got %v", err)
	}
}
