package handoff

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cc-collaboration/pkg/handoffschema"
)

// gitInit makes the temp dir a real git repo so git.CollectRepoMeta doesn't
// blow up. We use a single commit on a deterministic branch so the test
// doesn't depend on the host's git config defaults.
func gitInit(t *testing.T, dir string) {
	t.Helper()
	cmds := [][]string{
		{"git", "init", "--initial-branch=main", "--quiet"},
		{"git", "config", "user.email", "test@example.com"},
		{"git", "config", "user.name", "test"},
		{"git", "commit", "--allow-empty", "-m", "init", "--quiet"},
	}
	for _, c := range cmds {
		cmd := exec.Command(c[0], c[1:]...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v: %v: %s", c, err, out)
		}
	}
}

// TestBuild_ExtraAttachments confirms caller-supplied files ride along on the
// Package alongside the auto-derived swagger snapshot. Both must appear in
// pkg.Attachments with correct sha256.
func TestBuild_ExtraAttachments(t *testing.T) {
	dir := t.TempDir()
	gitInit(t, dir)

	inboxDir := filepath.Join(dir, ".cc-handoff", "inbox")
	if err := os.MkdirAll(inboxDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(SummaryDraftPath(inboxDir), []byte("## Bug\nbroken thing\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	imageBytes := []byte("PNG-like-bytes")
	extras := map[string][]byte{"screenshot.png": imageBytes}

	pkg, attachments, err := Build(context.Background(), BuildOptions{
		RepoRoot:         dir,
		RepoName:         "demo",
		Sender:           "tester",
		Recipients:       []string{"backend"},
		Kind:             handoffschema.KindBug,
		InboxDir:         inboxDir,
		ExtraAttachments: extras,
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if got, want := len(pkg.Attachments), 1; got != want {
		t.Fatalf("pkg.Attachments: got %d, want %d (%+v)", got, want, pkg.Attachments)
	}
	a := pkg.Attachments[0]
	if a.Name != "screenshot.png" {
		t.Errorf("attachment name: got %q, want screenshot.png", a.Name)
	}
	wantSum := sha256.Sum256(imageBytes)
	if a.SHA256 != hex.EncodeToString(wantSum[:]) {
		t.Errorf("sha256: got %s, want %s", a.SHA256, hex.EncodeToString(wantSum[:]))
	}
	if a.Size != len(imageBytes) {
		t.Errorf("size: got %d, want %d", a.Size, len(imageBytes))
	}
	if got, ok := attachments["screenshot.png"]; !ok || string(got) != string(imageBytes) {
		t.Errorf("attachments[screenshot.png] not returned correctly: ok=%v got=%q", ok, string(got))
	}
}

// TestBuild_Bug_NoGitRepo confirms a tester can file a bug from a plain
// directory that isn't a git repo: repo meta is best-effort for the bug/request
// flow, so Build succeeds with empty branch/HEAD instead of erroring out on
// `git rev-parse HEAD`. Note the deliberate absence of gitInit here.
func TestBuild_Bug_NoGitRepo(t *testing.T) {
	dir := t.TempDir() // intentionally NOT a git repo

	inboxDir := filepath.Join(dir, ".cc-handoff", "inbox")
	if err := os.MkdirAll(inboxDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(SummaryDraftPath(inboxDir), []byte("## Bug\nbroken thing\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	pkg, _, err := Build(context.Background(), BuildOptions{
		RepoRoot:   dir,
		RepoName:   "demo",
		Sender:     "tester",
		Recipients: []string{"backend"},
		Kind:       handoffschema.KindBug,
		InboxDir:   inboxDir,
	})
	if err != nil {
		t.Fatalf("Build in non-git dir should succeed for a bug, got: %v", err)
	}
	if pkg.Repo.Branch != "" || pkg.Repo.HeadSHA != "" {
		t.Fatalf("expected empty repo meta without git, got branch=%q head=%q", pkg.Repo.Branch, pkg.Repo.HeadSHA)
	}
}

// TestBuild_ExtraAttachment_RejectsSwaggerName: the reserved swagger.yaml
// slot is owned by Build itself; user-supplied attachments with that name
// must be rejected so they can't shadow the snapshot.
func TestBuild_ExtraAttachment_RejectsSwaggerName(t *testing.T) {
	dir := t.TempDir()
	gitInit(t, dir)

	inboxDir := filepath.Join(dir, ".cc-handoff", "inbox")
	if err := os.MkdirAll(inboxDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(SummaryDraftPath(inboxDir), []byte("body\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	_, _, err := Build(context.Background(), BuildOptions{
		RepoRoot:         dir,
		RepoName:         "demo",
		Sender:           "tester",
		Recipients:       []string{"backend"},
		Kind:             handoffschema.KindBug,
		InboxDir:         inboxDir,
		ExtraAttachments: map[string][]byte{SwaggerSnapshotName: []byte("evil")},
	})
	if err == nil {
		t.Fatal("expected error for reserved name, got nil")
	}
	if !strings.Contains(err.Error(), "reserved") {
		t.Errorf("error should mention reserved: %v", err)
	}
}
