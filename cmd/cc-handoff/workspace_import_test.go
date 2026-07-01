package main

import (
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// mkrepo makes dir/.git as a directory (a normal clone).
func mkrepo(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestScanGitRepos(t *testing.T) {
	root := t.TempDir()

	// Direct children that are repos.
	mkrepo(t, filepath.Join(root, "repoA"))
	mkrepo(t, filepath.Join(root, "repoB"))
	// A non-repo grouping dir with a repo one level deeper (recursive case).
	mkrepo(t, filepath.Join(root, "group", "repoC"))
	// A subdir INSIDE a repo must not be reported separately (stop at repo).
	if err := os.MkdirAll(filepath.Join(root, "repoA", "src", "deep"), 0o755); err != nil {
		t.Fatal(err)
	}
	// A vendored repo inside repoA must be ignored (we stop descending at repoA).
	mkrepo(t, filepath.Join(root, "repoA", "vendor", "nested"))
	// Noise dir at the top level must be skipped even though it holds a repo.
	mkrepo(t, filepath.Join(root, "node_modules", "pkg"))
	// A dotdir must be skipped.
	mkrepo(t, filepath.Join(root, ".hidden", "repoD"))
	// A worktree-style repo: .git is a FILE, not a directory.
	repoE := filepath.Join(root, "repoE")
	if err := os.MkdirAll(repoE, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repoE, ".git"), []byte("gitdir: /somewhere\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	got := scanGitRepos(root, 6)
	sort.Strings(got)
	want := []string{
		filepath.Join(root, "group", "repoC"),
		filepath.Join(root, "repoA"),
		filepath.Join(root, "repoB"),
		filepath.Join(root, "repoE"),
	}
	sort.Strings(want)
	if len(got) != len(want) {
		t.Fatalf("got %d repos %v, want %d %v", len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("repo[%d] = %q, want %q (full: %v)", i, got[i], want[i], got)
		}
	}
}

func TestScanGitReposRootIsRepo(t *testing.T) {
	root := t.TempDir()
	mkrepo(t, root)
	// Even with children, if root itself is a repo it's the only result.
	mkrepo(t, filepath.Join(root, "child"))
	got := scanGitRepos(root, 6)
	if len(got) != 1 || got[0] != root {
		t.Fatalf("root-is-repo: got %v, want [%s]", got, root)
	}
}

func TestScanGitReposDepthLimit(t *testing.T) {
	root := t.TempDir()
	// repo sits 3 levels down; a depth-2 scan must not find it.
	mkrepo(t, filepath.Join(root, "a", "b", "c", "repo"))
	if got := scanGitRepos(root, 2); len(got) != 0 {
		t.Fatalf("depth 2 should find nothing, got %v", got)
	}
	if got := scanGitRepos(root, 6); len(got) != 1 {
		t.Fatalf("depth 6 should find the repo, got %v", got)
	}
}
