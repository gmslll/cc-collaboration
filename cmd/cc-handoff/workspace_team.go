package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"unicode"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/githubrepo"
)

type teamRepoPullResult struct {
	Workspace   string `json:"workspace"`
	RepoName    string `json:"repo_name"`
	Destination string `json:"destination"`
	Status      string `json:"status"`
}

var cloneTeamRepository = func(ctx context.Context, cloneURL, destination string) error {
	cmd := exec.CommandContext(ctx, "git", "clone", "--", cloneURL, destination)
	// Keep stdout reserved for --json. Git diagnostics still reach the user,
	// but can never corrupt the machine-readable result consumed by the app.
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

var teamRepositoryRemotes = func(ctx context.Context, destination string) ([]string, error) {
	if _, err := os.Stat(filepath.Join(destination, ".git")); err != nil {
		return nil, errors.New("not a git checkout")
	}
	cmd := exec.CommandContext(ctx, "git", "-C", destination, "remote", "-v")
	out, err := cmd.Output()
	if err != nil {
		return nil, errors.New("cannot read git remotes")
	}
	seen := map[string]bool{}
	var urls []string
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 2 || seen[fields[1]] {
			continue
		}
		seen[fields[1]] = true
		urls = append(urls, fields[1])
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return urls, nil
}

// runWorkspacePullTeamRepo performs one independently reportable item in the
// desktop app's multi-repository "拉取团队项目" flow. One repo per invocation
// means a failed clone cannot roll back earlier successful repositories.
func runWorkspacePullTeamRepo(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("workspace pull-team-repo", flag.ContinueOnError)
	workspacePath := fs.String("path", "", "workspace root directory")
	projectID := fs.String("project-id", "", "relay team project id")
	asJSON := fs.Bool("json", false, "machine-readable result")
	// The three values originate partly in relay data. Parse them as literal
	// positionals before flags so a stable repo name such as "--path" can never
	// be reinterpreted as an option.
	if len(args) < 3 {
		return errors.New("usage: cc-handoff workspace pull-team-repo <workspace> <repo-name> <github-url> [--path DIR] [--project-id ID] [--json]")
	}
	pos := args[:3]
	if err := fs.Parse(args[3:]); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("unexpected arguments after pull-team-repo options")
	}
	workspaceName := strings.TrimSpace(pos[0])
	repoName := strings.TrimSpace(pos[1])
	workspacePathValue := strings.TrimSpace(*workspacePath)
	projectIDValue := strings.TrimSpace(*projectID)
	if !validTeamWorkspaceName(workspaceName) {
		return errors.New("workspace name is empty or contains path separators, reserved characters, or a reserved device name")
	}
	if repoName == "" || hasControlText(repoName) {
		return errors.New("repo name is required and cannot contain control characters")
	}
	if hasControlText(workspacePathValue) || hasControlText(projectIDValue) {
		return errors.New("workspace path and project id cannot contain control characters")
	}
	remote, err := githubrepo.Normalize(pos[2])
	if err != nil {
		return fmt.Errorf("invalid GitHub clone URL: %w", err)
	}

	u, err := loadUserOrFail()
	if err != nil {
		return err
	}
	for i := range u.Workspaces {
		if u.Workspaces[i].Name != workspaceName && strings.EqualFold(u.Workspaces[i].Name, workspaceName) {
			return fmt.Errorf("workspace %q conflicts with existing workspace %q", workspaceName, u.Workspaces[i].Name)
		}
	}
	desired := config.Workspace{Name: workspaceName, Path: workspacePathValue}
	desiredRoot, err := absoluteClean(config.WorkspaceDir(u, desired))
	if err != nil {
		return fmt.Errorf("resolve workspace path: %w", err)
	}
	ws := findWorkspace(u, workspaceName)
	createdWorkspace := false
	if ws == nil {
		ws = &desired
		createdWorkspace = true
	} else if workspacePathValue != "" {
		existingRoot, err := absoluteClean(config.WorkspaceDir(u, *ws))
		if err != nil {
			return fmt.Errorf("resolve existing workspace path: %w", err)
		}
		if !samePath(existingRoot, desiredRoot) {
			return fmt.Errorf("workspace %q already exists at %s, not %s", workspaceName, existingRoot, desiredRoot)
		}
	}
	root, err := absoluteClean(config.WorkspaceDir(u, *ws))
	if err != nil {
		return fmt.Errorf("resolve workspace path: %w", err)
	}
	for i := range u.Workspaces {
		other := &u.Workspaces[i]
		if other.Name == ws.Name {
			continue
		}
		otherRoot, err := absoluteClean(config.WorkspaceDir(u, *other))
		if err != nil {
			return fmt.Errorf("resolve workspace %q path: %w", other.Name, err)
		}
		if samePath(root, otherRoot) || root == otherRoot || sameExistingFile(root, otherRoot) {
			return fmt.Errorf("workspace path %s is already registered as workspace %q", root, other.Name)
		}
	}
	if info, err := os.Lstat(root); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("workspace path %s is a symbolic link; choose its real parent directory", root)
	} else if err == nil && !info.IsDir() {
		return fmt.Errorf("workspace path %s exists and is not a directory", root)
	} else if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("inspect workspace path %s: %w", root, err)
	}

	destination := filepath.Join(root, remote.RepoName)
	if err := validateTeamRepositoryRegistration(u, ws, repoName, destination, projectIDValue); err != nil {
		return err
	}
	status := "cloned"
	if info, err := os.Lstat(destination); err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("target %s is a symbolic link and will not be imported or overwritten", destination)
		}
		if !info.IsDir() {
			return fmt.Errorf("target %s exists and is not a directory", destination)
		}
		remotes, err := teamRepositoryRemotes(ctx, destination)
		if err != nil {
			return fmt.Errorf("target %s already exists but is not a readable git repository", destination)
		}
		matched := false
		for _, existing := range remotes {
			if githubrepo.SameRepository(existing, remote.URL) {
				matched = true
				break
			}
		}
		if !matched {
			return fmt.Errorf("target %s already exists but none of its git remotes match %s/%s", destination, strings.Split(remote.Key, "/")[0], remote.RepoName)
		}
		status = "imported"
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("inspect target %s: %w", destination, err)
	} else {
		if err := os.MkdirAll(root, 0o755); err != nil {
			return fmt.Errorf("create workspace directory %s: %w", root, err)
		}
		temporary, err := os.MkdirTemp(root, ".cc-handoff-clone-")
		if err != nil {
			return fmt.Errorf("prepare clone in workspace %s: %w", root, err)
		}
		defer func() { _ = os.RemoveAll(temporary) }()
		if err := cloneTeamRepository(ctx, remote.URL, temporary); err != nil {
			return fmt.Errorf("git clone failed (check repository access and your local Git/SSH credentials): %w", err)
		}
		if _, err := os.Lstat(destination); err == nil {
			return fmt.Errorf("target %s appeared while cloning; it was not overwritten", destination)
		} else if !os.IsNotExist(err) {
			return fmt.Errorf("inspect target %s after clone: %w", destination, err)
		}
		if err := os.Rename(temporary, destination); err != nil {
			return fmt.Errorf("place cloned repository at %s without overwriting: %w", destination, err)
		}
		temporary = ""
	}

	alreadyRegistered, err := registerTeamRepository(u, ws, repoName, destination, remote.URL, projectIDValue)
	if err != nil {
		return err
	}
	if alreadyRegistered && status == "imported" {
		status = "already_registered"
	}
	if createdWorkspace {
		u.Workspaces = append(u.Workspaces, *ws)
	}
	if _, err := config.SaveUser(u); err != nil {
		return fmt.Errorf("save workspace config (repository remains at %s): %w", destination, err)
	}

	result := teamRepoPullResult{
		Workspace:   workspaceName,
		RepoName:    repoName,
		Destination: destination,
		Status:      status,
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(result)
	}
	fmt.Printf("%s %q in workspace %q at %s\n", status, repoName, workspaceName, destination)
	return nil
}

