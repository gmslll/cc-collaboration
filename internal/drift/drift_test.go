package drift

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// fakeClient is a stub for the drift.Client interface so tests can drive
// every branch of Detect without spinning up a relay.
type fakeClient struct {
	sent        []handoffschema.ListItem
	listErr     error
	attachments map[string][]byte // keyed by handoffID + ":" + name; missing → ErrAttachmentNotFound
	fetchErrFor map[string]error  // override the error for a specific handoffID+":"+name
}

func (f *fakeClient) ListSent(ctx context.Context, limit int) ([]handoffschema.ListItem, error) {
	if f.listErr != nil {
		return nil, f.listErr
	}
	return f.sent, nil
}

func (f *fakeClient) FetchAttachment(ctx context.Context, id, name string) ([]byte, error) {
	key := id + ":" + name
	if err, ok := f.fetchErrFor[key]; ok {
		return nil, err
	}
	if b, ok := f.attachments[key]; ok {
		return b, nil
	}
	return nil, transport.ErrAttachmentNotFound
}

func writeSpec(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "swagger.yaml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

const minimalSpec = `openapi: 3.0.0
paths:
  /customers:
    get:
      operationId: listCustomers
      summary: list customers
`

const driftedSpec = `openapi: 3.0.0
paths:
  /customers:
    get:
      operationId: listCustomers
      summary: list customers
  /customers/export:
    post:
      operationId: exportCustomers
      summary: export customers as CSV
`

func TestDetect_NoSpec(t *testing.T) {
	_, err := Detect(context.Background(), &fakeClient{}, "alex@frontend", "", 20)
	if !errors.Is(err, ErrNoSpec) {
		t.Fatalf("want ErrNoSpec for empty path, got %v", err)
	}
	missing := filepath.Join(t.TempDir(), "nope.yaml")
	_, err = Detect(context.Background(), &fakeClient{}, "alex@frontend", missing, 20)
	if !errors.Is(err, ErrNoSpec) {
		t.Errorf("want ErrNoSpec for missing file, got %v", err)
	}
}

func TestDetect_NoBaseline(t *testing.T) {
	// Sender has sent items but none to this recipient (or none with a snapshot).
	client := &fakeClient{
		sent: []handoffschema.ListItem{
			{ID: "h1", Recipient: "other@frontend", State: handoffschema.StatePicked, CreatedAt: time.Now()},
		},
		attachments: map[string][]byte{
			"h1:swagger.yaml": []byte(minimalSpec), // exists, but for a different recipient
		},
	}
	got, err := Detect(context.Background(), client, "alex@frontend", writeSpec(t, minimalSpec), 20)
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	if got.BaselineID != "" || got.Delta != nil {
		t.Errorf("want empty Result for no-baseline case, got %+v", got)
	}
}

func TestDetect_NoDrift(t *testing.T) {
	// Most recent send to recipient is identical to local spec.
	client := &fakeClient{
		sent: []handoffschema.ListItem{
			{ID: "h_baseline", Recipient: "alex@frontend", State: handoffschema.StatePicked, CreatedAt: time.Now()},
		},
		attachments: map[string][]byte{
			"h_baseline:swagger.yaml": []byte(minimalSpec),
		},
	}
	got, err := Detect(context.Background(), client, "alex@frontend", writeSpec(t, minimalSpec), 20)
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	if got.BaselineID != "h_baseline" {
		t.Errorf("BaselineID: got %q want h_baseline", got.BaselineID)
	}
	if got.Delta != nil {
		t.Errorf("Delta should be nil for identical spec, got %+v", got.Delta)
	}
}

func TestDetect_HasDrift(t *testing.T) {
	client := &fakeClient{
		sent: []handoffschema.ListItem{
			{ID: "h_baseline", Recipient: "alex@frontend", State: handoffschema.StatePicked, CreatedAt: time.Now()},
		},
		attachments: map[string][]byte{
			"h_baseline:swagger.yaml": []byte(minimalSpec),
		},
	}
	got, err := Detect(context.Background(), client, "alex@frontend", writeSpec(t, driftedSpec), 20)
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	if got.BaselineID != "h_baseline" {
		t.Errorf("BaselineID: got %q want h_baseline", got.BaselineID)
	}
	if got.Delta == nil {
		t.Fatalf("expected non-nil Delta for changed spec")
	}
	if len(got.Delta.Added) != 1 || got.Delta.Added[0].Path != "/customers/export" {
		t.Errorf("want one added endpoint /customers/export, got %+v", got.Delta.Added)
	}
}

func TestDetect_SkipsRetractedAndOlderWithoutSnapshot(t *testing.T) {
	// Newest item has no snapshot; second has the right snapshot; third is
	// retracted (should not be used even with snapshot).
	now := time.Now()
	client := &fakeClient{
		sent: []handoffschema.ListItem{
			{ID: "h_recent_no_snap", Recipient: "alex@frontend", State: handoffschema.StatePicked, CreatedAt: now},
			{ID: "h_good", Recipient: "alex@frontend", State: handoffschema.StatePicked, CreatedAt: now.Add(-time.Hour)},
			{ID: "h_retracted", Recipient: "alex@frontend", State: handoffschema.StateRetracted, CreatedAt: now.Add(-2 * time.Hour)},
		},
		attachments: map[string][]byte{
			"h_good:swagger.yaml":      []byte(minimalSpec),
			"h_retracted:swagger.yaml": []byte(minimalSpec),
		},
	}
	got, err := Detect(context.Background(), client, "alex@frontend", writeSpec(t, minimalSpec), 20)
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	if got.BaselineID != "h_good" {
		t.Errorf("want baseline h_good (newest with snapshot, not retracted), got %q", got.BaselineID)
	}
}

func TestResult_Summary(t *testing.T) {
	created := time.Date(2026, 5, 10, 14, 23, 0, 0, time.UTC)

	t.Run("no baseline", func(t *testing.T) {
		got := (&Result{}).Summary("alex@frontend")
		for _, want := range []string{
			"no prior handoff to `alex@frontend`",
			"swagger snapshot",
			"`cc-handoff submit`",
		} {
			if !strings.Contains(got, want) {
				t.Errorf("missing %q\nfull:\n%s", want, got)
			}
		}
	})

	t.Run("no drift", func(t *testing.T) {
		r := &Result{
			BaselineID: "h_baseline",
			Baseline: &handoffschema.ListItem{
				ID:        "h_baseline",
				Recipient: "alex@frontend",
				State:     handoffschema.StatePicked,
				CreatedAt: created,
			},
		}
		got := r.Summary("alex@frontend")
		for _, want := range []string{
			"in sync with `h_baseline`",
			"alex@frontend",
			"state=picked",
			"no API changes",
		} {
			if !strings.Contains(got, want) {
				t.Errorf("missing %q\nfull:\n%s", want, got)
			}
		}
		if r.HasDrift() {
			t.Error("HasDrift should be false when Delta is nil")
		}
	})

	t.Run("has drift", func(t *testing.T) {
		r := &Result{
			BaselineID: "h_baseline",
			Baseline: &handoffschema.ListItem{
				ID:        "h_baseline",
				Recipient: "alex@frontend",
				State:     handoffschema.StatePicked,
				CreatedAt: created,
			},
			Delta: &handoffschema.APIDelta{
				Added: []handoffschema.Operation{
					{Method: "POST", Path: "/customers/export"},
				},
				Changed: []handoffschema.Operation{
					{Method: "POST", Path: "/customers"},
				},
			},
		}
		got := r.Summary("alex@frontend")
		for _, want := range []string{
			"drift detected since `h_baseline`",
			"operations: +1  ~1  -0",
			"added: POST /customers/export",
			"changed: POST /customers",
			"cc-handoff submit --amends h_baseline",
		} {
			if !strings.Contains(got, want) {
				t.Errorf("missing %q\nfull:\n%s", want, got)
			}
		}
		if !r.HasDrift() {
			t.Error("HasDrift should be true when Delta is non-empty")
		}
	})
}

func TestDetect_UsesHandoffSwaggerSnapshotName(t *testing.T) {
	// Belt-and-suspenders: the fakeClient keys attachments by exactly the
	// constant that drift.Detect uses. If someone renames
	// handoff.SwaggerSnapshotName the cross-package contract test catches it.
	const want = "swagger.yaml"
	if handoff.SwaggerSnapshotName != want {
		t.Fatalf("attachment name constant drifted: got %q want %q", handoff.SwaggerSnapshotName, want)
	}
}
