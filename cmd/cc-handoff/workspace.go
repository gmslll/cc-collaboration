package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/cc-collaboration/internal/config"
	gitsrc "github.com/cc-collaboration/internal/sources/git"
)

func runWorkspace(ctx context.Context, args []string) error {
	if len(args) == 0 {
		workspaceUsage()
		return fmt.Errorf("missing action")
	}
	action, rest := args[0], args[1:]
	switch action {
	case "list", "ls":
		return runWorkspaceList(ctx, rest)
	case "create", "new":
		return runWorkspaceCreate(ctx, rest)
	case "add":
		return runWorkspaceAdd(ctx, rest)
	case "import":
		return runWorkspaceImport(ctx, rest)
	case "remove", "rm", "delete":
		return runWorkspaceRemove(ctx, rest)
	case "set":
		return runWorkspaceSet(ctx, rest)
	case "open":
		return runWorkspaceOpen(ctx, rest)
	case "help", "-h", "--help":
		workspaceUsage()
		return nil
	default:
		workspaceUsage()
		return fmt.Errorf("unknown workspace action %q", action)
	}
}

func workspaceUsage() {
	fmt.Fprint(os.Stderr, `cc-handoff workspace — one-click launch targets (a root dir + projects)

  cc-handoff workspace list
        list workspaces, their projects, and the launch command to copy
  cc-handoff workspace create <name> [--path DIR]
        register a workspace and create its root dir (default: <root>/<name>)
  cc-handoff workspace add <name> <github-url|local-path>
        add a project; a git URL is cloned into the workspace dir, a local
        path is just registered
  cc-handoff workspace import <dir> [--name NAME] [--max-depth N] [--json]
        scan <dir> for git repos and register each as a project (in place, not
        moved/cloned) in workspace NAME (default: basename of <dir>); skips
        repos already tracked
  cc-handoff workspace remove <name> [project]
        drop a workspace (or one project from it) from config; files on disk
        are left untouched
  cc-handoff workspace set <name> [--pre-launch X] [--editor Y] [--agent Z]
        set per-workspace launch settings (only the flags you pass change)
  cc-handoff workspace open <project> [--workspace NAME] [--window]
        launch the agent in a project: in-place (replaces this shell) by
        default, or in a new terminal window with --window

list/add print the launch command to copy; open actually starts the agent.
`)
}

// runWorkspaceOpen launches the agent in a project. Default replaces the current
// shell (SSH-friendly); --window opens a new terminal. exec does not return.
func runWorkspaceOpen(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("workspace open", flag.ContinueOnError)
	wsName := fs.String("workspace", "", "narrow the project lookup to this workspace")
	window := fs.Bool("window", false, "open a new terminal window instead of replacing the current shell")
	pos, err := parseFlexible(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return fmt.Errorf("usage: cc-handoff workspace open <project> [--workspace NAME] [--window]")
	}
	u, err := loadUserOrFail()
	if err != nil {
		return err
	}
	ws, p, err := resolveProject(u, pos[0], *wsName)
	if err != nil {
		return err
	}
	return launchProject(ctx, u, ws, p, *window)
}

func runWorkspaceList(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("workspace list", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}
	u, err := loadUserOrFail()
	if err != nil {
		return err
	}
	if len(u.Workspaces) == 0 {
		fmt.Println("no workspaces configured. Create one with `cc-handoff workspace create <name>`.")
		return nil
	}
	for _, ws := range u.Workspaces {
		dir := config.WorkspaceDir(u, ws)
		name := ws.Name
		if name == "" {
			name = filepath.Base(dir)
		}
		fmt.Printf("%s  (%s)\n", name, dir)
		projects := config.ListProjects(u, ws)
		if len(projects) == 0 {
			fmt.Println("  (no projects — add one with `cc-handoff workspace add " + name + " <github-url|path>`)")
			continue
		}
		for _, p := range projects {
			fmt.Printf("  • %s  %s\n", p.Name, p.Path)
			fmt.Printf("      %s\n", config.BuildLaunchCommand(u, ws, p))
			printWorktrees(ctx, u, ws, p)
		}
	}
	return nil
}

