package main

import (
	"context"
	"strings"
	"testing"
)

func TestResolveSubmitRecipientsNormalizesDirectTarget(t *testing.T) {
	recipients, err := resolveSubmitRecipients(
		context.Background(),
		nil,
		" sender@x ",
		" receiver@x ",
		"   ",
		"",
		"   ",
	)
	if err != nil {
		t.Fatalf("resolveSubmitRecipients returned error: %v", err)
	}
	if len(recipients) != 1 || recipients[0] != "receiver@x" {
		t.Fatalf("recipients = %#v, want receiver@x", recipients)
	}
}

func TestResolveSubmitRecipientsMemberStillRequiresTeamTarget(t *testing.T) {
	_, err := resolveSubmitRecipients(
		context.Background(),
		nil,
		"sender@x",
		"receiver@x",
		"",
		"",
		" member@x ",
	)
	if err == nil || !strings.Contains(err.Error(), "--member requires") {
		t.Fatalf("error = %v, want --member requires", err)
	}
}

func TestResolveSubmitRecipientsRejectsSelfAfterTrimming(t *testing.T) {
	_, err := resolveSubmitRecipients(
		context.Background(),
		nil,
		" sender@x ",
		"sender@x",
		"",
		"",
		"",
	)
	if err == nil || !strings.Contains(err.Error(), "cannot send a handoff to yourself") {
		t.Fatalf("error = %v, want self-send rejection", err)
	}
}
