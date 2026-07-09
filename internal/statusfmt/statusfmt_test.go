package statusfmt

import (
	"strings"
	"testing"
	"time"

	"github.com/cc-collaboration/pkg/handoffschema"
)

func TestFormatCLIMultiRecipientShowsEveryPickupSlot(t *testing.T) {
	pickedAt := time.Date(2026, 7, 9, 8, 30, 0, 0, time.UTC)
	st := &handoffschema.Status{
		ID:         "h_team",
		State:      handoffschema.StatePending,
		Sender:     "owner@x",
		Recipients: []string{"dev@x", "ops@x"},
		CreatedAt:  pickedAt,
		PickupBy: map[string]handoffschema.RecipientStatus{
			"dev@x": {State: handoffschema.StatePicked, PickedAt: &pickedAt},
			"ops@x": {State: handoffschema.StatePending},
		},
	}

	out := Format(st, Options{Mode: ModeCLI})
	for _, want := range []string{
		"recipients: dev@x, ops@x",
		"pickup_by :",
		"dev@x: picked @ 2026-07-09T08:30:00Z",
		"ops@x: pending",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("status output missing %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "recipient :") || strings.Contains(out, "picked    :") {
		t.Fatalf("multi-recipient output should not use single-recipient labels:\n%s", out)
	}
}

func TestFormatMarkdownMultiRecipientShowsEveryPickupSlot(t *testing.T) {
	pickedAt := time.Date(2026, 7, 9, 8, 30, 0, 0, time.UTC)
	st := &handoffschema.Status{
		ID:         "h_team",
		State:      handoffschema.StatePending,
		Sender:     "owner@x",
		Recipients: []string{"dev@x", "ops@x"},
		CreatedAt:  pickedAt,
		PickupBy: map[string]handoffschema.RecipientStatus{
			"dev@x": {State: handoffschema.StatePicked, PickedAt: &pickedAt},
			"ops@x": {State: handoffschema.StatePending},
		},
	}

	out := Format(st, Options{Mode: ModeMarkdown})
	for _, want := range []string{
		"- recipients: `dev@x`, `ops@x`",
		"- pickup_by:",
		"- `dev@x`: picked at 2026-07-09 08:30:00 UTC",
		"- `ops@x`: pending",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("status output missing %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "- recipient:") || strings.Contains(out, "- picked:") {
		t.Fatalf("multi-recipient output should not use single-recipient labels:\n%s", out)
	}
}
