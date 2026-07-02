package main

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
)

// TestTodoHelp: `todo`, `todo -h`, `todo --help`, `todo help` all print the
// subcommand summary without touching the relay (no .cc-handoff.toml needed).
func TestTodoHelp(t *testing.T) {
	for _, args := range [][]string{{}, {"--help"}, {"-h"}, {"help"}} {
		var err error
		out := captureStdout(t, func() { err = runTodo(context.Background(), args) })
		if err != nil {
			t.Fatalf("runTodo(%v): %v", args, err)
		}
		for _, want := range []string{"create", "list", "get", "status", "assign", "comment"} {
			if !strings.Contains(out, want) {
				t.Fatalf("help for %v missing %q:\n%s", args, want, out)
			}
		}
	}
}

func TestTodoUnknownSubcommand(t *testing.T) {
	err := runTodo(context.Background(), []string{"bogus"})
	if err == nil || !strings.Contains(err.Error(), "unknown todo subcommand") {
		t.Fatalf("want unknown-subcommand error, got %v", err)
	}
}

// TestTodoCreateValidation covers the input-validation paths that must fail
// before any relay call is attempted (no .cc-handoff.toml in play), so the
// test needs no network and no config.
func TestTodoCreateValidation(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"missing title", nil, "usage: cc-handoff todo create"},
		{"bad priority", []string{"Title", "--priority", "urgent"}, "invalid --priority"},
		{"bad recurrence", []string{"Title", "--recurrence", "hourly"}, "invalid --recurrence"},
		{"bad due", []string{"Title", "--due", "not-a-date"}, "invalid --due"},
		{"missing attachment", []string{"Title", "--attach", "/no/such/file-xyz"}, "read attachment"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := runTodoCreate(context.Background(), tc.args)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("want error containing %q, got %v", tc.want, err)
			}
		})
	}
}

// TestTodoCreateAttachmentReadHappensBeforeNetwork checks that a bad --attach
// path fails fast (naming the path) before any relay call would be attempted.
func TestTodoCreateAttachmentReadHappensBeforeNetwork(t *testing.T) {
	dir := t.TempDir()
	missing := filepath.Join(dir, "does-not-exist.png")
	err := runTodoCreate(context.Background(), []string{"Title", "--attach", missing})
	if err == nil || !strings.Contains(err.Error(), missing) {
		t.Fatalf("want error naming missing attachment path, got %v", err)
	}
}

func TestTodoStatusValidation(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"missing args", []string{"id123"}, "usage: cc-handoff todo status"},
		{"bad status", []string{"id123", "urgent"}, "invalid status"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := runTodoStatus(context.Background(), tc.args)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("want error containing %q, got %v", tc.want, err)
			}
		})
	}
}

func TestTodoAssignRequiresIdentityOrUnassign(t *testing.T) {
	err := runTodoAssign(context.Background(), []string{"id123"})
	if err == nil || !strings.Contains(err.Error(), "identity required") {
		t.Fatalf("want identity-required error, got %v", err)
	}
}

func TestTodoAssignMissingID(t *testing.T) {
	err := runTodoAssign(context.Background(), nil)
	if err == nil || !strings.Contains(err.Error(), "usage: cc-handoff todo assign") {
		t.Fatalf("want usage error, got %v", err)
	}
}

func TestTodoCommentRequiresBodyOrList(t *testing.T) {
	err := runTodoComment(context.Background(), []string{"id123"})
	if err == nil || !strings.Contains(err.Error(), "comment body required") {
		t.Fatalf("want body-required error, got %v", err)
	}
}

func TestTodoCommentMissingID(t *testing.T) {
	err := runTodoComment(context.Background(), nil)
	if err == nil || !strings.Contains(err.Error(), "usage: cc-handoff todo comment") {
		t.Fatalf("want usage error, got %v", err)
	}
}

func TestTodoGetMissingID(t *testing.T) {
	err := runTodoGet(context.Background(), nil)
	if err == nil || !strings.Contains(err.Error(), "usage: cc-handoff todo get") {
		t.Fatalf("want usage error, got %v", err)
	}
}
