package main

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cc-collaboration/pkg/todoschema"
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

func TestTodoCreatePayloadNormalizesTeamFields(t *testing.T) {
	payload := todoCreatePayload(
		"  keep title padding  ",
		"  keep body padding  ",
		" project-1 ",
		" dev@x ",
		" Workspace ",
		" Repo ",
		" Sprint ",
		todoschema.PriorityHigh,
		todoschema.RecurrenceWeekly,
		nil,
	)
	if payload.ProjectID != "project-1" ||
		payload.AssigneeIdentity != "dev@x" ||
		payload.WorkspaceName != "Workspace" ||
		payload.RepoName != "Repo" ||
		payload.GroupName != "Sprint" {
		t.Fatalf("payload fields not normalized: %+v", payload)
	}
	if payload.Title != "  keep title padding  " || payload.BodyMD != "  keep body padding  " {
		t.Fatalf("title/body should be preserved: %+v", payload)
	}
}

func TestTodoListFilterNormalizesTeamFields(t *testing.T) {
	filter := todoListFilter(" project ", " project-1 ", " in_review ", " Sprint ", 25)
	if filter.Scope != "project" ||
		filter.ProjectID != "project-1" ||
		filter.Status != "in_review" ||
		filter.GroupName != "Sprint" ||
		filter.Limit != 25 {
		t.Fatalf("filter not normalized: %+v", filter)
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

func TestTodoStatusTargetNormalizesIDAndStatus(t *testing.T) {
	id, status, err := todoStatusTarget([]string{" td-1 ", " in_review "})
	if err != nil {
		t.Fatalf("todoStatusTarget returned error: %v", err)
	}
	if id != "td-1" || status != todoschema.StatusInReview {
		t.Fatalf("target = (%q, %q), want td-1/in_review", id, status)
	}
}

func TestTodoAssignRequiresIdentityOrUnassign(t *testing.T) {
	err := runTodoAssign(context.Background(), []string{"id123"})
	if err == nil || !strings.Contains(err.Error(), "identity required") {
		t.Fatalf("want identity-required error, got %v", err)
	}
}

func TestTodoAssignTargetNormalizesFields(t *testing.T) {
	id, identity, sessionID, sessionLabel, err := todoAssignTarget(
		[]string{" td-1 ", " dev@x "},
		" ts1 ",
		" codex ",
		false,
	)
	if err != nil {
		t.Fatalf("todoAssignTarget returned error: %v", err)
	}
	if id != "td-1" || identity != "dev@x" || sessionID != "ts1" || sessionLabel != "codex" {
		t.Fatalf("target = (%q, %q, %q, %q), want trimmed fields", id, identity, sessionID, sessionLabel)
	}
}

func TestTodoAssignTargetUnassignClearsFields(t *testing.T) {
	id, identity, sessionID, sessionLabel, err := todoAssignTarget(
		[]string{" td-1 ", " dev@x "},
		" ts1 ",
		" codex ",
		true,
	)
	if err != nil {
		t.Fatalf("todoAssignTarget returned error: %v", err)
	}
	if id != "td-1" || identity != "" || sessionID != "" || sessionLabel != "" {
		t.Fatalf("target = (%q, %q, %q, %q), want id with cleared assignment", id, identity, sessionID, sessionLabel)
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

func TestPrintTodoDetailUsesAssigneeDisplayName(t *testing.T) {
	out := captureStdout(t, func() {
		printTodoDetail(&todoschema.Todo{
			ID:                  "td1",
			OwnerIdentity:       "owner@x",
			Title:               "ship",
			Status:              todoschema.StatusTodo,
			Priority:            todoschema.PriorityNormal,
			AssigneeIdentity:    "dev@x",
			AssigneeDisplayName: "Dev",
		})
	})
	if !strings.Contains(out, "assignee  : Dev <dev@x>") {
		t.Fatalf("assignee display missing from detail:\n%s", out)
	}
}
