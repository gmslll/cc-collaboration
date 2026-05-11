package swagger

import (
	"slices"
	"strings"
	"testing"

	"github.com/cc-collaboration/pkg/handoffschema"
)

// findOp returns the first operation matching (method, path) from one of the
// three buckets. Test helper.
func findOp(ops []handoffschema.Operation, method, path string) *handoffschema.Operation {
	for i := range ops {
		if ops[i].Method == method && ops[i].Path == path {
			return &ops[i]
		}
	}
	return nil
}

// fieldByPath returns the first FieldRef with the given path, or nil.
func fieldByPath(fs []handoffschema.FieldRef, path string) *handoffschema.FieldRef {
	for i := range fs {
		if fs[i].Path == path {
			return &fs[i]
		}
	}
	return nil
}

// changeByPath returns the first FieldChange with the given path, or nil.
func changeByPath(cs []handoffschema.FieldChange, path string) *handoffschema.FieldChange {
	for i := range cs {
		if cs[i].Path == path {
			return &cs[i]
		}
	}
	return nil
}

func TestDiff_AddsNewEndpoint(t *testing.T) {
	prev := []byte(`openapi: 3.0.0
paths:
  /customers:
    get:
      operationId: listCustomers
      summary: list customers
`)
	curr := []byte(`openapi: 3.0.0
paths:
  /customers:
    get:
      operationId: listCustomers
      summary: list customers
  /customers/export:
    post:
      operationId: exportCustomers
      summary: export customers
`)
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatal(err)
	}
	if d == nil {
		t.Fatal("expected non-nil delta when prev != curr")
	}
	if got := len(d.Added); got != 1 {
		t.Fatalf("Added: want 1 got %d (%+v)", got, d.Added)
	}
	if d.Added[0].Path != "/customers/export" || d.Added[0].Method != "POST" {
		t.Fatalf("unexpected added op: %+v", d.Added[0])
	}
	if got := len(d.Removed); got != 0 {
		t.Fatalf("Removed: want 0 got %d", got)
	}
}

func TestDiff_FirstRunReportsAllAsAdded(t *testing.T) {
	curr := []byte(`paths:
  /customers:
    get:
      operationId: listCustomers
`)
	d, err := diff(nil, curr)
	if err != nil {
		t.Fatal(err)
	}
	if d == nil || len(d.Added) != 1 {
		t.Fatalf("first-run diff: want 1 added, got %+v", d)
	}
}

func TestDiff_NoChangeReturnsNil(t *testing.T) {
	spec := []byte(`paths:
  /customers:
    get:
      operationId: listCustomers
`)
	d, err := diff(spec, spec)
	if err != nil {
		t.Fatal(err)
	}
	if d != nil {
		t.Fatalf("identical specs should yield nil delta, got %+v", d)
	}
}

func TestParse_FlowStyleInfo(t *testing.T) {
	curr := []byte(`openapi: 3.0.0
info: { title: test, version: 0.0.1 }
paths:
  /customers:
    get:
      operationId: listCustomers
`)
	s, err := parseSpec(curr)
	if err != nil {
		t.Fatal(err)
	}
	op, ok := s.Paths["/customers"]["get"]
	if !ok {
		t.Fatalf("expected /customers get, got %+v", s.Paths)
	}
	if op.OperationID != "listCustomers" {
		t.Fatalf("operationId: got %q want listCustomers", op.OperationID)
	}
}

// ---- Field-level diff tests (A1) ----

// updateOp returns prev/curr YAML for a single endpoint `POST /customers` so
// each test only encodes the request/response/parameter delta of interest.
func updateOp(prevBody, currBody string) (prev, curr []byte) {
	const tmpl = `openapi: 3.0.0
paths:
  /customers:
    post:
      operationId: updateCustomer
      summary: update customer
%s
`
	return []byte(formatTmpl(tmpl, prevBody)), []byte(formatTmpl(tmpl, currBody))
}

func formatTmpl(tmpl, body string) string {
	return strings.ReplaceAll(tmpl, "%s", indent(body, "      "))
}

func indent(s, pad string) string {
	if s == "" {
		return ""
	}
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		if l != "" {
			lines[i] = pad + l
		}
	}
	return strings.Join(lines, "\n")
}

