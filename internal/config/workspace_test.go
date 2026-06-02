package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWorkspaceRootDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	if got, want := WorkspaceRootDir(nil), filepath.Join(home, "cc-handoff-workspaces"); got != want {
		t.Errorf("default root = %q, want %q", got, want)
	}
	if got, want := WorkspaceRootDir(&User{}), filepath.Join(home, "cc-handoff-workspaces"); got != want {
		t.Errorf("empty-config root = %q, want %q", got, want)
	}
	if got, want := WorkspaceRootDir(&User{WorkspaceRoot: "~/code"}), filepath.Join(home, "code"); got != want {
		t.Errorf("~-expanded root = %q, want %q", got, want)
	}
	if got, want := WorkspaceRootDir(&User{WorkspaceRoot: "/srv/ws"}), "/srv/ws"; got != want {
		t.Errorf("absolute root = %q, want %q", got, want)
	}
}

func TestWorkspaceDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	u := &User{}

	if got, want := WorkspaceDir(u, Workspace{Name: "demo"}), filepath.Join(home, "cc-handoff-workspaces", "demo"); got != want {
		t.Errorf("carved dir = %q, want %q", got, want)
	}
	if got, want := WorkspaceDir(u, Workspace{Name: "demo", Path: "/explicit/dir"}), "/explicit/dir"; got != want {
		t.Errorf("explicit dir = %q, want %q", got, want)
	}
}

func TestListProjects(t *testing.T) {
	root := t.TempDir()

	// Two git repos discoverable by scanning the root.
	mkRepo(t, filepath.Join(root, "backend"))
	mkRepo(t, filepath.Join(root, "frontend"))
	// A non-repo dir and a file should be ignored.
	if err := os.MkdirAll(filepath.Join(root, "notes"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "README"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	ws := Workspace{
		Name: "demo",
		Path: root,
		// "frontend" is also explicitly tracked with a GitHub URL — should
		// dedup against the scanned one and keep the URL.
		Projects: []Project{
			{Name: "frontend", Path: filepath.Join(root, "frontend"), GitHub: "https://example.com/frontend.git"},
			// An explicit project outside the scanned root.
			{Name: "mobile", Path: "/elsewhere/mobile"},
		},
	}

	got := ListProjects(nil, ws)
	want := map[string]string{ // name -> github
		"backend":  "",
		"frontend": "https://example.com/frontend.git",
		"mobile":   "",
	}
	if len(got) != len(want) {
		t.Fatalf("got %d projects %+v, want %d", len(got), got, len(want))
	}
	for _, p := range got {
		gh, ok := want[p.Name]
		if !ok {
			t.Errorf("unexpected project %q", p.Name)
			continue
		}
		if p.GitHub != gh {
			t.Errorf("project %q github = %q, want %q", p.Name, p.GitHub, gh)
		}
	}
	// Sorted by name.
	if got[0].Name != "backend" || got[len(got)-1].Name != "mobile" {
		t.Errorf("not sorted by name: %v", names(got))
	}
}

func TestBuildLaunchCommand(t *testing.T) {
	root := "/ws"
	tests := []struct {
		name string
		u    *User
		ws   Workspace
		p    Project
		want string
	}{
		{
			name: "bare defaults to claude",
			ws:   Workspace{Path: root},
			p:    Project{Path: filepath.Join(root, "api")},
			want: "cd '/ws/api' && claude",
		},
		{
			name: "pre_launch and editor",
			ws:   Workspace{Path: root, PreLaunch: "nvm use", Editor: "code ."},
			p:    Project{Path: filepath.Join(root, "api")},
			want: "cd '/ws/api' && nvm use && code . && claude",
		},
		{
			name: "workspace agent overrides user agent",
			u:    &User{Agent: "codex"},
			ws:   Workspace{Path: root, Agent: "claude"},
			p:    Project{Path: filepath.Join(root, "api")},
			want: "cd '/ws/api' && claude",
		},
		{
			name: "falls back to user agent",
			u:    &User{Agent: "codex"},
			ws:   Workspace{Path: root},
			p:    Project{Path: filepath.Join(root, "api")},
			want: "cd '/ws/api' && codex",
		},
		{
			name: "relative project path joins workspace root",
			ws:   Workspace{Path: root},
			p:    Project{Path: "api"},
			want: "cd '/ws/api' && claude",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := BuildLaunchCommand(tt.u, tt.ws, tt.p); got != tt.want {
				t.Errorf("BuildLaunchCommand = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestWorktreeDir(t *testing.T) {
	proj := "/ws/api"
	if got, want := WorktreesDir(proj), "/ws/api/.worktrees"; got != want {
		t.Errorf("WorktreesDir = %q, want %q", got, want)
	}
	if got, want := WorktreeDir(proj, "main"), "/ws/api/.worktrees/main"; got != want {
		t.Errorf("WorktreeDir = %q, want %q", got, want)
	}
	// Slashes in the branch collapse to a single path segment.
	if got, want := WorktreeDir(proj, "feature/x"), "/ws/api/.worktrees/feature-x"; got != want {
		t.Errorf("WorktreeDir slash = %q, want %q", got, want)
	}
}

// TestListProjects_IgnoresWorktrees guards the layout assumption: a project's
// .worktrees/<branch> dir must NOT be surfaced as a top-level project, because
// ListProjects only scans one level deep for a .git *directory* (worktrees
// have a .git *file* nested two levels down).
func TestListProjects_IgnoresWorktrees(t *testing.T) {
	root := t.TempDir()
	mkRepo(t, filepath.Join(root, "api"))
	// Simulate a worktree dir with a .git FILE under api/.worktrees/feature-x.
	wt := filepath.Join(root, "api", ".worktrees", "feature-x")
	if err := os.MkdirAll(wt, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(wt, ".git"), []byte("gitdir: ../../.git/worktrees/feature-x\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	got := ListProjects(nil, Workspace{Name: "demo", Path: root})
	if len(got) != 1 || got[0].Name != "api" {
		t.Fatalf("expected only [api], got %v", names(got))
	}
}

func mkRepo(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func names(ps []Project) []string {
	out := make([]string, len(ps))
	for i, p := range ps {
		out[i] = p.Name
	}
	return out
}
