package config

import (
	"encoding/json"
	"os"
)

// DiscoverRepo returns the cc-handoff repo dir for the current working
// directory, or "" when cwd isn't a configured repo. Shared by the desktop
// shells (Lorca `cc-handoff desktop` + the Wails cc-handoff-desktop) to default
// the pickup target.
func DiscoverRepo() string {
	cwd, err := os.Getwd()
	if err != nil {
		return ""
	}
	if _, err := os.Stat(RepoConfigPath(cwd)); err != nil {
		return ""
	}
	return RepoRoot(cwd)
}

// WorkspacesJSON flattens a user's workspaces into the per-project list the
// desktop UI renders (workspace / name / path / launch command). Local-only —
// the relay never sees these paths. Returns "[]" on any error so callers can
// inject it unconditionally.
func WorkspacesJSON(user *User) string {
	type wsItem struct {
		Workspace string `json:"workspace"`
		Name      string `json:"name"`
		Path      string `json:"path"`
		Command   string `json:"command"`
	}
	items := []wsItem{}
	for _, ws := range user.Workspaces {
		for _, p := range ListProjects(user, ws) {
			items = append(items, wsItem{
				Workspace: ws.Name,
				Name:      p.Name,
				Path:      p.Path,
				Command:   BuildLaunchCommand(user, ws, p),
			})
		}
	}
	b, err := json.Marshal(items)
	if err != nil {
		return "[]"
	}
	return string(b)
}
