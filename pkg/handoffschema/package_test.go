package handoffschema

import (
	"reflect"
	"testing"
)

func TestDedupeIdentitiesTrimsAndPreservesOrder(t *testing.T) {
	got := DedupeIdentities([]string{" backend ", "", "frontend", "backend", " frontend "})
	want := []string{"backend", "frontend"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("DedupeIdentities = %#v, want %#v", got, want)
	}
}

func TestEffectiveRecipientsNormalizesScalarAndList(t *testing.T) {
	if got := (&Package{Recipient: " backend "}).EffectiveRecipients(); !reflect.DeepEqual(got, []string{"backend"}) {
		t.Fatalf("scalar recipients = %#v", got)
	}
	if got := (&Package{Recipients: []string{" backend ", "backend", " frontend "}}).EffectiveRecipients(); !reflect.DeepEqual(got, []string{"backend", "frontend"}) {
		t.Fatalf("multi recipients = %#v", got)
	}
}
