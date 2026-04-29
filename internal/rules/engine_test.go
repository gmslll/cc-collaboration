package rules

import (
	"reflect"
	"testing"

	"github.com/cc-collaboration/internal/config"
)

func TestCompile_RejectsInvalidRegex(t *testing.T) {
	_, err := Compile([]config.Rule{{WhenPathMatches: "[unclosed"}})
	if err == nil {
		t.Fatal("expected error for invalid regex")
	}
}

func TestCompile_RequiresPattern(t *testing.T) {
	_, err := Compile([]config.Rule{{}})
	if err == nil {
		t.Fatal("expected error for empty pattern")
	}
}

func TestApply_testBackendToFrontend(t *testing.T) {
	e, err := Compile([]config.Rule{
		{
			WhenPathMatches:        `^internal/module/(?P<domain>[^/]+)/`,
			SuggestEdit:            []string{"lib/api/{domain}.ts"},
			SuggestCreateIfMissing: true,
		},
		{
			WhenPathMatches: `^internal/module/(?P<domain>[^/]+)/dto/`,
			SuggestEdit:     []string{"types/{domain}.ts"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	hints := e.Apply([]string{
		"internal/module/customers/handler/routes.go",
		"internal/module/customers/handler/http.go",
		"internal/module/customers/dto/request.go",
		"docs/swagger.yaml",
	})

	// Expected: customers domain produces both lib/api/customers.ts (rule 1)
	// and types/customers.ts (rule 2). Multiple paths matching rule 1 should
	// dedupe to one hint per (path, edits, creates) tuple.
	wantEdits := map[string]bool{
		"lib/api/customers.ts": false,
		"types/customers.ts":   false,
	}
	for _, h := range hints {
		for _, e := range h.SuggestEdit {
			if _, ok := wantEdits[e]; ok {
				wantEdits[e] = true
			}
		}
	}
	for edit, seen := range wantEdits {
		if !seen {
			t.Errorf("expected hint suggesting edit %q, none produced; got %d hints", edit, len(hints))
		}
	}

	// docs/swagger.yaml matches no rule; should not appear in hints.
	for _, h := range hints {
		if h.MatchedPath == "docs/swagger.yaml" {
			t.Errorf("docs/swagger.yaml should not match any rule, got hint: %+v", h)
		}
	}

	// SuggestCreate should be populated for rule 1 (suggest_create_if_missing=true)
	// but not rule 2. Find the rule-1 hint by checking captures and edits.
	foundCreate := false
	for _, h := range hints {
		for _, e := range h.SuggestEdit {
			if e == "lib/api/customers.ts" && len(h.SuggestCreate) > 0 {
				foundCreate = true
			}
		}
	}
	if !foundCreate {
		t.Error("rule with suggest_create_if_missing=true should populate SuggestCreate")
	}
}

func TestApply_UnknownPlaceholderLeftLiteral(t *testing.T) {
	e, _ := Compile([]config.Rule{{
		WhenPathMatches: `^src/(?P<name>[^/]+)`,
		SuggestEdit:     []string{"target/{name}/{unknown}.ts"},
	}})
	hints := e.Apply([]string{"src/foo/bar.go"})
	if len(hints) != 1 {
		t.Fatalf("want 1 hint, got %d", len(hints))
	}
	got := hints[0].SuggestEdit
	want := []string{"target/foo/{unknown}.ts"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("unknown placeholder should be left literal, got %v want %v", got, want)
	}
}

func TestApply_NilEngineNoPanic(t *testing.T) {
	var e *Engine
	if h := e.Apply([]string{"any/path.go"}); h != nil {
		t.Errorf("nil engine should return nil hints, got %v", h)
	}
}

func TestApply_CapturesRecorded(t *testing.T) {
	e, _ := Compile([]config.Rule{{
		WhenPathMatches: `^internal/module/(?P<domain>[^/]+)/`,
		SuggestEdit:     []string{"lib/api/{domain}.ts"},
	}})
	hints := e.Apply([]string{"internal/module/wallet/handler/routes.go"})
	if len(hints) != 1 {
		t.Fatalf("want 1 hint, got %d", len(hints))
	}
	if hints[0].Captures["domain"] != "wallet" {
		t.Errorf("expected captures[domain]=wallet, got %v", hints[0].Captures)
	}
}
