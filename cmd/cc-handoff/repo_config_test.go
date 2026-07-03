package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/cc-collaboration/internal/config"
)

// goldenRepoToml is a full-featured .cc-handoff.toml in the standard-TOML shape
// the Flutter GUI writes (array-of-tables + nested integrations.linear). This
// guards the Go side of the toml.dart ↔ BurntSushi interop: LoadRepo must parse
// this structure. (The Dart side — that toml.dart actually emits this shape —
// is covered by the RepoConfig save→load round-trip test in app/test.)
const goldenRepoToml = `
[identity]
me = "me@backend"
partner = "alex@frontend"
partners = ["a@x", "b@y"]

[paths]
base = "origin/main"
swagger = "docs/swagger.yaml"
repo = "backend"

[[partner_mapping.rule]]
when_path_matches = "^internal/(?P<domain>[^/]+)/handler/"
suggest_edit = ["lib/api/{domain}.ts"]
suggest_create_if_missing = true

[triggers]
auto_launch = true
auto_launch_normal = true
wake_on_comment = true
terminal_app = "iterm2"
pre_launch = "nvm use 18"
ack_on_launch = "on_launch"

[inbox]
dir = ".cc-handoff/inbox"

[integrations.linear]
enabled = true
team_key = "ENG"
project_id = "proj-123"
default_labels = ["handoff"]
sync_on_submit = true

  [integrations.linear.notifications]
  poll_interval = "5m"
  types = ["mention"]
`

func TestLoadRepo_FullFeatured(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(dir, ".cc-handoff.toml"), []byte(goldenRepoToml), 0o644); err != nil {
		t.Fatal(err)
	}

	r, _, err := config.LoadRepo(dir)
	if err != nil {
		t.Fatalf("LoadRepo: %v", err)
	}
	if r == nil {
		t.Fatal("nil repo")
	}
	if r.Identity.Partner != "alex@frontend" || len(r.Identity.Partners) != 2 {
		t.Fatalf("identity: %+v", r.Identity)
	}
	if r.Paths.Base != "origin/main" || r.Paths.Swagger != "docs/swagger.yaml" {
		t.Fatalf("paths: %+v", r.Paths)
	}
	if len(r.PartnerMapping.Rules) != 1 ||
		r.PartnerMapping.Rules[0].WhenPathMatches == "" ||
		!r.PartnerMapping.Rules[0].SuggestCreateIfMissing {
		t.Fatalf("rules: %+v", r.PartnerMapping.Rules)
	}
	if !r.Triggers.AutoLaunch || r.Triggers.TerminalApp != "iterm2" ||
		r.Triggers.PreLaunch != "nvm use 18" {
		t.Fatalf("triggers: %+v", r.Triggers)
	}
	if !r.Integrations.Linear.Enabled || r.Integrations.Linear.TeamKey != "ENG" ||
		r.Integrations.Linear.ProjectID != "proj-123" {
		t.Fatalf("linear: %+v", r.Integrations.Linear)
	}
	if r.Integrations.Linear.Notifications.PollInterval != "5m" {
		t.Fatalf("notif: %+v", r.Integrations.Linear.Notifications)
	}
}
