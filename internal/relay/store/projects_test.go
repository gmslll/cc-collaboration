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

	// MemberProjects (for /v1/me).
	if prs, _ := st.MemberProjects(ctx, "dev@x"); len(prs) != 1 || prs[0].ID != "p1" || prs[0].Role != RoleViewer {
		t.Fatalf("member projects = %+v", prs)
	}

	// List scope: all vs per-identity.
	if all, _ := st.ListProjects(ctx); len(all) != 1 {
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
