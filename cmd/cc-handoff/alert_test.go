package main

import (
	"context"
	"strings"
	"testing"

	"github.com/cc-collaboration/internal/config"
)

func TestAlertTeamTargetRequiresIdentity(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := config.SaveUser(&config.User{
		RelayURL: "https://relay.example.com",
		Token:    "tok",
	}); err != nil {
		t.Fatal(err)
	}

	err := runAlert(context.Background(), []string{
		"--team-project", "p1",
		"--project", "backend",
		"--message", "boom",
	})
	if err == nil || !strings.Contains(err.Error(), "identity missing") {
		t.Fatalf("runAlert error = %v, want missing identity", err)
	}
}

func TestAlertBlankTargetsAreRejectedBeforeConfig(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	err := runAlert(context.Background(), []string{
		"--to", "  ",
		"--team-project", "  ",
		"--org", "  ",
		"--member", "  ",
		"--project", " backend ",
		"--message", "boom",
	})
	if err == nil || !strings.Contains(err.Error(), "usage: cc-handoff alert") {
		t.Fatalf("runAlert error = %v, want usage", err)
	}
}
