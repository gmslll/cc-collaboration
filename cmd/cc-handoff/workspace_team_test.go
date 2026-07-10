package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cc-collaboration/internal/config"
)

func seedTeamPullUser(t *testing.T, workspaces ...config.Workspace) *config.User {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	u := &config.User{
		RelayURL:   "https://relay.example.com",
		Token:      "token",
		Identity:   "dev@example.com",
		Workspaces: workspaces,
	}
	if _, err := config.SaveUser(u); err != nil {
		t.Fatal(err)
	}
	return u
}

func stubTeamGit(t *testing.T, clone func(context.Context, string, string) error, remotes func(context.Context, string) ([]string, error)) {
	t.Helper()
	oldClone := cloneTeamRepository
	oldRemotes := teamRepositoryRemotes
	cloneTeamRepository = clone
	teamRepositoryRemotes = remotes
	t.Cleanup(func() {
		cloneTeamRepository = oldClone
		teamRepositoryRemotes = oldRemotes
	})
}

func TestWorkspacePullTeamRepoClonesAndRegisters(t *testing.T) {
	seedTeamPullUser(t)
	parent := t.TempDir()
	root := filepath.Join(parent, "Kunlun")
	var clonedURL, clonedDestination string
	stubTeamGit(t, func(_ context.Context, cloneURL, destination string) error {
		clonedURL, clonedDestination = cloneURL, destination
		return os.MkdirAll(filepath.Join(destination, ".git"), 0o755)
	}, func(context.Context, string) ([]string, error) {
		return nil, errors.New("unexpected remote lookup")
	})

	err := runWorkspacePullTeamRepo(context.Background(), []string{
		"Kunlun", "kunlun-backend", "https://github.com/kunlun/kunlun-backend",
		"--path", root, "--project-id", "project-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if clonedURL != "https://github.com/kunlun/kunlun-backend.git" ||
		filepath.Dir(clonedDestination) != root ||
		!strings.HasPrefix(filepath.Base(clonedDestination), ".cc-handoff-clone-") {
		t.Fatalf("clone = %q -> %q", clonedURL, clonedDestination)
	}
	if _, err := os.Stat(filepath.Join(root, "kunlun-backend", ".git")); err != nil {
		t.Fatalf("atomic clone destination: %v", err)
	}
	u := reload(t)
	if len(u.Workspaces) != 1 || u.Workspaces[0].Name != "Kunlun" || u.Workspaces[0].Path != root {
		t.Fatalf("workspaces = %+v", u.Workspaces)
	}
	projects := u.Workspaces[0].Projects
	if len(projects) != 1 || projects[0].Name != "kunlun-backend" || projects[0].ProjectID != "project-1" || projects[0].GitHub != clonedURL {
		t.Fatalf("projects = %+v", projects)
	}
}

func TestWorkspacePullTeamRepoImportsMatchingExistingRemoteIdempotently(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Kunlun")
	destination := filepath.Join(root, "desktop")
	if err := os.MkdirAll(filepath.Join(destination, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	seedTeamPullUser(t, config.Workspace{Name: "Kunlun", Path: root})
	cloneCalls := 0
	stubTeamGit(t, func(context.Context, string, string) error {
		cloneCalls++
		return nil
	}, func(_ context.Context, got string) ([]string, error) {
		if got != destination {
			t.Fatalf("remote lookup = %s", got)
		}
		return []string{"git@github.com:kunlun/desktop.git"}, nil
	})
	args := []string{"Kunlun", "desktop", "https://github.com/kunlun/desktop.git", "--path", root, "--project-id", "project-1"}
	if err := runWorkspacePullTeamRepo(context.Background(), args); err != nil {
		t.Fatal(err)
	}
	if err := runWorkspacePullTeamRepo(context.Background(), args); err != nil {
		t.Fatal(err)
	}
	if cloneCalls != 0 {
		t.Fatalf("matching existing repo was cloned %d times", cloneCalls)
	}
	u := reload(t)
	if len(u.Workspaces[0].Projects) != 1 {
		t.Fatalf("repeat pull duplicated config: %+v", u.Workspaces[0].Projects)
	}
}

func TestWorkspacePullTeamRepoRejectsExistingConflict(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Kunlun")
	destination := filepath.Join(root, "desktop")
	if err := os.MkdirAll(filepath.Join(destination, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	seedTeamPullUser(t)
	stubTeamGit(t, func(context.Context, string, string) error {
		t.Fatal("must not clone over an existing directory")
		return nil
	}, func(context.Context, string) ([]string, error) {
		return []string{"https://github.com/other/desktop.git"}, nil
	})
	err := runWorkspacePullTeamRepo(context.Background(), []string{
		"Kunlun", "desktop", "https://github.com/kunlun/desktop.git", "--path", root,
	})
	if err == nil || !strings.Contains(err.Error(), "none of its git remotes match") {
		t.Fatalf("conflict error = %v", err)
	}
	if len(reload(t).Workspaces) != 0 {
		t.Fatal("failed import must not register an empty workspace")
	}
}

func TestWorkspacePullTeamRepoKeepsCloneFailureUnregistered(t *testing.T) {
	seedTeamPullUser(t)
	root := filepath.Join(t.TempDir(), "Private")
	// Prove an incomplete clone is cleaned from the private temporary path
	// rather than poisoning the final target.
	stubTeamGit(t, func(_ context.Context, _, destination string) error {
		if err := os.WriteFile(filepath.Join(destination, "partial"), []byte("partial"), 0o600); err != nil {
			t.Fatal(err)
		}
		return errors.New("authentication failed")
	}, func(context.Context, string) ([]string, error) { return nil, nil })
	err := runWorkspacePullTeamRepo(context.Background(), []string{
		"Private", "private-repo", "git@github.com:kunlun/private-repo.git", "--path", root,
	})
	if err == nil || !strings.Contains(err.Error(), "local Git/SSH credentials") {
		t.Fatalf("clone failure = %v", err)
	}
	if len(reload(t).Workspaces) != 0 {
		t.Fatal("failed clone must not register an empty workspace")
	}
	entries, readErr := os.ReadDir(root)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if len(entries) != 0 {
		t.Fatalf("failed clone left workspace entries: %v", entries)
	}
}

func TestWorkspacePullTeamRepoRejectsWorkspaceNameCollision(t *testing.T) {
	existing := filepath.Join(t.TempDir(), "one")
	seedTeamPullUser(t, config.Workspace{Name: "Kunlun", Path: existing})
	stubTeamGit(t, func(context.Context, string, string) error {
		t.Fatal("workspace collision must be checked before clone")
		return nil
	}, func(context.Context, string) ([]string, error) { return nil, nil })
	err := runWorkspacePullTeamRepo(context.Background(), []string{
		"Kunlun", "desktop", "https://github.com/kunlun/desktop.git", "--path", filepath.Join(t.TempDir(), "two"),
	})
	if err == nil || !strings.Contains(err.Error(), "already exists at") {
		t.Fatalf("workspace collision = %v", err)
	}
}

func TestWorkspacePullTeamRepoRejectsCaseAndPathWorkspaceCollisions(t *testing.T) {
	existing := filepath.Join(t.TempDir(), "existing")
	if err := os.MkdirAll(existing, 0o755); err != nil {
		t.Fatal(err)
	}
	seedTeamPullUser(t, config.Workspace{Name: "Kunlun", Path: existing})
	stubTeamGit(t, func(context.Context, string, string) error {
		t.Fatal("workspace collisions must be checked before clone")
		return nil
	}, func(context.Context, string) ([]string, error) { return nil, nil })
	if err := runWorkspacePullTeamRepo(context.Background(), []string{
		"kunlun", "desktop", "https://github.com/kunlun/desktop.git", "--path", filepath.Join(t.TempDir(), "other"),
	}); err == nil || !strings.Contains(err.Error(), "conflicts with existing workspace") {
		t.Fatalf("case-only workspace collision = %v", err)
	}
	if err := runWorkspacePullTeamRepo(context.Background(), []string{
		"Other", "desktop", "https://github.com/kunlun/desktop.git", "--path", existing,
	}); err == nil || !strings.Contains(err.Error(), "already registered") {
		t.Fatalf("workspace path collision = %v", err)
	}
}

func TestWorkspacePullTeamRepoRejectsPathLikeNameAndTargetSymlink(t *testing.T) {
	seedTeamPullUser(t)
	cloneCalls := 0
	stubTeamGit(t, func(context.Context, string, string) error {
		cloneCalls++
		return nil
	}, func(context.Context, string) ([]string, error) { return nil, nil })
	if err := runWorkspacePullTeamRepo(context.Background(), []string{
		"../escape", "desktop", "https://github.com/kunlun/desktop.git",
	}); err == nil || !strings.Contains(err.Error(), "workspace name") {
		t.Fatalf("path-like workspace name = %v", err)
	}
	if err := runWorkspacePullTeamRepo(context.Background(), []string{
		"Kunlun", "desktop", "https://github.com/kunlun/desktop.git", "--path", "bad\npath",
	}); err == nil || !strings.Contains(err.Error(), "control characters") {
		t.Fatalf("control-character path = %v", err)
	}

	root := filepath.Join(t.TempDir(), "Kunlun")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	realTarget := t.TempDir()
	if err := os.Symlink(realTarget, filepath.Join(root, "desktop")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	err := runWorkspacePullTeamRepo(context.Background(), []string{
		"Kunlun", "desktop", "https://github.com/kunlun/desktop.git", "--path", root,
	})
	if err == nil || !strings.Contains(err.Error(), "symbolic link") {
		t.Fatalf("symlink target = %v", err)
	}
	if cloneCalls != 0 {
		t.Fatalf("unsafe targets cloned %d times", cloneCalls)
	}
}

func TestWorkspacePullTeamRepoTreatsFlagLikeRepoNameAsData(t *testing.T) {
	seedTeamPullUser(t)
	root := filepath.Join(t.TempDir(), "Kunlun")
	stubTeamGit(t, func(_ context.Context, _, destination string) error {
		return os.Mkdir(filepath.Join(destination, ".git"), 0o755)
	}, func(context.Context, string) ([]string, error) { return nil, nil })
	if err := runWorkspacePullTeamRepo(context.Background(), []string{
		"Kunlun", "--path", "https://github.com/kunlun/desktop.git", "--path", root,
	}); err != nil {
		t.Fatal(err)
	}
	if got := reload(t).Workspaces[0].Projects[0].Name; got != "--path" {
		t.Fatalf("repo name parsed as a flag: %q", got)
	}
}

func TestWorkspacePullTeamRepoDoesNotOverwriteTargetCreatedDuringClone(t *testing.T) {
	seedTeamPullUser(t)
	root := filepath.Join(t.TempDir(), "Kunlun")
	destination := filepath.Join(root, "desktop")
	stubTeamGit(t, func(_ context.Context, _, temporary string) error {
		if err := os.Mkdir(filepath.Join(temporary, ".git"), 0o755); err != nil {
			return err
		}
		if err := os.MkdirAll(destination, 0o755); err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(destination, "keep"), []byte("mine"), 0o600)
	}, func(context.Context, string) ([]string, error) { return nil, nil })
	err := runWorkspacePullTeamRepo(context.Background(), []string{
		"Kunlun", "desktop", "https://github.com/kunlun/desktop.git", "--path", root,
	})
	if err == nil || !strings.Contains(err.Error(), "appeared while cloning") {
		t.Fatalf("racing target = %v", err)
	}
	content, readErr := os.ReadFile(filepath.Join(destination, "keep"))
	if readErr != nil || string(content) != "mine" {
		t.Fatalf("racing target was changed: content=%q err=%v", content, readErr)
	}
	entries, readErr := os.ReadDir(root)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if len(entries) != 1 || entries[0].Name() != "desktop" {
		t.Fatalf("temporary clone not cleaned: %v", entries)
	}
	if len(reload(t).Workspaces) != 0 {
		t.Fatal("racing target must not be registered")
	}
}
