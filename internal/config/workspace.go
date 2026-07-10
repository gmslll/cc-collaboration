package config

import (
	"cmp"
	"context"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/cc-collaboration/internal/agent"
)

// DefaultWorkspaceRoot is the base dir used when User.WorkspaceRoot is empty.
const DefaultWorkspaceRoot = "~/cc-handoff-workspaces"

// WorkspaceRootDir resolves the base directory under which workspaces are
// carved when no explicit path is given: User.WorkspaceRoot, or
// DefaultWorkspaceRoot. The leading ~ is expanded to the user's home dir.
func WorkspaceRootDir(u *User) string {
	root := DefaultWorkspaceRoot
	if u != nil && strings.TrimSpace(u.WorkspaceRoot) != "" {
		root = u.WorkspaceRoot
	}
	return expandPath(root)
}

// WorkspaceDir resolves a workspace's root directory: ws.Path when set,
// otherwise <WorkspaceRootDir>/<name>. The result is absolute (~ expanded).
func WorkspaceDir(u *User, ws Workspace) string {
	if strings.TrimSpace(ws.Path) != "" {
		return expandPath(ws.Path)
	}
	name := ws.Name
	if name == "" {
		name = "default"
	}
	return filepath.Join(WorkspaceRootDir(u), name)
}

