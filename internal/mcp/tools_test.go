package mcp

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/handoff"
)

// TestReadAttachments_DedupeBasename: two files with the same basename land
// under different names (`screen.png`, `screen-2.png`) so neither clobbers
// the other in the receiver's attachments/ directory.
func TestReadAttachments_DedupeBasename(t *testing.T) {
	dir := t.TempDir()
	a := filepath.Join(dir, "a")
	b := filepath.Join(dir, "b")
	for _, sub := range []string{a, b} {
		if err := os.MkdirAll(sub, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(sub, "screen.png"), []byte("data-"+filepath.Base(sub)), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	out, names, err := readAttachments(dir, []string{
		filepath.Join(a, "screen.png"),
		filepath.Join(b, "screen.png"),
	})
	if err != nil {
		t.Fatalf("readAttachments: %v", err)
	}
	if len(out) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(out))
	}
	if want := []string{"screen.png", "screen-2.png"}; !slices.Equal(names, want) {
		t.Errorf("names: got %v, want %v", names, want)
	}
	if string(out["screen.png"]) != "data-a" {
		t.Errorf("first file should be a's bytes, got %q", out["screen.png"])
	}
	if string(out["screen-2.png"]) != "data-b" {
		t.Errorf("second file should be b's bytes, got %q", out["screen-2.png"])
	}
}

// TestReadAttachments_RejectsReservedName: caller can't shadow swagger.yaml.
func TestReadAttachments_RejectsReservedName(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, handoff.SwaggerSnapshotName)
	if err := os.WriteFile(path, []byte("evil"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, _, err := readAttachments(dir, []string{path})
	if err == nil || !strings.Contains(err.Error(), "reserved") {
		t.Errorf("want reserved-name error, got %v", err)
	}
}

// TestReadAttachments_RejectsMissingFile fails fast before any upload.
func TestReadAttachments_RejectsMissingFile(t *testing.T) {
	dir := t.TempDir()
	_, _, err := readAttachments(dir, []string{filepath.Join(dir, "nope.png")})
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}

// TestReadAttachments_RejectsOversize: we cap files client-side so the upload
// never even leaves the local machine. The over-cap file is created as a
// sparse file (Truncate, no allocation) so CI doesn't pay 50 MB of memory or
// disk — readAttachments stops at os.Stat anyway and never reads the bytes.
func TestReadAttachments_RejectsOversize(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "big.bin")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	if err := os.Truncate(path, handoff.AttachmentMaxBytes+1); err != nil {
		t.Fatal(err)
	}
	_, _, err = readAttachments(dir, []string{path})
	if err == nil || !strings.Contains(err.Error(), "max") {
		t.Errorf("want max-size error, got %v", err)
	}
}

// TestReadAttachments_RejectsDirectory: passing a folder path is a usage
// mistake; surface it instead of trying to read it as bytes.
func TestReadAttachments_RejectsDirectory(t *testing.T) {
	dir := t.TempDir()
	_, _, err := readAttachments(filepath.Dir(dir), []string{dir})
	if err == nil || !strings.Contains(err.Error(), "directory") {
		t.Errorf("want directory error, got %v", err)
	}
}

// TestReadAttachments_RelativeToCWD: bare basenames resolve under the cwd
// arg, matching how the MCP handler passes the repo root.
func TestReadAttachments_RelativeToCWD(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "report.har")
	if err := os.WriteFile(path, []byte("har-data"), 0o644); err != nil {
		t.Fatal(err)
	}
	out, names, err := readAttachments(dir, []string{"report.har"})
	if err != nil {
		t.Fatalf("readAttachments: %v", err)
	}
	if len(names) != 1 || names[0] != "report.har" {
		t.Errorf("names: got %v", names)
	}
	if string(out["report.har"]) != "har-data" {
		t.Errorf("bytes mismatch: %q", out["report.har"])
	}
}

// TestUniqueAttachmentName_NoExt: files without an extension still get a
// suffix on collision (e.g., `Makefile` → `Makefile-2`).
func TestUniqueAttachmentName_NoExt(t *testing.T) {
	taken := map[string][]byte{"Makefile": nil}
	if got := uniqueAttachmentName("Makefile", taken); got != "Makefile-2" {
		t.Errorf("got %q, want Makefile-2", got)
	}
}

func TestResolveBugRecipients_RoleAliasesUseConfiguredIdentities(t *testing.T) {
	res := &config.Resolved{
		Me:       "qa@tester",
		Partner:  "alex@frontend",
		Partners: []string{"user@backend", "alex@frontend"},
	}

	got, err := resolveBugRecipients([]string{"frontend"}, res)
	if err != nil {
		t.Fatalf("resolve frontend: %v", err)
	}
	if want := []string{"alex@frontend"}; !slices.Equal(got, want) {
		t.Fatalf("frontend resolved to %v, want %v", got, want)
	}

	got, err = resolveBugRecipients([]string{"both"}, res)
	if err != nil {
		t.Fatalf("resolve both: %v", err)
	}
	if want := []string{"user@backend", "alex@frontend"}; !slices.Equal(got, want) {
		t.Fatalf("both resolved to %v, want %v", got, want)
	}
}

func TestResolveBugRecipients_RejectsRoleResolvingToSelf(t *testing.T) {
	res := &config.Resolved{
		Me:       "gms@backend",
		Partner:  "alex@frontend",
		Partners: []string{"alex@frontend"},
	}

	_, err := resolveBugRecipients([]string{"backend"}, res)
	if err == nil || !strings.Contains(err.Error(), "yourself") {
		t.Fatalf("expected self-resolution error, got %v", err)
	}
}