// printWorktrees lists a project's extra branch worktrees (excluding the main
// checkout, already shown as the project itself) indented under it. Best
// effort: a project that isn't a git repo is silently skipped.
func printWorktrees(ctx context.Context, u *config.User, ws config.Workspace, p config.Project) {
	wts, err := gitsrc.ListWorktrees(ctx, p.Path)
	if err != nil {
		return
	}
	for _, wt := range wts {
		if samePath(wt.Path, p.Path) || wt.Bare {
			continue // the main checkout is the project row itself
		}
		branch, cmd := worktreeLaunch(u, ws, wt)
		fmt.Printf("      ↳ %s  %s\n", branch, wt.Path)
		fmt.Printf("          %s\n", cmd)
	}
}

func runWorkspaceCreate(_ context.Context, args []string) error {
	fs := flag.NewFlagSet("workspace create", flag.ContinueOnError)
	pathFlag := fs.String("path", "", "workspace root dir (default: <workspace_root>/<name>)")
	// parseFlexible (not fs.Parse) so `create <name> --path DIR` works: Go's flag
	// package stops at the first positional, so a trailing --path would otherwise
	// be misread as extra positionals and fail the NArg check below.
	pos, err := parseFlexible(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return fmt.Errorf("usage: cc-handoff workspace create <name> [--path DIR]")
	}
	name := pos[0]

	u, err := loadUserOrFail()
	if err != nil {
		return err
	}
	if findWorkspace(u, name) != nil {
		return fmt.Errorf("workspace %q already exists", name)
	}

	ws := config.Workspace{Name: name, Path: *pathFlag}
	dir, err := ensureWorkspaceDir(u, ws)
	if err != nil {
		return err
	}
	u.Workspaces = append(u.Workspaces, ws)
	if _, err := config.SaveUser(u); err != nil {
		return err
	}
	fmt.Printf("created workspace %q at %s\n", name, dir)
	fmt.Printf("add projects with: cc-handoff workspace add %s <github-url|path>\n", name)
	return nil
}

func runWorkspaceAdd(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("workspace add", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 2 {
		return fmt.Errorf("usage: cc-handoff workspace add <name> <github-url|local-path>")
	}
	name, source := fs.Arg(0), fs.Arg(1)

	u, err := loadUserOrFail()
	if err != nil {
		return err
	}

	// Find or create the workspace, carving its root dir.
	ws := findWorkspace(u, name)
	if ws == nil {
		u.Workspaces = append(u.Workspaces, config.Workspace{Name: name})
		ws = &u.Workspaces[len(u.Workspaces)-1]
	}
	root, err := ensureWorkspaceDir(u, *ws)
	if err != nil {
		return err
	}

	var proj config.Project
	if looksLikeGitURL(source) {
		dest := filepath.Join(root, repoBaseName(source))
		if _, err := os.Stat(dest); err == nil {
			return fmt.Errorf("target %s already exists; remove it or pick another workspace", dest)
		}
		fmt.Printf("cloning %s into %s ...\n", source, dest)
		cmd := exec.CommandContext(ctx, "git", "clone", source, dest)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("git clone failed: %w", err)
		}
		proj = config.Project{Name: filepath.Base(dest), Path: dest, GitHub: source}
	} else {
		abs, err := filepath.Abs(source)
		if err != nil {
			return err
		}
		if fi, err := os.Stat(abs); err != nil || !fi.IsDir() {
			return fmt.Errorf("local path %s is not an existing directory", abs)
		}
		proj = config.Project{Name: filepath.Base(abs), Path: abs}
	}

	ws.Projects = append(ws.Projects, proj)
	if _, err := config.SaveUser(u); err != nil {
		return err
	}
	fmt.Printf("added project %q to workspace %q\n", proj.Name, name)
	fmt.Printf("launch with: %s\n", config.BuildLaunchCommand(u, *ws, proj))
	return nil
}

