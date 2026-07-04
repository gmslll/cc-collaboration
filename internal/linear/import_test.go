package linear

import (
	"testing"

	"github.com/cc-collaboration/pkg/todoschema"
)

func TestMapIssueStatus(t *testing.T) {
	cases := map[string]todoschema.Status{
		"backlog":     todoschema.StatusBacklog,
		"unstarted":   todoschema.StatusTodo,
		"started":     todoschema.StatusInProgress,
		"completed":   todoschema.StatusDone,
		"canceled":    todoschema.StatusCanceled,
		"":            todoschema.StatusTriage, // unrecognized -> triage, not an error
		"made-up-typ": todoschema.StatusTriage,
	}
	for in, want := range cases {
		if got := mapIssueStatus(in); got != want {
			t.Errorf("mapIssueStatus(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestMapIssuePriority(t *testing.T) {
	// Linear's own scale is 0=no priority, 1=urgent, 2=high, 3=medium,
	// 4=low — urgent is the *lowest* number, so a naive "compress 0-4
	// ascending" mapping would be wrong. Assert the real semantics survive.
	cases := map[int]todoschema.Priority{
		0: todoschema.PriorityNormal, // no priority
		1: todoschema.PriorityHigh,   // urgent
		2: todoschema.PriorityHigh,   // high
		3: todoschema.PriorityNormal, // medium
		4: todoschema.PriorityLow,    // low
		9: todoschema.PriorityNormal, // unrecognized -> normal, not an error
	}
	for in, want := range cases {
		if got := mapIssuePriority(in); got != want {
			t.Errorf("mapIssuePriority(%d) = %q, want %q", in, got, want)
		}
	}
}

func TestComposeBodyMD(t *testing.T) {
	if got, want := composeBodyMD(nil, "hello"), "hello"; got != want {
		t.Errorf("no labels: got %q, want %q", got, want)
	}
	if got, want := composeBodyMD([]string{}, "hello"), "hello"; got != want {
		t.Errorf("empty labels: got %q, want %q", got, want)
	}
	got := composeBodyMD([]string{"bug", "urgent"}, "hello")
	want := "🏷 bug, urgent\n\nhello"
	if got != want {
		t.Errorf("with labels: got %q, want %q", got, want)
	}
}

func TestMatchAssigneeIdentity(t *testing.T) {
	candidates := []string{"me@company.com", "Alex@Company.com", "backend@team"}

	if got := matchAssigneeIdentity(candidates, ""); got != "" {
		t.Errorf("empty email: got %q, want \"\"", got)
	}
	if got := matchAssigneeIdentity(candidates, "nobody@elsewhere.com"); got != "" {
		t.Errorf("no match: got %q, want \"\"", got)
	}
	if got, want := matchAssigneeIdentity(candidates, "me@company.com"), "me@company.com"; got != want {
		t.Errorf("exact match: got %q, want %q", got, want)
	}
	// Case-insensitive, and returns the candidate's own casing (not the
	// input email's).
	if got, want := matchAssigneeIdentity(candidates, "alex@company.com"), "Alex@Company.com"; got != want {
		t.Errorf("case-insensitive match: got %q, want %q", got, want)
	}
}

func TestLooksLikeUUID(t *testing.T) {
	valid := "0b643943-60c1-4df5-9f56-2c63c5268767"
	if !looksLikeUUID(valid) {
		t.Fatalf("looksLikeUUID(%q) = false, want true", valid)
	}
	invalid := "b643943-60c1-4df5-9f56-2c63c5268767"
	if looksLikeUUID(invalid) {
		t.Fatalf("looksLikeUUID(%q) = true, want false", invalid)
	}
}

func TestIssueAssets(t *testing.T) {
	iss := Issue{
		Description: "body ![a](https://example.com/a.png) [doc](https://example.com/doc.pdf)",
		Assets: []IssueAsset{
			{Title: "external", URL: "https://example.com/a.png"},
			{Title: "trace.log", URL: "https://example.com/trace.log"},
		},
		Comments: []string{"comment ![b](https://example.com/b.jpg)"},
	}
	got := issueAssets(iss)
	if len(got) != 4 {
		t.Fatalf("issueAssets len = %d, want 4: %+v", len(got), got)
	}
	if got[0].URL != "https://example.com/a.png" || got[1].URL != "https://example.com/trace.log" {
		t.Fatalf("explicit attachments should lead and dedupe: %+v", got)
	}
}

func TestUniqueAssetName(t *testing.T) {
	used := map[string]bool{}
	if got := uniqueAssetName("shot.png", used); got != "shot.png" {
		t.Fatalf("first uniqueAssetName = %q", got)
	}
	if got := uniqueAssetName("shot.png", used); got != "shot-2.png" {
		t.Fatalf("second uniqueAssetName = %q", got)
	}
	if got := uniqueAssetName("shot.png", used); got != "shot-3.png" {
		t.Fatalf("third uniqueAssetName = %q", got)
	}
}
