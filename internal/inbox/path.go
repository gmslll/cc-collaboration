package inbox

import (
	"os"
	"path/filepath"
)

const (
	// PrimaryInboxDir is the agent-neutral default. New repos materialize
	// here; the path doesn't presume any particular AI agent.
	PrimaryInboxDir = ".cc-handoff/inbox"
	// LegacyInboxDir is what cc-handoff used before multi-agent support.
	// Kept readable so existing repos don't need a migration step.
	LegacyInboxDir = ".claude/handoff-inbox"
)

// resolveDir returns the inbox directory for repoRoot. Decision order:
//  1. override (from repo config Inbox.Dir) when non-empty — absolute path
//     used verbatim, relative path joined onto repoRoot.
//  2. legacy .claude/handoff-inbox when it exists and the primary doesn't,
//     so installs predating multi-agent support keep working.
//  3. primary .cc-handoff/inbox.
func resolveDir(repoRoot, override string) string {
	if override != "" {
		if filepath.IsAbs(override) {
			return override
		}
		return filepath.Join(repoRoot, override)
	}
	legacy := filepath.Join(repoRoot, LegacyInboxDir)
	primary := filepath.Join(repoRoot, PrimaryInboxDir)
	if dirExists(legacy) && !dirExists(primary) {
		return legacy
	}
	return primary
}

func dirExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}
