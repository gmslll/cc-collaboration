// Package drift detects whether the sender's local OpenAPI spec has changed
// since the most recent handoff that shipped a snapshot to a given recipient.
// It is the partner half of the B3 snapshot mechanism — B3 made every
// outbound handoff carry the spec; this package uses those snapshots as
// baselines so the sender can ask "did I forget to ship a follow-up?".
package drift

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/internal/sources/swagger"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// ErrNoSpec is returned by Detect when the caller passes specPath=="" or the
// file doesn't exist. Caller surfaces a "configure paths.swagger first"
// message — not a hard failure since not every project has an OpenAPI spec.
var ErrNoSpec = errors.New("no swagger spec configured")

// driftTimeFormat is the timestamp shape used in Summary output. Shared so
// CLI and MCP renderings stay byte-identical.
const driftTimeFormat = "2006-01-02 15:04"

// Result is the outcome of a drift scan. BaselineID is empty when no prior
// handoff with a snapshot was found in the scanned window. Delta is nil when
// the baseline matches the current spec.
type Result struct {
	BaselineID string
	Baseline   *handoffschema.ListItem
	Delta      *handoffschema.APIDelta
}

// Client is the subset of transport.Client that Detect needs. Defined as an
// interface so tests can stub out the network without spinning up a relay.
type Client interface {
	ListSent(ctx context.Context, limit int) ([]handoffschema.ListItem, error)
	FetchAttachment(ctx context.Context, handoffID, name string) ([]byte, error)
}

// Detect scans the sender's most recent `limit` sent handoffs (capped on the
// relay at 500), finds the newest one to `recipient` that still has the
// swagger snapshot attachment, and diffs that snapshot against the current
// local spec at specPath.
//
// Returns:
//   - (&Result{...}, nil) — normal case; check Result.Delta to know if drift
//     was found, and Result.BaselineID to know which prior handoff was used
//   - (nil, ErrNoSpec) — specPath is empty or missing
//   - (nil, err) — network / parse failure
//
// If no baseline exists in the scanned window, Result.BaselineID is empty
// and Result.Delta is nil — caller should advise "send a regular handoff
// first to establish a baseline".
func Detect(ctx context.Context, client Client, recipient, specPath string, limit int) (*Result, error) {
	if specPath == "" {
		return nil, ErrNoSpec
	}
	current, err := os.ReadFile(specPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNoSpec
		}
		return nil, fmt.Errorf("read swagger %s: %w", specPath, err)
	}

	if limit <= 0 {
		limit = 20
	}
	sent, err := client.ListSent(ctx, limit)
	if err != nil {
		return nil, fmt.Errorf("list sent: %w", err)
	}

	for i := range sent {
		it := sent[i]
		if recipient != "" && it.Recipient != recipient {
			continue
		}
		if it.State == handoffschema.StateRetracted {
			continue
		}
		if it.Kind == handoffschema.KindRequest {
			continue
		}
		baseline, err := client.FetchAttachment(ctx, it.ID, handoff.SwaggerSnapshotName)
		if err != nil {
			if errors.Is(err, transport.ErrAttachmentNotFound) {
				continue
			}
			return nil, fmt.Errorf("fetch attachment for %s: %w", it.ID, err)
		}
		delta, err := swagger.Diff(baseline, current)
		if err != nil {
			return nil, fmt.Errorf("diff against %s: %w", it.ID, err)
		}
		return &Result{
			BaselineID: it.ID,
			Baseline:   &it,
			Delta:      delta,
		}, nil
	}
	return &Result{}, nil
}

// HasDrift reports whether Detect found a baseline AND a non-empty delta
// against it. False covers both "no baseline" and "baseline matched".
func (r *Result) HasDrift() bool {
	return r.BaselineID != "" && r.Delta != nil
}

// Summary renders a human-readable summary of the drift scan. Used by both
// the CLI (`cc-handoff check-drift`) and the MCP (`check_drift`) entry
// points so wording stays in sync. The trailing remediation hint mentions
// `cc-handoff submit --amends ...` — agents reading this through MCP can
// substitute their preferred invocation.
func (r *Result) Summary(recipient string) string {
	if r.BaselineID == "" {
		return fmt.Sprintf(
			"no prior handoff to `%s` with a swagger snapshot found in the scanned window.\n"+
				"send a regular `cc-handoff submit` first to establish a baseline.",
			recipient,
		)
	}
	b := r.Baseline
	when := b.CreatedAt.Local().Format(driftTimeFormat)
	if r.Delta == nil {
		return fmt.Sprintf(
			"in sync with `%s` (sent %s to `%s`, state=%s).\n"+
				"no API changes since that handoff.",
			r.BaselineID, when, b.Recipient, b.State,
		)
	}
	d := r.Delta
	var sb strings.Builder
	fmt.Fprintf(&sb, "drift detected since `%s` (sent %s to `%s`, state=%s):\n\n", r.BaselineID, when, b.Recipient, b.State)
	fmt.Fprintf(&sb, "  operations: +%d  ~%d  -%d\n", len(d.Added), len(d.Changed), len(d.Removed))
	writeOps := func(label string, ops []handoffschema.Operation) {
		for _, op := range ops {
			fmt.Fprintf(&sb, "    %s: %s %s\n", label, op.Method, op.Path)
		}
	}
	writeOps("added", d.Added)
	writeOps("changed", d.Changed)
	writeOps("removed", d.Removed)
	if d.Servers != nil {
		fmt.Fprintf(&sb, "  servers:    +%d  -%d\n", len(d.Servers.Added), len(d.Servers.Removed))
	}
	if d.Security != nil {
		fmt.Fprintf(&sb, "  security:   +%d  -%d\n", len(d.Security.Added), len(d.Security.Removed))
	}
	fmt.Fprintf(&sb, "\nship a corrective handoff:\n  cc-handoff submit --amends %s\n", r.BaselineID)
	return sb.String()
}
