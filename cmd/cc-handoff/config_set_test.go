package main

import (
	"context"
	"testing"
)

func TestConfigSet_FieldsAndPreserve(t *testing.T) {
	seedUser(t) // relay/token/identity + ws1(be,fe), ws2
	err := runConfigSet(context.Background(), []string{
		"--identity", "new@me", "--agent", "codex",
		"--workspace-root", "/ws", "--grade-command", "grade",
		"--linear-token", "lin_abc",
	})
	if err != nil {
		t.Fatalf("set: %v", err)
	}
	u := reload(t)
	if u.Identity != "new@me" || u.Agent != "codex" || u.WorkspaceRoot != "/ws" ||
		u.GradeCommand != "grade" || u.LinearPersonalToken != "lin_abc" {
		t.Fatalf("fields not set: %+v", u)
	}
	// fields NOT passed (relay/token) + workspaces must survive the round-trip.
	if u.RelayURL == "" || u.Token != "tok-keepme" {
		t.Fatalf("relay/token clobbered: %+v", u)
	}
	if len(u.Workspaces) != 2 {
		t.Fatalf("workspaces lost: %+v", u.Workspaces)
	}
}

func TestConfigSet_OnlyPassedChange(t *testing.T) {
	seedUser(t)
	if err := runConfigSet(context.Background(), []string{"--agent", "manual"}); err != nil {
		t.Fatal(err)
	}
	u := reload(t)
	if u.Agent != "manual" || u.Identity != "me@backend" {
		t.Fatalf("only-agent change failed: %+v", u)
	}
}

func TestConfigSet_InvalidAgent(t *testing.T) {
	seedUser(t)
	if err := runConfigSet(context.Background(), []string{"--agent", "gpt"}); err == nil {
		t.Fatal("expected invalid agent error")
	}
}

func TestConfigSet_GitHubToken(t *testing.T) {
	seedUser(t)
	if err := runConfigSet(context.Background(),
		[]string{"--github-token", "ghp_abc"}); err != nil {
		t.Fatal(err)
	}
	u := reload(t)
	if u.GitHubToken != "ghp_abc" {
		t.Fatalf("github token not set: %+v", u)
	}
	// unrelated secrets/fields preserved.
	if u.Token != "tok-keepme" || u.Identity != "me@backend" {
		t.Fatalf("other fields clobbered: %+v", u)
	}
}

func TestConfigSet_TerminalApp(t *testing.T) {
	seedUser(t)
	if err := runConfigSet(context.Background(),
		[]string{"--terminal-app", "ghostty"}); err != nil {
		t.Fatal(err)
	}
	u := reload(t)
	if u.TerminalApp != "ghostty" {
		t.Fatalf("terminal_app not set: %+v", u)
	}
	// unrelated fields preserved.
	if u.Token != "tok-keepme" || u.Identity != "me@backend" {
		t.Fatalf("other fields clobbered: %+v", u)
	}
}

func TestConfigSet_PublishSessions(t *testing.T) {
	seedUser(t)
	if err := runConfigSet(context.Background(),
		[]string{"--publish-sessions=true"}); err != nil {
		t.Fatal(err)
	}
	u := reload(t)
	if !u.PublishSessions {
		t.Fatalf("publish_sessions not set: %+v", u)
	}

	if err := runConfigSet(context.Background(),
		[]string{"--publish-sessions=false"}); err != nil {
		t.Fatal(err)
	}
	u = reload(t)
	if u.PublishSessions {
		t.Fatalf("publish_sessions not cleared: %+v", u)
	}
}

func TestConfigSet_InvalidTerminalApp(t *testing.T) {
	seedUser(t)
	if err := runConfigSet(context.Background(),
		[]string{"--terminal-app", "kitty"}); err == nil {
		t.Fatal("expected invalid terminal-app error")
	}
}

func TestWorkspaceSet(t *testing.T) {
	seedUser(t)
	if err := runWorkspaceSet(context.Background(),
		[]string{"ws1", "--pre-launch", "nvm use", "--agent", "codex"}); err != nil {
		t.Fatalf("ws set: %v", err)
	}
	u := reload(t)
	ws := u.Workspaces[0]
	if ws.PreLaunch != "nvm use" || ws.Agent != "codex" {
		t.Fatalf("ws fields: %+v", ws)
	}
	if len(ws.Projects) != 2 {
		t.Fatalf("projects lost: %+v", ws.Projects)
	}
}
