package setup

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// instructionsHeading is the H2 every cc-handoff instructions snippet starts
// with. AppendSnippet uses it as the idempotency marker — if the destination
// already contains a line starting with this heading, the append is skipped
// so init runs are safe to repeat.
const instructionsHeading = "## cc-handoff"

// SnippetResult tells the caller what AppendSnippet did, so init can print
// useful status without re-reading the file.
type SnippetResult int

const (
	// SnippetWritten means the snippet was appended (or the file was created).
	SnippetWritten SnippetResult = iota
	// SnippetSkipped means the file already contained the marker heading.
	SnippetSkipped
)

// AppendSnippet appends snippet to the file at path, idempotently. The
// snippet is expected to start with "## cc-handoff" (or the configured
// heading); if a line beginning with that heading already exists in the
// file, AppendSnippet is a no-op. Otherwise:
//   - file missing: create with snippet (single trailing newline).
//   - file exists: append snippet, separated by a blank line if the file
//     doesn't already end with one.
//
// Empty path is rejected; empty snippet is treated as success no-op.
func AppendSnippet(path, snippet string) (SnippetResult, error) {
	if path == "" {
		return SnippetSkipped, errors.New("AppendSnippet: path is required")
	}
	if snippet == "" {
		return SnippetSkipped, nil
	}

	existing, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return SnippetSkipped, err
		}
		if err := os.WriteFile(path, []byte(ensureTrailingNewline(snippet)), 0o644); err != nil {
			return SnippetSkipped, err
		}
		return SnippetWritten, nil
	}
	if err != nil {
		return SnippetSkipped, fmt.Errorf("read %s: %w", path, err)
	}

	if strings.Contains(string(existing), instructionsHeading) {
		return SnippetSkipped, nil
	}

	combined := string(existing)
	if !strings.HasSuffix(combined, "\n\n") {
		if strings.HasSuffix(combined, "\n") {
			combined += "\n"
		} else {
			combined += "\n\n"
		}
	}
	combined += ensureTrailingNewline(snippet)
	if err := os.WriteFile(path, []byte(combined), 0o644); err != nil {
		return SnippetSkipped, err
	}
	return SnippetWritten, nil
}

func ensureTrailingNewline(s string) string {
	if strings.HasSuffix(s, "\n") {
		return s
	}
	return s + "\n"
}
