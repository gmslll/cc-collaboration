package main

import (
	"cmp"
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/cc-collaboration/internal/config"
	gitsrc "github.com/cc-collaboration/internal/sources/git"
)

func runWorktree(ctx context.Context, args []string) error {
	if len(args) == 0 {
		worktreeUsage()
		return fmt.Errorf("missing action")
	}
	action, rest := args[0], args[1:]
	switch action {
	case "add":
		return runWorktreeAdd(ctx, rest)
	case "list", "ls":
		return runWorktreeList(ctx, rest)
	case "remove", "rm":
		return runWorktreeRemove(ctx, rest)
	case "help", "-h", "--help":
		worktreeUsage()
		return nil
	default:
		worktreeUsage()
		return fmt.Errorf("unknown worktree action %q", action)
	}
}

func worktreeUsage() {
	fmt.Fprint(os.Stderr, `cc-handoff worktree — branch worktrees under a workspace project

  cc-handoff worktree add <project> <branch> [--workspace NAME] [--start REF]
        create <project>/.worktrees/<branch>; makes the branch if it doesn't
        exist (from --start or HEAD), else attaches the existing one
  cc-handoff worktree list <project> [--workspace NAME]
        list the project's worktrees and the launch command to copy
  cc-handoff worktree remove <project> <branch> [--workspace NAME] [--force]
        remove a worktree

The launch command is printed for you to copy/paste; nothing is auto-started.
`)
}

func runWorktreeAdd(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("worktree add", flag.ContinueOnError)
	wsName := fs.String("workspace", "", "narrow the project lookup to this workspace")
	start := fs.String("start", "", "start point for a new branch (default: current HEAD)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 2 {
		return fmt.Errorf("usage: cc-handoff worktree add <project> <branch> [--workspace NAME] [--start REF]")
	}
	project, branch := fs.Arg(0), fs.Arg(1)

	u, err := loadUserOrFail()
	if err != nil {
		return err
	}
	ws, p, err := resolveProject(u, project, *wsName)
	if err != nil {
		return err
	}

	dest := config.WorktreeDir(p.Path, branch)
	if _, err := os.Stat(dest); err == nil {
		return fmt.Errorf("worktree %s already exists", dest)
	}
	if err := os.MkdirAll(config.WorktreesDir(p.Path), 0o755); err != nil {
		return fmt.Errorf("create worktrees dir: %w", err)
	}
	if err := gitsrc.AddWorktree(ctx, p.Path, dest, branch, *start); err != nil {
		return err
	}
	fmt.Printf("created worktree for %q at %s\n", branch, dest)
	// The Project here is an ephemeral launch-command carrier, not persisted to
	// config — same reuse as worktreeLaunch.
	fmt.Printf("launch with: %s\n", config.BuildLaunchCommand(u, ws, config.Project{Name: branch, Path: dest}))
	return nil
}

func runWorktreeList(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("worktree list", flag.ContinueOnError)
	wsName := fs.String("workspace", "", "narrow the project lookup to this workspace")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("usage: cc-handoff worktree list <project> [--workspace NAME]")
	}
	u, err := loadUserOrFail()
	if err != nil {
		return err
	}
	ws, p, err := resolveProject(u, fs.Arg(0), *wsName)
	if err != nil {
		return err
	}
	wts, err := gitsrc.ListWorktrees(ctx, p.Path)
	if err != nil {
		return err
	}
	for _, wt := range wts {
		branch, cmd := worktreeLaunch(u, ws, wt)
		main := ""
		if samePath(wt.Path, p.Path) {
			main = "  [main]"
		}
		fmt.Printf("• %s  %s%s\n", branch, wt.Path, main)
		fmt.Printf("    %s\n", cmd)
	}
	return nil
}

func runWorktreeRemove(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("worktree remove", flag.ContinueOnError)
	wsName := fs.String("workspace", "", "narrow the project lookup to this workspace")
	force := fs.Bool("force", false, "remove even with uncommitted changes")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 2 {
		return fmt.Errorf("usage: cc-handoff worktree remove <project> <branch> [--workspace NAME] [--force]")
	}
	project, branch := fs.Arg(0), fs.Arg(1)

	u, err := loadUserOrFail()
	if err != nil {
		return err
	}
	_, p, err := resolveProject(u, project, *wsName)
	if err != nil {
		return err
	}
	dest := config.WorktreeDir(p.Path, branch)
	if err := gitsrc.RemoveWorktree(ctx, p.Path, dest, *force); err != nil {
		return err
	}
	fmt.Printf("removed worktree %s\n", dest)
	return nil
}

// resolveProject finds a project by name across the user's workspaces. When
// wsName is set the search is limited to that workspace. A name that matches
// projects in more than one workspace is ambiguous and returns an error asking
// the caller to disambiguate with --workspace.
func resolveProject(u *config.User, project, wsName string) (config.Workspace, config.Project, error) {
	type match struct {
		ws config.Workspace
		p  config.Project
	}
	var matches []match
	for _, ws := range u.Workspaces {
		if wsName != "" && ws.Name != wsName {
			continue
		}
		for _, p := range config.ListProjects(u, ws) {
			if p.Name == project {
				matches = append(matches, match{ws, p})
			}
		}
	}
	switch len(matches) {
	case 0:
		if wsName != "" {
			return config.Workspace{}, config.Project{}, fmt.Errorf("project %q not found in workspace %q", project, wsName)
		}
		return config.Workspace{}, config.Project{}, fmt.Errorf("project %q not found; add it with `cc-handoff workspace add`", project)
	case 1:
		return matches[0].ws, matches[0].p, nil
	default:
		return config.Workspace{}, config.Project{}, fmt.Errorf("project %q exists in multiple workspaces; pass --workspace NAME", project)
	}
}

// worktreeLaunch returns the display branch label and the copyable launch
// command for a worktree, the bits shared by `worktree list` and `workspace
// list`'s nested view (each formats the surrounding line its own way). A
// detached worktree (empty branch) is labelled "(detached)". The command reuses
// BuildLaunchCommand via an ephemeral Project — a launch-command carrier, never
// persisted to config.
func worktreeLaunch(u *config.User, ws config.Workspace, wt gitsrc.Worktree) (branch, cmd string) {
	branch = cmp.Or(wt.Branch, "(detached)")
	cmd = config.BuildLaunchCommand(u, ws, config.Project{Name: branch, Path: wt.Path})
	return branch, cmd
}

// samePath reports whether two paths point at the same location, resolving
// symlinks first. git reports the main worktree via its real path (e.g.
// /private/var/... on macOS) while a configured project path may go through a
// symlink (/var/...), so a plain string compare would miss the match.
func samePath(a, b string) bool {
	if a == b {
		return true
	}
	ra, err1 := filepath.EvalSymlinks(a)
	rb, err2 := filepath.EvalSymlinks(b)
	return err1 == nil && err2 == nil && ra == rb
}