func registerTeamRepository(u *config.User, ws *config.Workspace, repoName, destination, cloneURL, projectID string) (bool, error) {
	if err := validateTeamRepositoryRegistration(u, ws, repoName, destination, projectID); err != nil {
		return false, err
	}
	destination, err := absoluteClean(destination)
	if err != nil {
		return false, err
	}
	workspaceRoot := config.WorkspaceDir(u, *ws)
	for i := range ws.Projects {
		p := &ws.Projects[i]
		path := resolveConfiguredProjectPath(workspaceRoot, p.Path)
		if p.Name != repoName || !samePath(path, destination) {
			continue
		}
		unchanged := p.GitHub == cloneURL && (projectID == "" || p.ProjectID == projectID)
		p.GitHub = cloneURL
		if projectID != "" {
			p.ProjectID = projectID
		}
		return unchanged, nil
	}
	ws.Projects = append(ws.Projects, config.Project{
		Name:      repoName,
		Path:      destination,
		GitHub:    cloneURL,
		ProjectID: projectID,
	})
	return false, nil
}

func validateTeamRepositoryRegistration(u *config.User, ws *config.Workspace, repoName, destination, projectID string) error {
	destination, err := absoluteClean(destination)
	if err != nil {
		return err
	}
	for wi := range u.Workspaces {
		other := &u.Workspaces[wi]
		for pi := range other.Projects {
			p := &other.Projects[pi]
			path := resolveConfiguredProjectPath(config.WorkspaceDir(u, *other), p.Path)
			if samePath(path, destination) && other.Name != ws.Name {
				return fmt.Errorf("target repository is already registered in workspace %q", other.Name)
			}
		}
	}
	workspaceRoot := config.WorkspaceDir(u, *ws)
	for i := range ws.Projects {
		p := &ws.Projects[i]
		path := resolveConfiguredProjectPath(workspaceRoot, p.Path)
		if p.Name == repoName && !samePath(path, destination) {
			return fmt.Errorf("project %q already exists in workspace %q at %s", repoName, ws.Name, path)
		}
		if samePath(path, destination) && p.Name != repoName {
			return fmt.Errorf("target repository is already registered as project %q", p.Name)
		}
		if p.Name == repoName && samePath(path, destination) && strings.TrimSpace(p.ProjectID) != "" && projectID != "" && strings.TrimSpace(p.ProjectID) != projectID {
			return fmt.Errorf("project %q is already bound to a different team project", repoName)
		}
	}
	return nil
}

