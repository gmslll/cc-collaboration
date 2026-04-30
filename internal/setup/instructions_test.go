package setup

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const sampleSnippet = `## cc-handoff (cross-machine handoff)

This repo uses cc-handoff. Tools: ` + "`submit_handoff`" + `, etc.
`

func TestAppendSnippetCreatesFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "AGENTS.md")
	res, err := AppendSnippet(path, sampleSnippet)
	if err != nil {
		t.Fatal(err)
	}
	if res != SnippetWritten {
		t.Errorf("want Written, got %v", res)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(got), "## cc-handoff") {
		t.Errorf("file missing heading:\n%s", got)
	}
}

func TestAppendSnippetIdempotent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "AGENTS.md")
	if _, err := AppendSnippet(path, sampleSnippet); err != nil {
		t.Fatal(err)
	}
	res, err := AppendSnippet(path, sampleSnippet)
	if err != nil {
		t.Fatal(err)
	}
	if res != SnippetSkipped {
		t.Errorf("second call: want Skipped, got %v", res)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(got), "## cc-handoff") != 1 {
		t.Errorf("expected exactly one heading, got:\n%s", got)
	}
}

func TestAppendSnippetExtendsExistingFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "CLAUDE.md")
	preexisting := "# Project notes\n\nSome other content.\n"
	if err := os.WriteFile(path, []byte(preexisting), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := AppendSnippet(path, sampleSnippet); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	s := string(got)
	if !strings.HasPrefix(s, preexisting) {
		t.Errorf("preexisting content missing or reordered:\n%s", s)
	}
	if !strings.Contains(s, "## cc-handoff") {
		t.Errorf("snippet not appended:\n%s", s)
	}
}

func TestAppendSnippetEmptySnippetNoOp(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "AGENTS.md")
	res, err := AppendSnippet(path, "")
	if err != nil {
		t.Fatal(err)
	}
	if res != SnippetSkipped {
		t.Errorf("want Skipped, got %v", res)
	}
	if _, err := os.Stat(path); err == nil {
		t.Errorf("file should not have been created")
	}
}
