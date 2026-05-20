package setup

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const versionMarker = "cc-handoff-version"

var versionLineRE = regexp.MustCompile(`<!--\s*` + versionMarker + `:\s*(\S+)\s*-->`)

// ConflictReason describes why a destination file conflicts with the embedded source.
type ConflictReason int

const (
	// ConflictUnstamped means the destination exists but has no cc-handoff
	// version marker — likely a hand-edited or pre-versioned file.
	ConflictUnstamped ConflictReason = iota
	// ConflictOlder means the destination has a version marker older than
	// the binary's version.
	ConflictOlder
)

// PromptFunc is called when CopyCommands needs the user to decide on a conflict.
// It returns one of 'o' (overwrite), 's' (skip), or 'b' (backup-then-overwrite),
// case-insensitive. Implementations are free to default to 's' on EOF or error
// from underlying input. Pass nil to CopyCommands to make every conflict a skip
// (used by --non-interactive runs).
type PromptFunc func(filename string, reason ConflictReason, existingVer, newVer string) (rune, error)

// CopyResult summarizes what CopyCommands did.
type CopyResult struct {
	Written  []string          // files written or overwritten (relative names, e.g. "handoff.md")
	Skipped  []string          // files left untouched
	BackedUp map[string]string // original path -> backup path (under destDir)
}

// CopyCommands materializes the embedded slash command files into destDir,
// stamping each written file with the binary's version. It does not create
// destDir's parents — call os.MkdirAll on the parent before invoking.
//
// Conflict handling:
//   - target missing: write directly.
//   - target stamped with the same version: skip silently.
//   - target stamped with a newer version: skip with a warning printed to out
//     (the user's binary is older than what they have on disk).
//   - target stamped with an older version, or unstamped: call prompt.
//     prompt == nil means non-interactive — treat as skip.
func CopyCommands(destDir, version string, prompt PromptFunc, out io.Writer) (CopyResult, error) {
	if out == nil {
		out = io.Discard
	}
	res := CopyResult{BackedUp: map[string]string{}}

	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return res, fmt.Errorf("create %s: %w", destDir, err)
	}

	for _, name := range CommandFiles {
		src, err := commandsFS.ReadFile("templates/commands/" + name)
		if err != nil {
			return res, fmt.Errorf("read embedded %s: %w", name, err)
		}
		stamped := stampVersion(src, version)

		dest := filepath.Join(destDir, name)
		existing, err := os.ReadFile(dest)
		switch {
		case errors.Is(err, os.ErrNotExist):
			if err := os.WriteFile(dest, stamped, 0o644); err != nil {
				return res, fmt.Errorf("write %s: %w", dest, err)
			}
			res.Written = append(res.Written, name)
			fmt.Fprintf(out, "  ✓ wrote %s\n", dest)
			continue
		case err != nil:
			return res, fmt.Errorf("stat %s: %w", dest, err)
		}

		existingVer := extractVersion(existing)

		if existingVer == version && existingVer != "" {
			res.Skipped = append(res.Skipped, name)
			fmt.Fprintf(out, "  · %s already at %s, skipped\n", dest, version)
			continue
		}

		if existingVer != "" && version != "" && compareSemver(existingVer, version) > 0 {
			res.Skipped = append(res.Skipped, name)
			fmt.Fprintf(out, "  ! %s is at %s (newer than binary %s), skipped\n", dest, existingVer, version)
			continue
		}

		reason := ConflictUnstamped
		if existingVer != "" {
			reason = ConflictOlder
		}

		choice := 's'
		if prompt != nil {
			c, err := prompt(name, reason, existingVer, version)
			if err != nil {
				return res, fmt.Errorf("prompt for %s: %w", name, err)
			}
			choice = c
		}

		switch choice {
		case 'o', 'O':
			if err := os.WriteFile(dest, stamped, 0o644); err != nil {
				return res, fmt.Errorf("overwrite %s: %w", dest, err)
			}
			res.Written = append(res.Written, name)
			fmt.Fprintf(out, "  ✓ overwrote %s\n", dest)
		case 'b', 'B':
			backup := dest + ".bak." + time.Now().Format("20060102-150405")
			if err := os.WriteFile(backup, existing, 0o644); err != nil {
				return res, fmt.Errorf("backup %s: %w", dest, err)
			}
			if err := os.WriteFile(dest, stamped, 0o644); err != nil {
				return res, fmt.Errorf("write %s after backup: %w", dest, err)
			}
			res.Written = append(res.Written, name)
			res.BackedUp[dest] = backup
			fmt.Fprintf(out, "  ✓ backed up to %s, then overwrote %s\n", backup, dest)
		default:
			res.Skipped = append(res.Skipped, name)
			fmt.Fprintf(out, "  · skipped %s\n", dest)
		}
	}

	return res, nil
}

// CopyCodexPlugin materializes a local Codex plugin under destDir. The plugin
// exposes the same workflow prompts as Codex commands in commands/*.md.
func CopyCodexPlugin(destDir, version string, prompt PromptFunc, out io.Writer) (CopyResult, error) {
	if out == nil {
		out = io.Discard
	}
	res := CopyResult{BackedUp: map[string]string{}}

	manifest, err := codexPluginFS.ReadFile("templates/codex-plugin/.codex-plugin/plugin.json")
	if err != nil {
		return res, fmt.Errorf("read embedded codex plugin manifest: %w", err)
	}
	written, skipped, backups, err := copyStampedFile(filepath.Join(destDir, ".codex-plugin", "plugin.json"), manifest, version, prompt, out, "plugin.json")
	if err != nil {
		return res, err
	}
	appendResult(&res, written, skipped, backups)

	for _, name := range CommandFiles {
		src, err := commandsFS.ReadFile("templates/commands/" + name)
		if err != nil {
			return res, fmt.Errorf("read embedded %s: %w", name, err)
		}
		written, skipped, backups, err := copyStampedFile(filepath.Join(destDir, "commands", name), src, version, prompt, out, name)
		if err != nil {
			return res, err
		}
		appendResult(&res, written, skipped, backups)
	}

	return res, nil
}

