package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// runCommit implements `cc-handoff commit`: a safe, atomic commit+push for a
// working tree shared by several agent sessions.
//
// It NEVER touches the working tree, the shared index, or local HEAD/refs.
// Instead it builds the commit directly on top of <remote>/<branch> from the
// current working-tree contents of the given paths — via a private temp index
// (GIT_INDEX_FILE) + `git write-tree` + `git commit-tree` — and fast-forward
// pushes that commit object to the branch, serialized by a real cross-process
// flock. This sidesteps the detached-HEAD and shared-index races that plague
// plain `git add` + `git commit` when multiple sessions share one .git.
//
// Only the listed paths are included; other sessions' unrelated working-tree
// edits are left untouched. If the remote advanced and changed one of your
// paths since the fetch, it aborts (exit 3) rather than clobbering.
//
// Exit codes: 0 ok · 1 error/usage · 2 lock timeout · 3 conflict · 4 nothing to commit.
func runCommit(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("commit", flag.ContinueOnError)
	msg := fs.String("m", "", "commit message (required)")
	repo := fs.String("repo", ".", "repo directory")
	remote := fs.String("remote", "origin", "remote name")
	branch := fs.String("branch", "main", "target branch")
	noPush := fs.Bool("no-push", false, "build the commit but don't push")
	timeout := fs.Duration("lock-timeout", 60*time.Second, "max wait for the commit lock")
	retries := fs.Int("retries", 5, "non-ff fetch+rebuild retries")
	fs.Usage = func() {
		fmt.Fprint(os.Stderr, `cc-handoff commit — safe atomic commit+push for a shared working tree

Usage:
  cc-handoff commit -m "<message>" [flags] -- <path>...

Builds a commit from the CURRENT contents of <path>... on top of
<remote>/<branch> — without touching the working tree, index, or HEAD — and
fast-forward-pushes it, serialized by a cross-process lock. Never force-pushes.
Only the given paths are committed. If the remote advanced and changed one of
your paths, it aborts instead of clobbering.

Flags:
  -m <message>        commit message (required)
  --repo DIR          repo directory (default ".")
  --remote NAME       remote (default "origin")
  --branch NAME       target branch (default "main")
  --no-push           build the commit but don't push
  --lock-timeout DUR  max wait for the commit lock (default 60s)
  --retries N         non-ff fetch+rebuild retries (default 5)

Exit codes: 0 ok · 1 error/usage · 2 lock timeout · 3 conflict (remote changed
one of your paths — resolve manually) · 4 nothing to commit.
`)
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	paths := fs.Args()
	if strings.TrimSpace(*msg) == "" {
		fs.Usage()
		return fmt.Errorf("commit: -m <message> is required")
	}
	if len(paths) == 0 {
		fs.Usage()
		return fmt.Errorf("commit: at least one <path> is required")
	}

	root, err := cmtGitTrim(ctx, *repo, nil, "rev-parse", "--show-toplevel")
	if err != nil {
		return fmt.Errorf("commit: %s is not a git repo: %w", *repo, err)
	}

	// Real cross-process mutex: only one `cc-handoff commit` touches the branch
	// at a time on this machine. flock is released by the OS if we crash.
	release, lerr := acquireCommitLock(filepath.Join(root, ".git", "cc-handoff-commit.lock"), *timeout)
	if lerr != nil {
		fmt.Fprintln(os.Stderr, "error:", lerr)
		os.Exit(2)
	}

	sha, code, cerr := cmtCommitAndPush(ctx, root, *remote, *branch, *msg, paths, *noPush, *retries)
	release() // release before any os.Exit so the fallback lockfile is cleaned up

	if code != 0 {
		fmt.Fprintln(os.Stderr, "error:", cerr)
		os.Exit(code)
	}
	if cerr != nil {
		return cerr // generic error -> main prints it and exits 1
	}
	if *noPush {
		fmt.Printf("built %s (not pushed)\n", sha)
	} else {
		fmt.Printf("pushed %s -> %s/%s\n", sha, *remote, *branch)
	}
	return nil
}

// cmtCommitAndPush builds the commit on <remote>/<branch> and fast-forward
// pushes it, retrying on non-ff as long as the remote's new commits don't touch
// the requested paths. Returns (sha, exitCode, err); exitCode is 0 for success
// or a generic error, 3 for a conflict, 4 for nothing-to-commit.
func cmtCommitAndPush(ctx context.Context, root, remote, branch, msg string, paths []string, noPush bool, retries int) (string, int, error) {
	remoteRef := remote + "/" + branch
	if _, err := cmtGit(ctx, root, nil, "fetch", remote, branch); err != nil {
		return "", 0, fmt.Errorf("fetch %s %s: %w", remote, branch, err)
	}
	for attempt := 0; ; attempt++ {
		base, err := cmtGitTrim(ctx, root, nil, "rev-parse", remoteRef)
		if err != nil {
			return "", 0, fmt.Errorf("rev-parse %s: %w", remoteRef, err)
		}
		sha, code, err := cmtBuildCommit(ctx, root, base, msg, paths)
		if code != 0 || err != nil {
			return "", code, err
		}
		if noPush {
			return sha, 0, nil
		}
		if _, perr := cmtGit(ctx, root, nil, "push", remote, sha+":"+branch); perr == nil {
			return sha, 0, nil
		} else if attempt >= retries {
			return "", 0, fmt.Errorf("push rejected after %d retries: %w", retries, perr)
		}
		// Push rejected — most likely the remote advanced. Re-fetch and decide.
		if _, err := cmtGit(ctx, root, nil, "fetch", remote, branch); err != nil {
			return "", 0, fmt.Errorf("re-fetch: %w", err)
		}
		newBase, err := cmtGitTrim(ctx, root, nil, "rev-parse", remoteRef)
		if err != nil {
			return "", 0, err
		}
		if newBase == base {
			return "", 0, fmt.Errorf("push to %s rejected but the ref did not move (check remote / permissions)", remoteRef)
		}
		// If the intervening commits touched any of our paths, our commit would
		// silently revert them — refuse and let a human resolve it.
		diffArgs := append([]string{"diff", "--name-only", base, newBase, "--"}, paths...)
		changed, err := cmtGitTrim(ctx, root, nil, diffArgs...)
		if err != nil {
			return "", 0, err
		}
		if changed != "" {
			return "", 3, fmt.Errorf("%s advanced and changed: %s — resolve manually (committing now would clobber it)",
				remoteRef, strings.ReplaceAll(changed, "\n", ", "))
		}
		// Safe to rebuild on the newer base; loop.
	}
}

// cmtBuildCommit stages the working-tree contents of paths into a PRIVATE temp
// index seeded from base's tree, then writes a commit object with base as its
// only parent. Nothing on disk (working tree / .git/index / HEAD) is touched.
func cmtBuildCommit(ctx context.Context, root, base, msg string, paths []string) (string, int, error) {
	tmp, err := os.CreateTemp("", "cc-commit-index-*")
	if err != nil {
		return "", 0, err
	}
	tmpIdx := tmp.Name()
	tmp.Close()
	defer os.Remove(tmpIdx)
	env := append(os.Environ(), "GIT_INDEX_FILE="+tmpIdx)

	if _, err := cmtGit(ctx, root, env, "read-tree", base); err != nil {
		return "", 0, fmt.Errorf("read-tree %s: %w", base, err)
	}
	// --all so modifications, additions AND deletions under paths are staged.
	addArgs := append([]string{"add", "--all", "--"}, paths...)
	if _, err := cmtGit(ctx, root, env, addArgs...); err != nil {
		return "", 0, fmt.Errorf("stage paths: %w", err)
	}
	tree, err := cmtGitTrim(ctx, root, env, "write-tree")
	if err != nil {
		return "", 0, fmt.Errorf("write-tree: %w", err)
	}
	baseTree, err := cmtGitTrim(ctx, root, nil, "rev-parse", base+"^{tree}")
	if err != nil {
		return "", 0, err
	}
	if tree == baseTree {
		return "", 4, fmt.Errorf("nothing to commit for the given paths")
	}
	// commit-tree takes author/committer from git config / GIT_* env.
	sha, err := cmtGitTrim(ctx, root, nil, "commit-tree", tree, "-p", base, "-m", msg)
	if err != nil {
		return "", 0, fmt.Errorf("commit-tree: %w", err)
	}
	return sha, 0, nil
}

// cmtGit runs a git command in dir (with optional extra env) and returns stdout,
// wrapping non-zero exits with the trimmed stderr for a clear message.
func cmtGit(ctx context.Context, dir string, env []string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = dir
	if env != nil {
		cmd.Env = env
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("git %s: %w (%s)", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), nil
}

func cmtGitTrim(ctx context.Context, dir string, env []string, args ...string) (string, error) {
	out, err := cmtGit(ctx, dir, env, args...)
	return strings.TrimSpace(out), err
}