func TestDiff_AddsTopLevelField(t *testing.T) {
	prev, curr := updateOp(`requestBody:
  content:
    application/json:
      schema:
        type: object
        properties:
          name: { type: string }
`, `requestBody:
  content:
    application/json:
      schema:
        type: object
        properties:
          name: { type: string }
          age: { type: integer }
`)
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatal(err)
	}
	op := findOp(d.Changed, "POST", "/customers")
	if op == nil || op.Detail == nil || op.Detail.RequestBody == nil {
		t.Fatalf("missing request-body diff: %+v", d)
	}
	if fieldByPath(op.Detail.RequestBody.Added, "age") == nil {
		t.Fatalf("expected `age` in Added, got %+v", op.Detail.RequestBody.Added)
	}
}

func TestDiff_AddsNestedField(t *testing.T) {
	prev, curr := updateOp(`requestBody:
  content:
    application/json:
      schema:
        type: object
        properties:
          address:
            type: object
            properties:
              street: { type: string }
`, `requestBody:
  content:
    application/json:
      schema:
        type: object
        properties:
          address:
            type: object
            properties:
              street: { type: string }
              city: { type: string }
              zip: { type: string }
`)
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatal(err)
	}
	op := findOp(d.Changed, "POST", "/customers")
	if op == nil || op.Detail == nil || op.Detail.RequestBody == nil {
		t.Fatalf("missing request-body diff: %+v", d)
	}
	if fieldByPath(op.Detail.RequestBody.Added, "address.city") == nil {
		t.Errorf("expected address.city in Added, got %+v", op.Detail.RequestBody.Added)
	}
	if fieldByPath(op.Detail.RequestBody.Added, "address.zip") == nil {
		t.Errorf("expected address.zip in Added, got %+v", op.Detail.RequestBody.Added)
	}
}

func TestDiff_ChangesFieldType(t *testing.T) {
	prev, curr := updateOp(`requestBody:
  content:
    application/json:
      schema:
        type: object
        properties:
          age: { type: integer }
`, `requestBody:
  content:
    application/json:
      schema:
        type: object
        properties:
          age: { type: string }
`)
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatal(err)
	}
	op := findOp(d.Changed, "POST", "/customers")
	if op == nil || op.Detail == nil || op.Detail.RequestBody == nil {
		t.Fatalf("missing request-body diff")
	}
	ch := changeByPath(op.Detail.RequestBody.Changed, "age")
	if ch == nil {
		t.Fatalf("expected `age` in Changed, got %+v", op.Detail.RequestBody.Changed)
	}
	if ch.Reason != "type" || ch.Before.Type != "integer" || ch.After.Type != "string" {
		t.Errorf("unexpected change: %+v", ch)
	}
}

func TestDiff_FlipsRequired(t *testing.T) {
	prev, curr := updateOp(`requestBody:
  content:
    application/json:
      schema:
        type: object
        required: [name]
        properties:
          name: { type: string }
          email: { type: string }
`, `requestBody:
  content:
    application/json:
      schema:
        type: object
        required: [name, email]
        properties:
          name: { type: string }
          email: { type: string }
`)
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatal(err)
	}
	op := findOp(d.Changed, "POST", "/customers")
	if op == nil || op.Detail == nil || op.Detail.RequestBody == nil {
		t.Fatalf("missing request-body diff")
	}
	ch := changeByPath(op.Detail.RequestBody.Changed, "email")
	if ch == nil {
		t.Fatalf("expected `email` required flip, got %+v", op.Detail.RequestBody.Changed)
	}
	if ch.Reason != "required" || ch.Before.Required || !ch.After.Required {
		t.Errorf("unexpected required flip: %+v", ch)
	}
}

func TestDiff_ChangesArrayItem(t *testing.T) {
	prev, curr := updateOp(`requestBody:
  content:
    application/json:
      schema:
        type: object
        properties:
          tags:
            type: array
            items: { type: string }
`, `requestBody:
  content:
    application/json:
      schema:
        type: object
        properties:
          tags:
            type: array
            items: { type: integer }
`)
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatal(err)
	}
	op := findOp(d.Changed, "POST", "/customers")
	if op == nil || op.Detail == nil || op.Detail.RequestBody == nil {
		t.Fatalf("missing request-body diff")
	}
	ch := changeByPath(op.Detail.RequestBody.Changed, "tags[]")
	if ch == nil {
		t.Fatalf("expected tags[] in Changed, got %+v", op.Detail.RequestBody.Changed)
	}
	if ch.Reason != "type" {
		t.Errorf("expected type-change reason on tags[]: %+v", ch)
	}
}

