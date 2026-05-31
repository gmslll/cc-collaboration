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

The launch command is printed for you to copy/paste; nothing is auto-started.
`)
}

func runWorkspaceList(_ context.Context, args []string) error {
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
		}
	}
	return nil
}

func runWorkspaceCreate(_ context.Context, args []string) error {
	fs := flag.NewFlagSet("workspace create", flag.ContinueOnError)
	pathFlag := fs.String("path", "", "workspace root dir (default: <workspace_root>/<name>)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("usage: cc-handoff workspace create <name> [--path DIR]")
	}
	name := fs.Arg(0)

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
