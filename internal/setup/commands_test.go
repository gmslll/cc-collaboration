package setup

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCopyCommands_FreshDir(t *testing.T) {
	dir := t.TempDir()
	res, err := CopyCommands(dir, "0.1.1", refusePrompt(t), io.Discard)
	if err != nil {
		t.Fatalf("CopyCommands: %v", err)
	}
	if len(res.Written) != len(CommandFiles) {
		t.Fatalf("want %d written, got %v", len(CommandFiles), res.Written)
	}
	for _, name := range CommandFiles {
		got, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		if !strings.Contains(string(got), "cc-handoff-version: 0.1.1") {
			t.Errorf("%s missing version stamp:\n%s", name, got)
		}
	}
}

func TestCopyCodexSkills_FreshDir(t *testing.T) {
	dir := t.TempDir()
	res, err := CopyCodexSkills(dir, "0.1.1", refusePrompt(t), io.Discard)
	if err != nil {
		t.Fatalf("CopyCodexSkills: %v", err)
	}
	if len(res.Written) != len(CommandFiles) {
		t.Fatalf("want %d written, got %v", len(CommandFiles), res.Written)
	}
	for _, name := range CommandFiles {
		skillName := strings.TrimSuffix(name, ".md")
		got, err := os.ReadFile(filepath.Join(dir, "cc-handoff-"+skillName, "SKILL.md"))
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		if !strings.Contains(string(got), "name: cc-handoff-"+skillName) {
			t.Errorf("%s missing skill name:\n%s", name, got)
		}
		if strings.Contains(string(got), "---\ndescription:") {
			t.Errorf("%s still contains command-style frontmatter:\n%s", name, got)
		}
		if !strings.Contains(string(got), "cc-handoff-version: 0.1.1") {
			t.Errorf("%s missing version stamp:\n%s", name, got)
		}
	}
}