func TestDiff_ResolvesRef(t *testing.T) {
	prev := []byte(`openapi: 3.0.0
paths:
  /customers:
    post:
      operationId: updateCustomer
      summary: update customer
      requestBody:
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/Customer'
components:
  schemas:
    Customer:
      type: object
      properties:
        name: { type: string }
`)
	curr := []byte(`openapi: 3.0.0
paths:
  /customers:
    post:
      operationId: updateCustomer
      summary: update customer
      requestBody:
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/Customer'
components:
  schemas:
    Customer:
      type: object
      properties:
        name: { type: string }
        email: { type: string }
`)
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatal(err)
	}
	op := findOp(d.Changed, "POST", "/customers")
	if op == nil || op.Detail == nil || op.Detail.RequestBody == nil {
		t.Fatalf("$ref-resolution diff missing: %+v", d)
	}
	if fieldByPath(op.Detail.RequestBody.Added, "email") == nil {
		t.Errorf("expected email in Added through $ref, got %+v", op.Detail.RequestBody.Added)
	}
}

func TestDiff_CycleProtection(t *testing.T) {
	// Self-referencing Comment.replies: [Comment]. Identical on both sides
	// except for a leaf addition far away — verifies we don't loop on cycles.
	prev := []byte(`openapi: 3.0.0
paths:
  /threads:
    post:
      operationId: addThread
      summary: add
      requestBody:
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/Comment'
components:
  schemas:
    Comment:
      type: object
      properties:
        body: { type: string }
        replies:
          type: array
          items: { $ref: '#/components/schemas/Comment' }
`)
	curr := []byte(`openapi: 3.0.0
paths:
  /threads:
    post:
      operationId: addThread
      summary: add
      requestBody:
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/Comment'
components:
  schemas:
    Comment:
      type: object
      properties:
        body: { type: string }
        author: { type: string }
        replies:
          type: array
          items: { $ref: '#/components/schemas/Comment' }
`)
	// We just need diff to terminate. Asserting `author` shows up is also nice.
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatalf("cycle protection failed: %v", err)
	}
	if d == nil {
		t.Fatalf("expected a delta for the new author field")
	}
}

func TestDiff_ParameterRequiredFlip(t *testing.T) {
	prev, curr := updateOp(`parameters:
  - name: limit
    in: query
    required: false
    schema: { type: integer }
`, `parameters:
  - name: limit
    in: query
    required: true
    schema: { type: integer }
`)
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatal(err)
	}
	op := findOp(d.Changed, "POST", "/customers")
	if op == nil || op.Detail == nil || op.Detail.Parameters == nil {
		t.Fatalf("missing params diff: %+v", d)
	}
	ch := changeByPath(op.Detail.Parameters.Changed, "query.limit")
	if ch == nil {
		t.Fatalf("expected query.limit required-flip, got %+v", op.Detail.Parameters.Changed)
	}
	if ch.Reason != "required" {
		t.Errorf("unexpected reason: %s", ch.Reason)
	}
}

func TestDiff_ErrorCodesAdded(t *testing.T) {
	prev, curr := updateOp(`responses:
  '200': { description: ok }
  '400': { description: bad }
`, `responses:
  '200': { description: ok }
  '400': { description: bad }
  '404': { description: not found }
  '409': { description: conflict }
`)
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatal(err)
	}
	op := findOp(d.Changed, "POST", "/customers")
	if op == nil || op.Detail == nil || op.Detail.ErrorCodes == nil {
		t.Fatalf("missing error-code diff: %+v", d)
	}
	if !slices.Contains(op.Detail.ErrorCodes.Added, "404") || !slices.Contains(op.Detail.ErrorCodes.Added, "409") {
		t.Errorf("expected 404 and 409 added: %+v", op.Detail.ErrorCodes.Added)
	}
}

func TestDiff_ResponseHeaders(t *testing.T) {
	prev, curr := updateOp(`responses:
  '200':
    description: ok
    headers:
      X-Trace-Id:
        schema: { type: string }
`, `responses:
  '200':
    description: ok
    headers:
      X-Trace-Id:
        schema: { type: string }
      X-Rate-Limit:
        schema: { type: integer }
`)
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatal(err)
	}
	op := findOp(d.Changed, "POST", "/customers")
	if op == nil || op.Detail == nil {
		t.Fatalf("missing op detail: %+v", d)
	}
	resp, ok := op.Detail.Responses["200"]
	if !ok || resp.Headers == nil {
		t.Fatalf("missing 200 response headers diff: %+v", op.Detail.Responses)
	}
	if fieldByPath(resp.Headers.Added, "X-Rate-Limit") == nil {
		t.Errorf("expected X-Rate-Limit in Added: %+v", resp.Headers.Added)
	}
}