// ListProjects returns the effective project list for a workspace: the git
// repos found by scanning the workspace root one level deep (auto-discovery),
// merged with ws.Projects (explicitly tracked, e.g. cloned entries). Dedup is
// by cleaned absolute path; explicit entries win so their GitHub source URL is
// preserved. Names default to the directory basename. The result is sorted by
// name for stable output.
func ListProjects(u *User, ws Workspace) []Project {
	root := WorkspaceDir(u, ws)

	byPath := map[string]Project{}
	add := func(p Project) {
		clean := projectPath(root, p.Path)
		if clean == "" {
			return
		}
		if _, ok := byPath[clean]; ok {
			return // first writer wins; explicit entries are added first
		}
		if p.Name == "" {
			p.Name = filepath.Base(clean)
		}
		p.Path = clean
		byPath[clean] = p
	}

	// Explicit entries first so they take precedence over scanned ones.
	for _, p := range ws.Projects {
		add(p)
	}
	// Scan the workspace root one level deep for git repos.
	if entries, err := os.ReadDir(root); err == nil {
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			dir := filepath.Join(root, e.Name())
			if fi, err := os.Stat(filepath.Join(dir, ".git")); err == nil && fi.IsDir() {
				add(Project{Path: dir})
			}
		}
	}

	out := make([]Project, 0, len(byPath))
	for _, p := range byPath {
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// WorkspaceProjectIDForPath returns the relay project id configured for the
// workspace project that contains path. Empty means either no workspace project
// matched or the matched project has no project_id binding.
func WorkspaceProjectIDForPath(u *User, path string) string {
	p, ok := WorkspaceProjectForPath(u, path)
	if !ok {
		return ""
	}
	return strings.TrimSpace(p.ProjectID)
}

// WorkspaceProjectForPath finds the most specific workspace project containing
// path. Explicit project entries can carry metadata such as project_id; scanned
// repos still participate but usually have no project_id.
func WorkspaceProjectForPath(u *User, path string) (Project, bool) {
	if u == nil || strings.TrimSpace(path) == "" {
		return Project{}, false
	}
	cleanPath, err := filepath.Abs(expandPath(path))
	if err != nil {
		cleanPath = filepath.Clean(expandPath(path))
	}
	var (
		best    Project
		bestLen int
		found   bool
	)
	for _, ws := range u.Workspaces {
		for _, p := range ListProjects(u, ws) {
			projectRoot := filepath.Clean(p.Path)
			if !pathWithin(cleanPath, projectRoot) {
				continue
			}
			if n := len(projectRoot); !found || n > bestLen {
				best = p
				bestLen = n
				found = true
			}
		}
	}
	return best, found
}

// BuildLaunchCommand renders the copyable one-line shell command that opens a
// project: cd into it, run the optional pre-launch snippet, optionally open the
// editor, then start the agent. This is the single source of truth for the
// launch shape — the UI/CLI copy it today, a future LaunchProject would execute
// the same string. Pure: no side effects.
//
// Example: cd '/Users/me/ws/api' && nvm use && code . && claude
func BuildLaunchCommand(u *User, ws Workspace, p Project) string {
	agentCmd := cmp.Or(ws.Agent, userAgent(u), "claude")
	parts := []string{"cd " + agent.POSIXSingleQuote(projectPath(WorkspaceDir(u, ws), p.Path))}
	if strings.TrimSpace(ws.PreLaunch) != "" {
		parts = append(parts, ws.PreLaunch)
	}
	if strings.TrimSpace(ws.Editor) != "" {
		parts = append(parts, ws.Editor)
	}
	parts = append(parts, agentCmd)
	return strings.Join(parts, " && ")
}

// LaunchProject is the reserved extension point for actually spawning a
// workspace project (open a terminal, cd, run pre_launch, start the agent). It
// is intentionally NOT implemented in this version: the launcher only copies
// BuildLaunchCommand's output. When wired up, it should feed the same fields
// BuildLaunchCommand already resolves into the terminal-launch path, keeping
// the change local.
func LaunchProject(_ context.Context, _ *User, _ Workspace, _ Project) error {
	return errors.New("workspace auto-launch not implemented yet; copy the launch command and run it instead")
}

// WorktreesDir returns a project's worktree container directory:
// <projectPath>/.worktrees. Branch worktrees live one level below it.
func WorktreesDir(projectPath string) string {
	return filepath.Join(projectPath, ".worktrees")
}

// WorktreeDir returns the directory for a branch's worktree:
// <projectPath>/.worktrees/<sanitized-branch>. Slashes in the branch name are
// replaced with "-" so "feature/x" doesn't nest extra directories.
func WorktreeDir(projectPath, branch string) string {
	return filepath.Join(WorktreesDir(projectPath), sanitizeBranch(branch))
}

// HandoffWorktreeBranch derives the branch name for a handoff's worktree:
// h_<shortid>_<senderBranch>, falling back to h_<shortid> when the sender's
// branch is unknown. shortid is the handoff id's trailing token (after the last
// "_") so the name stays readable. Shared by `pickup --worktree` (CLI) and the
// pickup_handoff MCP tool so both produce identical names.
func HandoffWorktreeBranch(handoffID, senderBranch string) string {
	short := handoffID
	if i := strings.LastIndex(handoffID, "_"); i >= 0 && i+1 < len(handoffID) {
		short = handoffID[i+1:]
	}
	name := "h_" + short
	if b := strings.TrimSpace(senderBranch); b != "" {
		name += "_" + sanitizeBranch(b)
	}
	return name
}

// sanitizeBranch turns a branch name into a single safe path segment. It only
// collapses "/" → "-", which covers the common feature/x case on POSIX
// filesystems. Other git-legal-but-path-hostile characters (":", "?", "\" on
// Windows) are left as-is for now; the caller's "dest already exists" check
// catches the rare collision (e.g. foo/bar and foo-bar both → foo-bar).
func sanitizeBranch(branch string) string {
	return strings.ReplaceAll(branch, "/", "-")
}

// projectPath resolves a project's configured path against the workspace root:
// absolute paths (after ~ expansion) are returned as-is; relative paths are
// joined onto root. Empty input returns "".
func projectPath(root, p string) string {
	if strings.TrimSpace(p) == "" {
		return ""
	}
	p = expandPath(p)
	if !filepath.IsAbs(p) {
		p = filepath.Join(root, p)
	}
	return filepath.Clean(p)
}

func pathWithin(path, root string) bool {
	path = filepath.Clean(path)
	root = filepath.Clean(root)
	if path == root {
		return true
	}
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != "." && rel != "" && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && rel != ".."
}

func userAgent(u *User) string {
	if u == nil {
		return ""
	}
	return u.Agent
}

// expandPath expands a leading ~ (or ~/...) to the user's home directory.
func expandPath(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, strings.TrimPrefix(strings.TrimPrefix(p, "~"), "/"))
		}
	}
	return p
}
