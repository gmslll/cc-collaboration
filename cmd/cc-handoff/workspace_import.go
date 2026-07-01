package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/cc-collaboration/internal/config"
)

// runWorkspaceImport scans a directory tree for git repos and registers each as a
// project in a (new or existing) workspace — the bulk alternative to `workspace
// add`, which takes one path at a time. Repos are registered IN PLACE (never
// moved or cloned); import only records their paths in config. A repo already
// tracked in any workspace is skipped, so re-running is idempotent.
func runWorkspaceImport(_ context.Context, args []string) error {
	fs := flag.NewFlagSet("workspace import", flag.ContinueOnError)
	name := fs.String("name", "", "workspace name (default: basename of the imported dir)")
	maxDepth := fs.Int("max-depth", 6, "how deep to recurse looking for repos (descent stops at each repo)")
	asJSON := fs.Bool("json", false, "machine-readable output for the GUI")
	// parseFlexible so `import <dir> --name X` works regardless of order.
	pos, err := parseFlexible(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return errors.New("usage: cc-handoff workspace import <dir> [--name NAME] [--max-depth N] [--json]")
	}
	root, err := filepath.Abs(pos[0])
	if err != nil {
		return err
	}
	if fi, err := os.Stat(root); err != nil || !fi.IsDir() {
		return fmt.Errorf("%s is not an existing directory", root)
	}
	wsName := strings.TrimSpace(*name)
	if wsName == "" {
		wsName = filepath.Base(root)
	}

	repos := scanGitRepos(root, *maxDepth)

	u, err := loadUserOrFail()
	if err != nil {
		return err
	}
	ws, created := findOrCreateWorkspace(u, wsName)

	// Dedupe by path across the whole config so a repo already tracked anywhere
	// (this workspace or another) is skipped rather than double-registered.
	seen := map[string]bool{}
	for i := range u.Workspaces {
		for _, p := range u.Workspaces[i].Projects {
			seen[filepath.Clean(p.Path)] = true
		}
	}
	added := make([]string, 0, len(repos))
	skipped := make([]string, 0)
	for _, r := range repos {
		c := filepath.Clean(r)
		if seen[c] {
			skipped = append(skipped, r)
			continue
		}
		seen[c] = true
		ws.Projects = append(ws.Projects, config.Project{Name: filepath.Base(r), Path: r})
		added = append(added, r)
	}

	// Persist when we changed anything — a brand-new (possibly empty) workspace
	// still counts, so importing an empty dir at least creates the workspace.
	if len(added) > 0 || created {
		if _, err := config.SaveUser(u); err != nil {
			return err
		}
	}

	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(map[string]any{
			"workspace": wsName,
			"created":   created,
			"scanned":   len(repos),
			"added":     added,
			"skipped":   skipped,
		})
	}
	fmt.Printf("workspace %q: added %d project(s), skipped %d already-tracked (found %d repo(s) under %s)\n",
		wsName, len(added), len(skipped), len(repos), root)
	for _, r := range added {
		fmt.Printf("  + %s\n", r)
	}
	return nil
}

// scanGitRepos walks root up to maxDepth and returns every directory that IS a
// git repo (contains a .git entry — a directory for a normal clone, or a file for
// a worktree/submodule). It does NOT descend into a repo (a repo's own subdirs
// aren't separate projects). If root itself is a repo, it's the only result.
//
// A directory is recognized as a repo BEFORE any name-based filtering, so a repo
// that happens to be named like a build/vendor dir — or a dot-named repo such as
// ~/.dotfiles — is still imported. The noise list and the dotdir rule only gate
// whether we DESCEND INTO a non-repo grouping dir, so their worst failure is
// "walk a bit less", never "drop a real project".
func scanGitRepos(root string, maxDepth int) []string {
	noise := map[string]bool{
		"node_modules": true, "vendor": true, "Pods": true,
		"build": true, "dist": true, "target": true, "venv": true,
	}
	var out []string
	var walk func(dir, name string, depth int)
	walk = func(dir, name string, depth int) {
		if isGitRepoDir(dir) {
			out = append(out, dir) // a repo → record it (whatever its name) and stop
			return
		}
		// Not a repo: only descend into non-noise, non-dot grouping dirs. Keyed on
		// the dir's OWN name (root passes ""), so recognizing a repo never depends
		// on this list.
		if name != "" && (noise[name] || strings.HasPrefix(name, ".")) {
			return
		}
		if depth >= maxDepth {
			return
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range entries {
			if e.IsDir() {
				walk(filepath.Join(dir, e.Name()), e.Name(), depth+1)
			}
		}
	}
	walk(root, "", 0)
	return out
}

// isGitRepoDir reports whether dir is the root of a git repo: a `.git` entry
// exists directly in it (a directory for a normal checkout, a file for a
// worktree/submodule). Mirrors the `.git` probe used in internal/config.
func isGitRepoDir(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, ".git"))
	return err == nil
}
