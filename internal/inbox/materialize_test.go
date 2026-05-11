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
