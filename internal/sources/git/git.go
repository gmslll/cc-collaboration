package git

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"

	"github.com/cc-collaboration/pkg/handoffschema"
)

// Collect runs git commands relative to repoDir and assembles a Git block.
// base is the base ref to compare against, e.g. "origin/main". If base is
// unreachable, falls back to HEAD~1 so submit still works on shallow clones.
//
// Only commit metadata and changed paths travel in the package — the full
// unified diff is intentionally omitted because pickup-side Claude generates
// the integration plan against the recipient's real frontend tree, not against
// the sender's diff.
func Collect(ctx context.Context, repoDir, base string) (*handoffschema.Git, handoffschema.Repo, error) {
	repo, err := CollectRepoMeta(ctx, repoDir)
	if err != nil {
		return nil, repo, err
	}

	baseSHA, err := run(ctx, repoDir, "git", "rev-parse", base)
	if err != nil {
		alt, err2 := run(ctx, repoDir, "git", "rev-parse", "HEAD~1")
		if err2 != nil {
			return nil, repo, fmt.Errorf("base ref %q unreachable, and HEAD has no parent: %w", base, err)
		}
		baseSHA = alt
	}
	repo.BaseSHA = strings.TrimSpace(baseSHA)

	g := &handoffschema.Git{}

	if log, err := run(ctx, repoDir, "git", "log", "--format=%H%x1f%s%x1f%b%x1e",
		repo.BaseSHA+".."+repo.HeadSHA); err == nil {
		g.Commits = parseCommits(log)
	}

	if names, err := run(ctx, repoDir, "git", "diff", "--name-only", repo.BaseSHA+"..."+repo.HeadSHA); err == nil {
		for line := range strings.SplitSeq(names, "\n") {
			if line = strings.TrimSpace(line); line != "" {
				g.ChangedPaths = append(g.ChangedPaths, line)
			}
		}
	}

	return g, repo, nil
}

// CollectRepoMeta returns just HEAD + branch — no diff work, no base ref.
// Used by module-mode handoffs that ship a self-contained API brief without
// a diff window. BaseSHA is intentionally left empty.
func CollectRepoMeta(ctx context.Context, repoDir string) (handoffschema.Repo, error) {
	repo := handoffschema.Repo{}
	headSHA, err := run(ctx, repoDir, "git", "rev-parse", "HEAD")
	if err != nil {
		return repo, fmt.Errorf("rev-parse HEAD: %w", err)
	}
	repo.HeadSHA = strings.TrimSpace(headSHA)
	if branch, err := run(ctx, repoDir, "git", "rev-parse", "--abbrev-ref", "HEAD"); err == nil {
		repo.Branch = strings.TrimSpace(branch)
	}
	return repo, nil
}

func parseCommits(raw string) []handoffschema.Commit {
	var out []handoffschema.Commit
	for rec := range strings.SplitSeq(raw, "\x1e") {
		rec = strings.TrimSpace(rec)
		if rec == "" {
			continue
		}
		parts := strings.SplitN(rec, "\x1f", 3)
		if len(parts) < 2 {
			continue
		}
		c := handoffschema.Commit{SHA: parts[0], Subject: parts[1]}
		if len(parts) == 3 {
			c.Body = strings.TrimSpace(parts[2])
		}
		out = append(out, c)
	}
	return out
}

func run(ctx context.Context, dir, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("%s %s: %w (stderr: %s)", name, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), nil
}
