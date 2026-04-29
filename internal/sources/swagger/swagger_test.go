package swagger

import "testing"

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
	m, err := parse(curr)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := m["/customers"]["GET"]; !ok {
		t.Fatalf("expected /customers GET, got %+v", m)
	}
}
