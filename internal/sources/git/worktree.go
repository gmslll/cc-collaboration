package git

import (
	"context"
	"fmt"
	"os"
	"os/exec"
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
// already exists it attaches with `git worktree add <dest> <branch>`. stdout
// and stderr stream to the caller's terminal since creation may fetch or print
// progress.
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

// RemoveWorktree runs `git worktree remove <dest>`, optionally with --force.
func RemoveWorktree(ctx context.Context, repoDir, dest string, force bool) error {
	args := []string{"worktree", "remove"}
	if force {
		args = append(args, "--force")
	}
	args = append(args, dest)
	return runStreaming(ctx, repoDir, args...)
}

// branchExists reports whether a local branch ref exists in repoDir.
func branchExists(ctx context.Context, repoDir, branch string) bool {
	_, err := run(ctx, repoDir, "git", "show-ref", "--verify", "--quiet", "refs/heads/"+branch)
	return err == nil
}

// runStreaming runs a git command with stdout/stderr wired to the process so
// the user sees progress, mirroring the clone flow in the workspace CLI. This
// is the user-facing counterpart to the sibling run helper in git.go: run
// captures output for parsing (ListWorktrees, Collect), runStreaming streams it
// for commands the user watches (worktree add/remove). Pick run when you need
// the output, runStreaming when the user does.
func runStreaming(ctx context.Context, dir string, args ...string) error {
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = dir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
	}
	return nil
}