func appendResult(res *CopyResult, written, skipped string, backups map[string]string) {
	if written != "" {
		res.Written = append(res.Written, written)
	}
	if skipped != "" {
		res.Skipped = append(res.Skipped, skipped)
	}
	for orig, bak := range backups {
		res.BackedUp[orig] = bak
	}
}

func copyStampedFile(dest string, src []byte, version string, prompt PromptFunc, out io.Writer, displayName string) (written, skipped string, backups map[string]string, err error) {
	backups = map[string]string{}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return "", "", backups, fmt.Errorf("create %s: %w", filepath.Dir(dest), err)
	}

	stamped := stampVersion(src, version)
	existing, readErr := os.ReadFile(dest)
	switch {
	case errors.Is(readErr, os.ErrNotExist):
		if err := os.WriteFile(dest, stamped, 0o644); err != nil {
			return "", "", backups, fmt.Errorf("write %s: %w", dest, err)
		}
		fmt.Fprintf(out, "  ✓ wrote %s\n", dest)
		return displayName, "", backups, nil
	case readErr != nil:
		return "", "", backups, fmt.Errorf("stat %s: %w", dest, readErr)
	}

	existingVer := extractVersion(existing)
	if existingVer == version && existingVer != "" {
		fmt.Fprintf(out, "  · %s already at %s, skipped\n", dest, version)
		return "", displayName, backups, nil
	}
	if existingVer != "" && version != "" && compareSemver(existingVer, version) > 0 {
		fmt.Fprintf(out, "  ! %s is at %s (newer than binary %s), skipped\n", dest, existingVer, version)
		return "", displayName, backups, nil
	}

	reason := ConflictUnstamped
	if existingVer != "" {
		reason = ConflictOlder
	}

	choice := 's'
	if prompt != nil {
		c, err := prompt(displayName, reason, existingVer, version)
		if err != nil {
			return "", "", backups, fmt.Errorf("prompt for %s: %w", displayName, err)
		}
		choice = c
	}

	switch choice {
	case 'o', 'O':
		if err := os.WriteFile(dest, stamped, 0o644); err != nil {
			return "", "", backups, fmt.Errorf("overwrite %s: %w", dest, err)
		}
		fmt.Fprintf(out, "  ✓ overwrote %s\n", dest)
		return displayName, "", backups, nil
	case 'b', 'B':
		backup := dest + ".bak." + time.Now().Format("20060102-150405")
		if err := os.WriteFile(backup, existing, 0o644); err != nil {
			return "", "", backups, fmt.Errorf("backup %s: %w", dest, err)
		}
		if err := os.WriteFile(dest, stamped, 0o644); err != nil {
			return "", "", backups, fmt.Errorf("write %s after backup: %w", dest, err)
		}
		backups[dest] = backup
		fmt.Fprintf(out, "  ✓ backed up to %s, then overwrote %s\n", backup, dest)
		return displayName, "", backups, nil
	default:
		fmt.Fprintf(out, "  · skipped %s\n", dest)
		return "", displayName, backups, nil
	}
}

// stampVersion returns content with a trailing version marker. If content already
// ends with a marker line, it's replaced; otherwise appended on its own line.
func stampVersion(content []byte, version string) []byte {
	if version == "" {
		return content
	}
	marker := fmt.Sprintf("<!-- %s: %s -->\n", versionMarker, version)
	s := string(content)
	s = versionLineRE.ReplaceAllString(s, "")
	s = strings.TrimRight(s, "\n") + "\n\n" + marker
	return []byte(s)
}

// extractVersion finds the last cc-handoff-version marker in content. Returns "" if absent.
func extractVersion(content []byte) string {
	matches := versionLineRE.FindAllStringSubmatch(string(content), -1)
	if len(matches) == 0 {
		return ""
	}
	return matches[len(matches)-1][1]
}

// compareSemver returns -1/0/+1 comparing two semver-ish strings.
// "dev" sorts as the lowest possible version. Strings without a leading 'v' or
// digit fall back to lexicographic compare; we don't need full semver semantics
// here since all real values come from the VERSION file ("0.1.1") or ldflags.
func compareSemver(a, b string) int {
	an := normalizeVer(a)
	bn := normalizeVer(b)
	if an == bn {
		return 0
	}
	pa, pb := splitInts(an), splitInts(bn)
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var x, y int
		if i < len(pa) {
			x = pa[i]
		}
		if i < len(pb) {
			y = pb[i]
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

func normalizeVer(s string) string {
	s = strings.TrimPrefix(strings.TrimSpace(s), "v")
	if s == "dev" || s == "" {
		return "0.0.0"
	}
	if i := strings.IndexAny(s, "-+"); i > 0 {
		s = s[:i]
	}
	return s
}

func splitInts(s string) []int {
	parts := strings.Split(s, ".")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		n := 0
		for _, c := range p {
			if c < '0' || c > '9' {
				return out
			}
			n = n*10 + int(c-'0')
		}
		out = append(out, n)
	}
	return out
}