func resolveConfiguredProjectPath(root, path string) string {
	if !filepath.IsAbs(path) {
		path = filepath.Join(root, path)
	}
	clean, err := absoluteClean(path)
	if err != nil {
		return filepath.Clean(path)
	}
	return clean
}

func absoluteClean(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	return filepath.Clean(abs), nil
}

func sameExistingFile(left, right string) bool {
	leftInfo, leftErr := os.Stat(left)
	rightInfo, rightErr := os.Stat(right)
	return leftErr == nil && rightErr == nil && os.SameFile(leftInfo, rightInfo)
}

func hasControlText(value string) bool {
	return strings.IndexFunc(value, unicode.IsControl) >= 0
}

func validTeamWorkspaceName(value string) bool {
	if value == "" || len([]rune(value)) > 80 || value == "." || value == ".." ||
		hasControlText(value) || strings.ContainsAny(value, `<>:"/\|?*`) ||
		strings.HasPrefix(value, ".") || strings.HasSuffix(value, ".") {
		return false
	}
	device := strings.ToUpper(strings.SplitN(value, ".", 2)[0])
	if device == "CON" || device == "PRN" || device == "AUX" || device == "NUL" {
		return false
	}
	return !((strings.HasPrefix(device, "COM") || strings.HasPrefix(device, "LPT")) &&
		len(device) == 4 && device[3] >= '1' && device[3] <= '9')
}
