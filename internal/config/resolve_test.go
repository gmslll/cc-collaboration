package config

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestResolve_NoPartnerNeeded pins team-project routing: repo config can omit
// the legacy point-to-point partner.
func TestResolve_NoPartnerNeeded(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := SaveUser(&User{RelayURL: "http://relay", Token: "tok", Identity: "me@x", Agent: "claude"}); err != nil {
		t.Fatal(err)
	}
	// A repo WITH a .cc-handoff.toml but NO partner.
	repo := t.TempDir()
	if err := SaveRepo(RepoConfigPath(repo), &Repo{Identity: Identity{Me: "me@x"}}); err != nil {
		t.Fatal(err)
	}

	full, err := Resolve(repo)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if full.Partner != "" || len(full.Partners) != 0 {
		t.Fatalf("legacy partner fields = %q/%v, want empty", full.Partner, full.Partners)
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