// runWorkspaceRemove drops a workspace, or one project from it, from config.
// Config-only: files on disk are left untouched (we never rm -rf a user's repo).
func runWorkspaceRemove(_ context.Context, args []string) error {
	fs := flag.NewFlagSet("workspace remove", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 && fs.NArg() != 2 {
		return fmt.Errorf("usage: cc-handoff workspace remove <name> [project]")
	}
	name := fs.Arg(0)

	u, err := loadUserOrFail()
	if err != nil {
		return err
	}
	idx := -1
	for i := range u.Workspaces {
		if u.Workspaces[i].Name == name {
			idx = i
			break
		}
	}
	if idx < 0 {
		return fmt.Errorf("workspace %q not found", name)
	}

	if fs.NArg() == 2 {
		proj := fs.Arg(1)
		ws := &u.Workspaces[idx]
		pidx := -1
		for i := range ws.Projects {
			if ws.Projects[i].Name == proj {
				pidx = i
				break
			}
		}
		if pidx < 0 {
			return fmt.Errorf("project %q not found in workspace %q", proj, name)
		}
		ws.Projects = append(ws.Projects[:pidx], ws.Projects[pidx+1:]...)
		if _, err := config.SaveUser(u); err != nil {
			return err
		}
		fmt.Printf("removed project %q from workspace %q (files left on disk)\n", proj, name)
		return nil
	}

	u.Workspaces = append(u.Workspaces[:idx], u.Workspaces[idx+1:]...)
	if _, err := config.SaveUser(u); err != nil {
		return err
	}
	fmt.Printf("removed workspace %q (files left on disk)\n", name)
	return nil
}

// runWorkspaceSet sets per-workspace launch fields (pre_launch / editor / agent),
// changing only the flags passed and preserving the rest of the config.
func runWorkspaceSet(_ context.Context, args []string) error {
	fs := flag.NewFlagSet("workspace set", flag.ContinueOnError)
	preLaunch := fs.String("pre-launch", "", "shell snippet run before the agent")
	editor := fs.String("editor", "", "editor launch command")
	agent := fs.String("agent", "", "agent override: claude|codex|manual")
	pos, err := parseFlexible(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return fmt.Errorf("usage: cc-handoff workspace set <name> [--pre-launch X] [--editor Y] [--agent Z]")
	}

	u, err := loadUserOrFail()
	if err != nil {
		return err
	}
	ws := findWorkspace(u, pos[0])
	if ws == nil {
		return fmt.Errorf("workspace %q not found", pos[0])
	}

	var setErr error
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "pre-launch":
			ws.PreLaunch = *preLaunch
		case "editor":
			ws.Editor = *editor
		case "agent":
			if !validAgent(*agent) {
				setErr = fmt.Errorf("invalid agent %q (claude|codex|manual)", *agent)
				return
			}
			ws.Agent = *agent
		}
	})
	if setErr != nil {
		return setErr
	}

	if _, err := config.SaveUser(u); err != nil {
		return err
	}
	fmt.Printf("workspace %q updated\n", pos[0])
	return nil
}

// loadUserOrFail loads the user config, turning a missing file into the
// standard "run init" error the workspace subcommands share.
func loadUserOrFail() (*config.User, error) {
	u, path, err := config.LoadUser()
	if err != nil {
		return nil, err
	}
	if u == nil {
		return nil, fmt.Errorf("user config missing at %s; run `cc-handoff init`", path)
	}
	return u, nil
}

// ensureWorkspaceDir resolves a workspace's root dir and creates it, returning
// the resolved path.
func ensureWorkspaceDir(u *config.User, ws config.Workspace) (string, error) {
	dir := config.WorkspaceDir(u, ws)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("create workspace dir %s: %w", dir, err)
	}
	return dir, nil
}

func findWorkspace(u *config.User, name string) *config.Workspace {
	for i := range u.Workspaces {
		if u.Workspaces[i].Name == name {
			return &u.Workspaces[i]
		}
	}
	return nil
}

// looksLikeGitURL reports whether source should be treated as a clonable git
// remote rather than a local directory path.
func looksLikeGitURL(source string) bool {
	switch {
	case strings.HasPrefix(source, "https://"), strings.HasPrefix(source, "http://"),
		strings.HasPrefix(source, "git@"), strings.HasPrefix(source, "ssh://"),
		strings.HasPrefix(source, "git://"):
		return true
	case strings.HasSuffix(source, ".git"):
		return true
	default:
		return false
	}
}

// repoBaseName derives the clone target directory name from a git URL, e.g.
// "git@github.com:org/my-repo.git" -> "my-repo".
func repoBaseName(url string) string {
	s := strings.TrimSuffix(url, ".git")
	s = strings.TrimSuffix(s, "/")
	if i := strings.LastIndexAny(s, "/:"); i >= 0 {
		s = s[i+1:]
	}
	if s == "" {
		s = "repo"
	}
	return s
}