func TestPickupCommandDocumentsTeamTargeting(t *testing.T) {
	got, err := os.ReadFile(filepath.Join("templates", "commands", "pickup.md"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(got)
	for _, want := range []string{
		"delivery_target",
		"project_id",
		"org_id",
		"member",
		"团队包里的 `delivery_target` 是更强约束",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("pickup command missing team targeting guidance %q:\n%s", want, text)
		}
	}
}

func TestCopyCodexSkills_SameVersionSkips(t *testing.T) {
	dir := t.TempDir()
	if _, err := CopyCodexSkills(dir, "0.1.1", nil, io.Discard); err != nil {
		t.Fatalf("first copy: %v", err)
	}
	res, err := CopyCodexSkills(dir, "0.1.1", refusePrompt(t), io.Discard)
	if err != nil {
		t.Fatalf("second copy: %v", err)
	}
	if len(res.Written) != 0 {
		t.Errorf("expected no writes on idempotent run, got %v", res.Written)
	}
	if len(res.Skipped) != len(CommandFiles) {
		t.Errorf("expected all skipped, got %v", res.Skipped)
	}
}

func TestCopyCodexSkills_NonInteractiveRefreshesOlderSkills(t *testing.T) {
	dir := t.TempDir()
	if _, err := CopyCodexSkills(dir, "0.1.0", nil, io.Discard); err != nil {
		t.Fatalf("seed: %v", err)
	}
	res, err := CopyCodexSkills(dir, "0.1.1", nil, io.Discard)
	if err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if len(res.Written) != len(CommandFiles) {
		t.Fatalf("expected all older skills refreshed, written=%v skipped=%v", res.Written, res.Skipped)
	}
	got, err := os.ReadFile(filepath.Join(dir, "cc-handoff-handoff", "SKILL.md"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(got), "cc-handoff-version: 0.1.1") {
		t.Fatalf("skill was not refreshed:\n%s", got)
	}
}

func TestCopyCodexSkills_RemovesStampedLegacySingleSkill(t *testing.T) {
	dir := t.TempDir()
	legacy := filepath.Join(dir, "cc-handoff")
	if err := os.MkdirAll(filepath.Join(legacy, "references"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacy, "SKILL.md"), []byte("old\n<!-- cc-handoff-version: 0.1.1 -->\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacy, "references", "handoff.md"), []byte("stale\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := CopyCodexSkills(dir, "0.1.2", nil, io.Discard); err != nil {
		t.Fatalf("CopyCodexSkills: %v", err)
	}
	if _, err := os.Stat(legacy); !os.IsNotExist(err) {
		t.Fatalf("legacy skill should be removed, stat err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "cc-handoff-handoff", "SKILL.md")); err != nil {
		t.Fatalf("new handoff skill missing: %v", err)
	}
}

func TestCopyCodexSkills_KeepsUnstampedLegacySingleSkill(t *testing.T) {
	dir := t.TempDir()
	legacy := filepath.Join(dir, "cc-handoff")
	if err := os.MkdirAll(legacy, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacy, "SKILL.md"), []byte("user edited\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := CopyCodexSkills(dir, "0.1.2", nil, io.Discard); err != nil {
		t.Fatalf("CopyCodexSkills: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(legacy, "SKILL.md"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "user edited\n" {
		t.Fatalf("unstamped legacy skill should be left untouched, got %q", got)
	}
}

func contains(xs []string, want string) bool {
	for _, x := range xs {
		if x == want {
			return true
		}
	}
	return false
}

func TestCopyCommands_SameVersionSkips(t *testing.T) {
	dir := t.TempDir()
	if _, err := CopyCommands(dir, "0.1.1", nil, io.Discard); err != nil {
		t.Fatalf("first copy: %v", err)
	}
	res, err := CopyCommands(dir, "0.1.1", refusePrompt(t), io.Discard)
	if err != nil {
		t.Fatalf("second copy: %v", err)
	}
	if len(res.Written) != 0 {
		t.Errorf("expected no writes on idempotent run, got %v", res.Written)
	}
	if len(res.Skipped) != len(CommandFiles) {
		t.Errorf("expected all skipped, got %v", res.Skipped)
	}
}

func TestCopyCommands_NewerOnDiskWarns(t *testing.T) {
	dir := t.TempDir()
	if _, err := CopyCommands(dir, "0.2.0", nil, io.Discard); err != nil {
		t.Fatalf("seed: %v", err)
	}
	var buf bytes.Buffer
	res, err := CopyCommands(dir, "0.1.1", refusePrompt(t), &buf)
	if err != nil {
		t.Fatalf("CopyCommands: %v", err)
	}
	if len(res.Written) != 0 {
		t.Errorf("should not overwrite newer files, wrote %v", res.Written)
	}
	if !strings.Contains(buf.String(), "newer than binary") {
		t.Errorf("expected warning, got %q", buf.String())
	}
}

func TestCopyCommands_OlderTargetPromptsOverwrite(t *testing.T) {
	dir := t.TempDir()
	if _, err := CopyCommands(dir, "0.0.9", nil, io.Discard); err != nil {
		t.Fatalf("seed: %v", err)
	}
	calls := map[string]ConflictReason{}
	prompt := func(name string, reason ConflictReason, existing, _ string) (rune, error) {
		calls[name] = reason
		if existing != "0.0.9" {
			t.Errorf("%s: expected existing 0.0.9, got %q", name, existing)
		}
		return 'o', nil
	}
	res, err := CopyCommands(dir, "0.1.1", prompt, io.Discard)
	if err != nil {
		t.Fatalf("CopyCommands: %v", err)
	}
	if len(res.Written) != len(CommandFiles) {
		t.Errorf("expected all overwritten, got %v / %v", res.Written, res.Skipped)
	}
	for _, name := range CommandFiles {
		if calls[name] != ConflictOlder {
			t.Errorf("%s: expected ConflictOlder, got %v", name, calls[name])
		}
	}
}

func TestCopyCommands_UnstampedTargetPromptsBackup(t *testing.T) {
	dir := t.TempDir()
	for _, name := range CommandFiles {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("hand-edited content\n"), 0o644); err != nil {
			t.Fatalf("seed %s: %v", name, err)
		}
	}
	prompt := func(name string, reason ConflictReason, existing, _ string) (rune, error) {
		if reason != ConflictUnstamped {
			t.Errorf("%s: expected ConflictUnstamped, got %v", name, reason)
		}
		if existing != "" {
			t.Errorf("%s: expected empty existing version, got %q", name, existing)
		}
		return 'b', nil
	}
	res, err := CopyCommands(dir, "0.1.1", prompt, io.Discard)
	if err != nil {
		t.Fatalf("CopyCommands: %v", err)
	}
	if len(res.BackedUp) != len(CommandFiles) {
		t.Errorf("expected all backed up, got %v", res.BackedUp)
	}
	for orig, bak := range res.BackedUp {
		got, err := os.ReadFile(bak)
		if err != nil {
			t.Fatalf("read backup %s: %v", bak, err)
		}
		if string(got) != "hand-edited content\n" {
			t.Errorf("backup %s does not preserve original: %q", bak, got)
		}
		if _, err := os.Stat(orig); err != nil {
			t.Errorf("original %s missing after overwrite: %v", orig, err)
		}
	}
}

func TestCopyCommands_NilPromptSkipsConflicts(t *testing.T) {
	dir := t.TempDir()
	if _, err := CopyCommands(dir, "0.0.9", nil, io.Discard); err != nil {
		t.Fatalf("seed: %v", err)
	}
	res, err := CopyCommands(dir, "0.1.1", nil, io.Discard)
	if err != nil {
		t.Fatalf("CopyCommands: %v", err)
	}
	if len(res.Skipped) != len(CommandFiles) {
		t.Errorf("nil prompt should skip all conflicts, got written=%v skipped=%v", res.Written, res.Skipped)
	}
}

func TestStampAndExtract(t *testing.T) {
	got := stampVersion([]byte("hello\n"), "0.1.1")
	if !strings.HasSuffix(string(got), "<!-- cc-handoff-version: 0.1.1 -->\n") {
		t.Errorf("stamp at tail: %q", got)
	}
	if v := extractVersion(got); v != "0.1.1" {
		t.Errorf("extractVersion = %q, want 0.1.1", v)
	}
	bumped := stampVersion(got, "0.2.0")
	if v := extractVersion(bumped); v != "0.2.0" {
		t.Errorf("re-stamp lost version: got %q, want 0.2.0", v)
	}
	if strings.Count(string(bumped), versionMarker) != 1 {
		t.Errorf("expected single marker after re-stamp, got %d:\n%s",
			strings.Count(string(bumped), versionMarker), bumped)
	}
}

func TestCompareSemver(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"0.1.1", "0.1.1", 0},
		{"0.1.1", "0.2.0", -1},
		{"1.0.0", "0.9.9", 1},
		{"v0.1.1", "0.1.1", 0},
		{"dev", "0.1.1", -1},
		{"0.1.1-rc1", "0.1.1", 0},
	}
	for _, c := range cases {
		if got := compareSemver(c.a, c.b); got != c.want {
			t.Errorf("compareSemver(%q,%q) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

func refusePrompt(t *testing.T) PromptFunc {
	t.Helper()
	return func(name string, _ ConflictReason, _, _ string) (rune, error) {
		t.Errorf("prompt called unexpectedly for %s", name)
		return 's', nil
	}
}
