package main

import (
	"context"
	"testing"

	"github.com/cc-collaboration/internal/config"
)

func seedUser(t *testing.T) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	u := &config.User{
		RelayURL: "https://relay.example.com",
		Token:    "tok-keepme",
		Identity: "me@backend",
		Workspaces: []config.Workspace{
			{Name: "ws1", Projects: []config.Project{
				{Name: "be", Path: "/code/be"},
				{Name: "fe", Path: "/code/fe"},
			}},
			{Name: "ws2"},
		},
	}
	if _, err := config.SaveUser(u); err != nil {
		t.Fatalf("seed: %v", err)
	}
}

func reload(t *testing.T) *config.User {
	t.Helper()
	u, _, err := config.LoadUser()
	if err != nil || u == nil {
		t.Fatalf("reload: %v", err)
	}
	return u
}

func TestWorkspaceRemove_Workspace(t *testing.T) {
	seedUser(t)
	if err := runWorkspaceRemove(context.Background(), []string{"ws1"}); err != nil {
		t.Fatalf("remove: %v", err)
	}
	u := reload(t)
	if len(u.Workspaces) != 1 || u.Workspaces[0].Name != "ws2" {
		t.Fatalf("ws1 not removed: %+v", u.Workspaces)
	}
	// other fields must survive the round-trip.
	if u.RelayURL == "" || u.Token != "tok-keepme" || u.Identity == "" {
		t.Fatalf("config fields clobbered: %+v", u)
	}
}

func TestWorkspaceRemove_Project(t *testing.T) {
	seedUser(t)
	if err := runWorkspaceRemove(context.Background(), []string{"ws1", "be"}); err != nil {
		t.Fatalf("remove project: %v", err)
	}
	u := reload(t)
	ws := u.Workspaces[0]
	if len(ws.Projects) != 1 || ws.Projects[0].Name != "fe" {
		t.Fatalf("project be not removed: %+v", ws.Projects)
	}
}

func TestWorkspaceRemove_Errors(t *testing.T) {
	seedUser(t)
	if err := runWorkspaceRemove(context.Background(), []string{"nope"}); err == nil {
		t.Fatal("expected error for missing workspace")
	}
	if err := runWorkspaceRemove(context.Background(), []string{"ws1", "nope"}); err == nil {
		t.Fatal("expected error for missing project")
	}
}
