package git

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// gitInitRepo makes dir a real git repo with one commit on a deterministic
// branch so worktree operations have a HEAD to branch from.
func gitInitRepo(t *testing.T, dir string) {
	t.Helper()
	cmds := [][]string{
		{"git", "init", "--initial-branch=main", "--quiet"},
		{"git", "config", "user.email", "test@example.com"},
		{"git", "config", "user.name", "test"},
		{"git", "commit", "--allow-empty", "-m", "init", "--quiet"},
	}
	for _, c := range cmds {
		cmd := exec.Command(c[0], c[1:]...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v: %v: %s", c, err, out)
		}
	}
}

func TestAddWorktree_NewBranch(t *testing.T) {
	ctx := context.Background()
	repo := t.TempDir()
	gitInitRepo(t, repo)

	dest := filepath.Join(repo, ".worktrees", "feature-x")
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := AddWorktree(ctx, repo, dest, "feature/x", ""); err != nil {
		t.Fatalf("AddWorktree: %v", err)
	}
	if fi, err := os.Stat(dest); err != nil || !fi.IsDir() {
		t.Fatalf("worktree dir not created at %s: %v", dest, err)
	}

	wts, err := ListWorktrees(ctx, repo)
	if err != nil {
		t.Fatalf("ListWorktrees: %v", err)
	}
	if !hasBranch(wts, "feature/x") {
		t.Errorf("feature/x worktree not listed: %+v", wts)
	}
	// The main worktree is always present too.
	if !hasBranch(wts, "main") {
		t.Errorf("main worktree not listed: %+v", wts)
	}
}

func TestAddWorktree_AttachExisting(t *testing.T) {
	ctx := context.Background()
	repo := t.TempDir()
	gitInitRepo(t, repo)

	// Create a branch ahead of time so AddWorktree must attach, not -b.
	cmd := exec.Command("git", "branch", "existing")
	cmd.Dir = repo
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git branch: %v: %s", err, out)
	}

	dest := filepath.Join(repo, ".worktrees", "existing")
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := AddWorktree(ctx, repo, dest, "existing", ""); err != nil {
		t.Fatalf("AddWorktree (attach): %v", err)
	}
	wts, err := ListWorktrees(ctx, repo)
	if err != nil {
		t.Fatalf("ListWorktrees: %v", err)
	}
	if !hasBranch(wts, "existing") {
		t.Errorf("existing worktree not listed: %+v", wts)
	}
}

func TestRemoveWorktree(t *testing.T) {
	ctx := context.Background()
	repo := t.TempDir()
	gitInitRepo(t, repo)

	dest := filepath.Join(repo, ".worktrees", "tmp")
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := AddWorktree(ctx, repo, dest, "tmp", ""); err != nil {
		t.Fatalf("AddWorktree: %v", err)
	}
	if err := RemoveWorktree(ctx, repo, dest, false); err != nil {
		t.Fatalf("RemoveWorktree: %v", err)
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Errorf("worktree dir still present after remove: %v", err)
	}
	wts, err := ListWorktrees(ctx, repo)
	if err != nil {
		t.Fatalf("ListWorktrees: %v", err)
	}
	if hasBranch(wts, "tmp") {
		t.Errorf("tmp worktree still listed after remove: %+v", wts)
	}
}

func TestListWorktrees_NotARepo(t *testing.T) {
	if _, err := ListWorktrees(context.Background(), t.TempDir()); err == nil {
		t.Error("expected error listing worktrees outside a git repo")
	}
}

func hasBranch(wts []Worktree, branch string) bool {
	for _, w := range wts {
		if w.Branch == branch {
			return true
		}
	}
	return false
}
