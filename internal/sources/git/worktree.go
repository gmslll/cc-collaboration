package git

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Worktree describes one entry from `git worktree list --porcelain`.
type Worktree struct {
	Path   string // absolute worktree path
	Branch string // short branch name, e.g. "feature/x"; empty when detached
	Head   string // HEAD SHA
	Bare   bool   // the bare main repo, if any
}

// ListWorktrees parses `git worktree list --porcelain` for the repo containing
// repoDir and returns every worktree (including the main one). Returns an error
// when repoDir is not inside a git repository.
func ListWorktrees(ctx context.Context, repoDir string) ([]Worktree, error) {
	out, err := run(ctx, repoDir, "git", "worktree", "list", "--porcelain")
	if err != nil {
		return nil, err
	}
	return parseWorktrees(out), nil
}

// parseWorktrees turns porcelain output into Worktree records. Records are
// separated by blank lines; each starts with a "worktree <path>" line.
func parseWorktrees(raw string) []Worktree {
	var out []Worktree
	var cur *Worktree
	flush := func() {
		if cur != nil {
			out = append(out, *cur)
			cur = nil
		}
	}
	for line := range strings.SplitSeq(raw, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			flush()
			continue
		}
		switch {
		case strings.HasPrefix(line, "worktree "):
			flush()
			cur = &Worktree{Path: strings.TrimPrefix(line, "worktree ")}
		case cur == nil:
			// stray line before the first record; ignore
		case strings.HasPrefix(line, "HEAD "):
			cur.Head = strings.TrimPrefix(line, "HEAD ")
		case strings.HasPrefix(line, "branch "):
			// "branch refs/heads/feature/x" → "feature/x"
			cur.Branch = strings.TrimPrefix(strings.TrimPrefix(line, "branch "), "refs/heads/")
		case line == "bare":
			cur.Bare = true
		}
	}
	flush()
	return out
}

// AddWorktree creates a worktree at dest for the repo at repoDir. When branch
// does not exist yet it runs `git worktree add -b <branch> <dest> [start]` to
// create it (from start, or current HEAD when start is empty); when the branch
// already exists it attaches with `git worktree add <dest> <branch>`. git's
// progress (including stdout) streams to the caller's stderr so it stays visible
// in a terminal without polluting a machine-readable stdout (e.g. `pickup
// --json`, or the MCP server's JSON-RPC stdio channel).
func AddWorktree(ctx context.Context, repoDir, dest, branch, start string) error {
	var args []string
	if branchExists(ctx, repoDir, branch) {
		args = []string{"worktree", "add", dest, branch}
	} else {
		args = []string{"worktree", "add", "-b", branch, dest}
		if strings.TrimSpace(start) != "" {
			args = append(args, start)
		}
	}
	return runStreaming(ctx, repoDir, args...)
}

// CarveWorktree creates a worktree at dest under repoDir: it refuses if dest
// already exists, ensures the parent dir, then runs AddWorktree. This is the
// "carve a worktree at a known path" step shared by `pickup --worktree` (CLI)
// and the pickup_handoff MCP tool, so the existence guard and mkdir don't drift
// between them. Callers compute dest/branch from config's path + naming helpers.
func CarveWorktree(ctx context.Context, repoDir, dest, branch, start string) error {
	if _, err := os.Stat(dest); err == nil {
		return fmt.Errorf("worktree %s already exists", dest)
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return fmt.Errorf("create worktrees dir: %w", err)
	}
	return AddWorktree(ctx, repoDir, dest, branch, start)
}

// RemoveWorktree runs `git worktree remove <dest>`, optionally with --force.
func RemoveWorktree(ctx context.Context, repoDir, dest string, force bool) error {
	args := []string{"worktree", "remove"}
	if force {
		args = append(args, "--force")
	}
	args = append(args, dest)
	return runStreaming(ctx, repoDir, args...)
}

// MergedWorktreeBranches returns the worktrees whose branch has already been
// merged into base — the cleanup candidates for `worktree remove --prune-merged`.
// The main worktree, the bare repo, detached worktrees, and the base branch's
// own worktree are excluded.
func MergedWorktreeBranches(ctx context.Context, repoDir, base string) ([]Worktree, error) {
	wts, err := ListWorktrees(ctx, repoDir)
	if err != nil {
		return nil, err
	}
	out, err := run(ctx, repoDir, "git", "branch", "--merged", base, "--format=%(refname:short)")
	if err != nil {
		return nil, err
	}
	merged := map[string]bool{}
	for line := range strings.SplitSeq(out, "\n") {
		if b := strings.TrimSpace(line); b != "" {
			merged[b] = true
		}
	}
	var cands []Worktree
	for _, wt := range wts {
		if wt.Bare || wt.Branch == "" || wt.Branch == base {
			continue
		}
		if merged[wt.Branch] {
			cands = append(cands, wt)
		}
	}
	return cands, nil
}

// DeleteBranch runs `git branch -d <branch>` (safe delete; refuses if unmerged).
func DeleteBranch(ctx context.Context, repoDir, branch string) error {
	return runStreaming(ctx, repoDir, "branch", "-d", branch)
}

// PruneWorktrees runs `git worktree prune` to clear stale administrative entries.
func PruneWorktrees(ctx context.Context, repoDir string) error {
	return runStreaming(ctx, repoDir, "worktree", "prune")
}

// branchExists reports whether a local branch ref exists in repoDir.
func branchExists(ctx context.Context, repoDir, branch string) bool {
	_, err := run(ctx, repoDir, "git", "show-ref", "--verify", "--quiet", "refs/heads/"+branch)
	return err == nil
}

// runStreaming runs a git command with its output wired to the process's
// stderr so the user sees progress, mirroring the clone flow in the workspace
// CLI. This is the user-facing counterpart to the sibling run helper in git.go:
// run captures output for parsing (ListWorktrees, Collect), runStreaming streams
// it for commands the user watches (worktree add/remove). Pick run when you need
// the output, runStreaming when the user does.
//
// Both git's stdout and stderr go to os.Stderr (not os.Stdout): some git
// messages (e.g. "HEAD is now at …" on checkout) land on stdout, which would
// corrupt callers whose stdout is a machine contract — `cc-handoff pickup
// --json` and the MCP server's JSON-RPC stdio channel both materialize worktrees
// through here. Progress stays visible in a terminal regardless.
func runStreaming(ctx context.Context, dir string, args ...string) error {
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = dir
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
	}
	return nil
}
