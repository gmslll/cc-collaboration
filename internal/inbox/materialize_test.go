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

// TestRenderAttachmentsSection_SkipsSwagger verifies the swagger snapshot is
// excluded (it's covered by the API delta section), while user-supplied
// attachments are listed with size + path.
func TestRenderAttachmentsSection_SkipsSwagger(t *testing.T) {
	p := &handoffschema.Package{
		Attachments: []handoffschema.Attachment{
			{Name: "swagger.yaml", SHA256: "x", Size: 12345},
			{Name: "screenshot.png", SHA256: "y", Size: 555_000},
			{Name: "network.har", SHA256: "z", Size: 12 * 1024},
		},
	}
	got := renderAttachmentsSection(p)
	if strings.Contains(got, "swagger.yaml") {
		t.Errorf("swagger.yaml should be excluded:\n%s", got)
	}
	for _, want := range []string{
		"## 📎 附件",
		"attachments/screenshot.png",
		"attachments/network.har",
		"用 Read",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in:\n%s", want, got)
		}
	}
}

// TestRenderAttachmentsSection_EmptyWhenNothingUserAttached: a package with
// only swagger.yaml (the default for delivery) produces no section — empty
// templates concatenate fine.
func TestRenderAttachmentsSection_EmptyWhenNothingUserAttached(t *testing.T) {
	p := &handoffschema.Package{
		Attachments: []handoffschema.Attachment{
			{Name: "swagger.yaml", SHA256: "x", Size: 12345},
		},
	}
	if got := renderAttachmentsSection(p); got != "" {
		t.Errorf("expected empty section, got:\n%s", got)
	}
}

// TestRenderBugPromptMD_AttachmentsBeforeDecisionTree: in bug templates the
// attachment list must come *before* the decision tree, because screenshots
// are evidence the receiver uses to judge ownership in step 1.
func TestRenderBugPromptMD_AttachmentsBeforeDecisionTree(t *testing.T) {
	p := &handoffschema.Package{
		ID:         "b_attach",
		Kind:       handoffschema.KindBug,
		Sender:     "tester",
		Recipients: []string{"backend", "frontend"},
		SummaryMD:  "## Symptom\n broken",
		Attachments: []handoffschema.Attachment{
			{Name: "screenshot.png", SHA256: "a", Size: 1024},
		},
	}
	got := renderPromptMD(p, ModeDocFirst)
	attachIdx := strings.Index(got, "## 📎 附件")
	treeIdx := strings.Index(got, "## 归属判断决策树")
	if attachIdx < 0 || treeIdx < 0 {
		t.Fatalf("missing sections: attach=%d, tree=%d\n%s", attachIdx, treeIdx, got)
	}
	if attachIdx > treeIdx {
		t.Errorf("attachments (%d) should appear before decision tree (%d)", attachIdx, treeIdx)
	}
}

// TestRenderBugPromptMD_MultiRecipient checks the decision-tree template fires
// for kind=bug and surfaces the multi-recipient banner when more than one
// engineering side is on the to= list.
func TestRenderBugPromptMD_MultiRecipient(t *testing.T) {
	p := &handoffschema.Package{
		ID:             "b_test",
		Kind:           handoffschema.KindBug,
		Sender:         "tester",
		OriginalSender: "tester",
		Recipients:     []string{"backend", "frontend"},
		SummaryMD:      "## Symptom\n broken thing on /orders",
		NoteMD:         "must pass automated regression",
	}
	got := renderPromptMD(p, ModeDocFirst)

	mustContain := []string{
		"# Bug:",
		"reported by `tester`",
		"同时发送", // multi-recipient banner
		"`backend`",
		"`frontend`",
		"## 归属判断决策树",
		"reassign_bug",
		"comment_handoff",
		"## ⚠️ 测试备注 / 验收标准 (必读)",
		"must pass automated regression",
	}
	for _, want := range mustContain {
		if !strings.Contains(got, want) {
			t.Errorf("bug prompt missing %q in:\n%s", want, got)
		}
	}
}

// TestRenderBugPromptMD_ReassignedBanner verifies the "由对端转过来" banner
// renders the reassign reason when ReassignedFrom is set.
func TestRenderBugPromptMD_ReassignedBanner(t *testing.T) {
	p := &handoffschema.Package{
		ID:               "b_child",
		Kind:             handoffschema.KindBug,
		Sender:           "backend",
		OriginalSender:   "tester",
		Recipients:       []string{"frontend"},
		SummaryMD:        "## Symptom\n broken thing",
		ReassignedFrom:   "b_parent",
		ReassignedReason: "字段是前端拼的",
	}
	got := renderPromptMD(p, ModeDocFirst)

	mustContain := []string{
		"由对端转过来",
		"`backend`",
		"字段是前端拼的",
		"reassign_bug",
	}
	for _, want := range mustContain {
		if !strings.Contains(got, want) {
			t.Errorf("reassigned bug prompt missing %q in:\n%s", want, got)
		}
	}
}

// TestRenderBugPromptMD_OriginalSenderFallback verifies the reporter name in
// the header falls back to Sender when OriginalSender is empty (e.g. legacy
// payloads or first-hop bug never reassigned).
func TestRenderBugPromptMD_OriginalSenderFallback(t *testing.T) {
	p := &handoffschema.Package{
		ID:         "b_orig",
		Kind:       handoffschema.KindBug,
		Sender:     "tester",
		Recipients: []string{"backend"},
		SummaryMD:  "## Symptom\n broken",
	}
	got := renderPromptMD(p, ModeDocFirst)
	if !strings.Contains(got, "reported by `tester`") {
		t.Errorf("header should fall back to Sender when OriginalSender empty:\n%s", got)
	}
}
