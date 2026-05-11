package inbox

import (
	"strings"
	"testing"

	"github.com/cc-collaboration/pkg/handoffschema"
)

// TestRenderAPIDeltaMD_FieldLevel locks down the rendered shape of a Changed
// operation with full field-level Detail. Each substring assertion is a
// "this kind of information must reach the receiver" guarantee.
func TestRenderAPIDeltaMD_FieldLevel(t *testing.T) {
	d := &handoffschema.APIDelta{
		Format: "openapi-3",
		Changed: []handoffschema.Operation{
			{
				Method:  "POST",
				Path:    "/customers",
				Summary: "update customer",
				Detail: &handoffschema.OperationDetail{
					RequestBody: &handoffschema.SchemaDiff{
						Added: []handoffschema.FieldRef{
							{Path: "address.city", Type: "string", Required: true},
						},
						Removed: []handoffschema.FieldRef{
							{Path: "legacy_field", Type: "string"},
						},
						Changed: []handoffschema.FieldChange{
							{
								Path:   "age",
								Before: handoffschema.FieldRef{Path: "age", Type: "integer"},
								After:  handoffschema.FieldRef{Path: "age", Type: "string"},
								Reason: "type",
							},
						},
					},
					Responses: map[string]*handoffschema.ResponseDetail{
						"200": {
							Body: &handoffschema.SchemaDiff{
								Added: []handoffschema.FieldRef{
									{Path: "updated_at", Type: "string", Format: "date-time"},
								},
							},
						},
					},
					Parameters: &handoffschema.SchemaDiff{
						Changed: []handoffschema.FieldChange{
							{
								Path:   "query.limit",
								Before: handoffschema.FieldRef{Path: "query.limit", Type: "integer"},
								After:  handoffschema.FieldRef{Path: "query.limit", Type: "integer", Required: true},
								Reason: "required",
							},
						},
					},
					ErrorCodes: &handoffschema.StatusCodeListDiff{
						Added: []string{"404", "409"},
					},
					Security: &handoffschema.StringListDiff{
						Added: []string{"oauth2:write"},
					},
				},
			},
		},
		Servers: &handoffschema.StringListDiff{
			Added:   []string{"https://api.example.com"},
			Removed: []string{"https://api-old.example.com"},
		},
	}

	got := renderAPIDeltaMD(d)
	for _, want := range []string{
		"### POST /customers — update customer",
		"**请求体变更**",
		"- + `address.city` string required",
		"- - `legacy_field` string",
		"- ~ `age`: integer → string (type)",
		"**200 响应变更**",
		"- + `updated_at` string format=date-time",
		"**参数变更**",
		"- ~ `query.limit`: integer → integer required (required)",
		"**错误码列表**",
		"- + 404",
		"- + 409",
		"**安全要求**",
		"- + oauth2:write",
		"## 全局变更",
		"**Servers**",
		"- + https://api.example.com",
		"- - https://api-old.example.com",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("rendered delta missing %q\nfull output:\n%s", want, got)
		}
	}
}

// TestRenderPromptMD_AmendsBanner: when AmendsHandoff is set on a delivery
// package, the receiver-side prompt must lead with a prominent "修正交付"
// banner pointing back at the prior id.
func TestRenderPromptMD_AmendsBanner(t *testing.T) {
	p := &handoffschema.Package{
		ID:            "h_new",
		Sender:        "backend",
		Recipient:     "frontend",
		AmendsHandoff: "h_prior",
		SummaryMD:     "fixed discount field type",
	}
	got := renderPromptMD(p, ModeDocFirst)
	for _, want := range []string{
		"⚠️ **修正交付**",
		"`h_prior`",
		"docs/integrations/h_prior.md",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("amends banner missing %q\nfull:\n%s", want, got)
		}
	}
}

// TestRenderPromptMD_NoAmendsBannerWhenAbsent confirms that without
// AmendsHandoff the banner doesn't appear (no stray "修正交付" leak).
func TestRenderPromptMD_NoAmendsBannerWhenAbsent(t *testing.T) {
	p := &handoffschema.Package{
		ID:        "h_new",
		Sender:    "backend",
		Recipient: "frontend",
		SummaryMD: "regular delivery",
	}
	got := renderPromptMD(p, ModeDocFirst)
	if strings.Contains(got, "修正交付") {
		t.Errorf("unexpected amends banner when AmendsHandoff is empty:\n%s", got)
	}
}

// TestRenderPromptMD_FeedbackTemplate confirms the C2 structured feedback
// step appears in every delivery prompt, with the four canonical sections
// the receiver is expected to fill in via comment_handoff.
func TestRenderPromptMD_FeedbackTemplate(t *testing.T) {
	cases := []struct {
		name string
		pkg  *handoffschema.Package
		mode Mode
	}{
		{
			name: "doc-first delivery",
			pkg:  &handoffschema.Package{ID: "h_d1", Sender: "backend", Recipient: "frontend", SummaryMD: "x"},
			mode: ModeDocFirst,
		},
		{
			name: "direct delivery",
			pkg:  &handoffschema.Package{ID: "h_d2", Sender: "backend", Recipient: "frontend", SummaryMD: "x"},
			mode: ModeDirect,
		},
		{
			name: "module-brief doc-first",
			pkg:  &handoffschema.Package{ID: "h_m1", Sender: "backend", Recipient: "frontend", SummaryMD: "x", ModulePaths: []string{"internal/foo"}},
			mode: ModeDocFirst,
		},
		{
			name: "module-brief direct",
			pkg:  &handoffschema.Package{ID: "h_m2", Sender: "backend", Recipient: "frontend", SummaryMD: "x", ModulePaths: []string{"internal/foo"}},
			mode: ModeDirect,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := renderPromptMD(tc.pkg, tc.mode)
			for _, want := range []string{
				"结构化反馈",
				"comment_handoff " + tc.pkg.ID,
				"理解:",
				"已落地:",
				"疑问:",
				"跨端反馈:",
			} {
				if !strings.Contains(got, want) {
					t.Errorf("feedback template missing %q\nfull:\n%s", want, got)
				}
			}
		})
	}
}

// TestRenderAPIDeltaMD_LegacyOpWithoutDetail confirms older payloads
// (Detail == nil) still render their operation heading without crashing.
func TestRenderAPIDeltaMD_LegacyOpWithoutDetail(t *testing.T) {
	d := &handoffschema.APIDelta{
		Format: "openapi-3",
		Changed: []handoffschema.Operation{
			{Method: "GET", Path: "/health", Summary: "health check"},
		},
	}
	got := renderAPIDeltaMD(d)
	if !strings.Contains(got, "### GET /health — health check") {
		t.Errorf("legacy op heading missing: %s", got)
	}
	if strings.Contains(got, "**请求体变更**") {
		t.Errorf("legacy op should have no body sub-section: %s", got)
	}
}
