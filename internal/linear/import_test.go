package linear

import (
	"testing"

	"github.com/cc-collaboration/pkg/todoschema"
)

func TestMapIssueStatus(t *testing.T) {
	// stateName now varies independently of stateType (Linear's type enum has
	// no "review" category, so a custom "In Review" state is still
	// type=started and can only be told apart from "In Progress" by name), so
	// this is a struct table rather than a plain type->status map.
	cases := []struct {
		stateType string
		stateName string
		want      todoschema.Status
	}{
		// The started branch disambiguates on name. The In Progress case is
		// the most important regression guard: the common path must not get
		// swept into StatusInReview by the new name check.
		{"started", "In Progress", todoschema.StatusInProgress},
		{"started", "In Review", todoschema.StatusInReview},   // the reported bug
		{"started", "Code Review", todoschema.StatusInReview}, // adjacent naming
		{"started", "", todoschema.StatusInProgress},          // no name -> stays in progress
		// name only matters for started: a "review"-ish name on any other
		// type must be ignored, so backlog stays backlog even with "In Review".
		{"backlog", "In Review", todoschema.StatusBacklog},
		{"backlog", "Backlog", todoschema.StatusBacklog},
		{"unstarted", "Todo", todoschema.StatusTodo},
		{"completed", "Done", todoschema.StatusDone},
		{"canceled", "Canceled", todoschema.StatusCanceled},
		{"", "", todoschema.StatusTriage},            // unrecognized -> triage, not an error
		{"made-up-typ", "", todoschema.StatusTriage}, // unrecognized -> triage
	}
	for _, c := range cases {
		if got := mapIssueStatus(c.stateType, c.stateName); got != c.want {
			t.Errorf("mapIssueStatus(%q, %q) = %q, want %q", c.stateType, c.stateName, got, c.want)
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

func TestRewriteImageRefs(t *testing.T) {
	url1 := "https://uploads.linear.app/w/i/79d19f5f-b331-4131"
	url2 := "https://uploads.linear.app/w/i/074ae41f-9ce1-4190"
	renamed := map[string]string{
		url1: "79d19f5f-b331-4131.png",
		url2: "074ae41f-9ce1-4190.png",
	}
	body := "intro\n![字段配置](" + url1 + ")\ntext\n![列宽](" + url2 + ")\n" +
		"a plain [doc](" + url1 + ") link stays a url\n" +
		"![quoted]('" + url2 + "')\n" +
		"![unknown](https://uploads.linear.app/w/i/nope)"
	got := rewriteImageRefs(body, renamed)
	want := "intro\n![字段配置](79d19f5f-b331-4131.png)\ntext\n![列宽](074ae41f-9ce1-4190.png)\n" +
		"a plain [doc](" + url1 + ") link stays a url\n" +
		"![quoted](074ae41f-9ce1-4190.png)\n" +
		"![unknown](https://uploads.linear.app/w/i/nope)"
	if got != want {
		t.Fatalf("rewriteImageRefs mismatch:\n got: %q\nwant: %q", got, want)
	}
	// No-op when nothing was uploaded.
	if got := rewriteImageRefs(body, nil); got != body {
		t.Fatalf("rewriteImageRefs with empty map changed body")
	}
}
