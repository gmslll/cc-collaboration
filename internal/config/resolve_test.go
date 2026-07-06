package config

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestResolveRelay_NoPartnerNeeded pins the capsule/plaza fix: ResolveRelay
// succeeds with only a user-level relay connection, even when the repo config
// has no partner — while strict Resolve still rejects that.
func TestResolveRelay_NoPartnerNeeded(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := SaveUser(&User{RelayURL: "http://relay", Token: "tok", Identity: "me@x", Agent: "claude"}); err != nil {
		t.Fatal(err)
	}
	// A repo WITH a .cc-handoff.toml but NO partner.
	repo := t.TempDir()
	if err := SaveRepo(RepoConfigPath(repo), &Repo{Identity: Identity{Me: "me@x"}}); err != nil {
		t.Fatal(err)
	}

	if _, err := Resolve(repo); err == nil || !strings.Contains(err.Error(), "identity.partner") {
		t.Errorf("strict Resolve should reject the missing partner, got %v", err)
	}
	res, err := ResolveRelay(repo)
	if err != nil {
		t.Fatalf("ResolveRelay: %v", err)
	}
	if res.RelayURL != "http://relay" || res.Token != "tok" || res.Me != "me@x" {
		t.Errorf("relay connection mismatch: %+v", res)
	}
}

// TestResolveRelay_NoRepoConfig confirms ResolveRelay tolerates a directory with
// no .cc-handoff.toml at all, degrading RepoName to the directory name and Me to
// the user identity.
func TestResolveRelay_NoRepoConfig(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := SaveUser(&User{RelayURL: "http://relay", Token: "tok", Identity: "me@x", Agent: "claude"}); err != nil {
		t.Fatal(err)
	}
	bare := t.TempDir() // no .cc-handoff.toml, no .git
	res, err := ResolveRelay(bare)
	if err != nil {
		t.Fatalf("ResolveRelay (no repo config): %v", err)
	}
	if want := filepath.Base(RepoRoot(bare)); res.RepoName != want {
		t.Errorf("RepoName = %q, want dir-name fallback %q", res.RepoName, want)
	}
	if res.Me != "me@x" {
		t.Errorf("Me = %q, want user identity fallback", res.Me)
	}
}

// TestResolveRelay_StillRequiresRelayConnection confirms the relay-connection
// check is kept (only the partner/repo requirements are relaxed).
func TestResolveRelay_StillRequiresRelayConnection(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	// User config present but token missing.
	if _, err := SaveUser(&User{RelayURL: "http://relay", Identity: "me@x", Agent: "claude"}); err != nil {
		t.Fatal(err)
	}
	if _, err := ResolveRelay(t.TempDir()); err == nil || !strings.Contains(err.Error(), "relay_url/token/identity") {
		t.Errorf("ResolveRelay should still require the relay connection, got %v", err)
	}
}