func TestDiff_PolymorphicNotRecursed(t *testing.T) {
	prev, curr := updateOp(`requestBody:
  content:
    application/json:
      schema:
        type: object
        properties:
          payload:
            oneOf:
              - { type: object, properties: { a: { type: string } } }
              - { type: object, properties: { b: { type: integer } } }
`, `requestBody:
  content:
    application/json:
      schema:
        type: object
        properties:
          payload:
            oneOf:
              - { type: object, properties: { a: { type: string } } }
              - { type: object, properties: { b: { type: integer } } }
              - { type: object, properties: { c: { type: boolean } } }
`)
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatal(err)
	}
	op := findOp(d.Changed, "POST", "/customers")
	if op == nil || op.Detail == nil || op.Detail.RequestBody == nil {
		t.Fatalf("missing request-body diff: %+v", d)
	}
	ch := changeByPath(op.Detail.RequestBody.Changed, "payload")
	if ch == nil {
		t.Fatalf("expected payload polymorphic change, got %+v", op.Detail.RequestBody.Changed)
	}
	if ch.Reason != "polymorphic" {
		t.Errorf("expected reason=polymorphic, got %q", ch.Reason)
	}
	// Should NOT have recursed into oneOf members.
	for _, c := range op.Detail.RequestBody.Changed {
		if c.Path != "payload" {
			t.Errorf("polymorphic should not recurse, but got change at %q", c.Path)
		}
	}
	for _, a := range op.Detail.RequestBody.Added {
		if a.Path == "payload.c" || a.Path == "c" {
			t.Errorf("polymorphic should not surface inner field %q", a.Path)
		}
	}
}

func TestDiff_ServersChange(t *testing.T) {
	prev := []byte(`openapi: 3.0.0
servers:
  - url: https://api-old.example.com
paths:
  /x:
    get: { operationId: x, summary: x }
`)
	curr := []byte(`openapi: 3.0.0
servers:
  - url: https://api.example.com
  - url: https://api-staging.example.com
paths:
  /x:
    get: { operationId: x, summary: x }
`)
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatal(err)
	}
	if d == nil || d.Servers == nil {
		t.Fatalf("expected Servers diff, got %+v", d)
	}
	if !slices.Contains(d.Servers.Added, "https://api.example.com") {
		t.Errorf("expected api.example.com added: %+v", d.Servers)
	}
	if !slices.Contains(d.Servers.Removed, "https://api-old.example.com") {
		t.Errorf("expected api-old.example.com removed: %+v", d.Servers)
	}
}

func TestDiff_SecuritySchemeChange(t *testing.T) {
	prev := []byte(`openapi: 3.0.0
security:
  - bearerAuth: []
paths:
  /x:
    get: { operationId: x, summary: x }
`)
	curr := []byte(`openapi: 3.0.0
security:
  - bearerAuth: []
  - oauth2: [read, write]
paths:
  /x:
    get: { operationId: x, summary: x }
`)
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatal(err)
	}
	if d == nil || d.Security == nil {
		t.Fatalf("expected Security diff, got %+v", d)
	}
	if !slices.Contains(d.Security.Added, "oauth2:read,write") {
		t.Errorf("expected oauth2:read,write added: %+v", d.Security)
	}
}

func TestDiff_BackwardCompat_OldOperationOnlyChange(t *testing.T) {
	// Summary changed; nothing else differs. Detail should be nil so the
	// receiver renders the operation just like the pre-A1 flow did.
	prev := []byte(`openapi: 3.0.0
paths:
  /x:
    get: { operationId: x, summary: old summary }
`)
	curr := []byte(`openapi: 3.0.0
paths:
  /x:
    get: { operationId: x, summary: new summary }
`)
	d, err := diff(prev, curr)
	if err != nil {
		t.Fatal(err)
	}
	op := findOp(d.Changed, "GET", "/x")
	if op == nil {
		t.Fatalf("expected /x GET in Changed: %+v", d)
	}
	if op.Detail != nil {
		t.Errorf("Detail should be nil when only summary changes, got %+v", op.Detail)
	}
}
