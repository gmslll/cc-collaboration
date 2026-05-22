package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// resolveRepoFlag turns a --repo / --workdir flag value (possibly empty,
// relative, or with a typo) into an absolute path that contains a
// .cc-handoff.toml. Empty value falls back to the process cwd. The strict
// "must contain .cc-handoff.toml at this exact path" check exists so a typo
// like `--repo ~/work/forntend-project1` fails fast instead of silently
// walking up to a sibling repo's config via ancestor traversal.
func resolveRepoFlag(raw, flagName string) (string, error) {
	cwd := raw
	if cwd == "" {
		w, err := os.Getwd()
		if err != nil {
			return "", err
		}
		return w, nil
	}
	abs, err := filepath.Abs(cwd)
	if err != nil {
		return "", fmt.Errorf("resolve %s path: %w", flagName, err)
	}
	fi, err := os.Stat(abs)
	if err != nil {
		return "", fmt.Errorf("%s: %w", flagName, err)
	}
	if !fi.IsDir() {
		return "", fmt.Errorf("%s: %s is not a directory", flagName, abs)
	}
	if _, err := os.Stat(filepath.Join(abs, ".cc-handoff.toml")); err != nil {
		return "", fmt.Errorf("%s: no .cc-handoff.toml directly in %s (run `cc-handoff init` there or fix the path)", flagName, abs)
	}
	return abs, nil
}
