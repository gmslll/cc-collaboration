package handoffschema

import (
	"reflect"
	"testing"
	"time"
)

func TestNewCapsuleListItemProjectsLibraryMetadata(t *testing.T) {
	createdAt := time.Date(2026, time.July, 1, 2, 3, 4, 0, time.UTC)
	updatedAt := createdAt.Add(time.Hour)
	pkg := &Package{
		ID:        "cap-1",
		Sender:    "owner@example.com",
		CreatedAt: createdAt,
		SummaryMD: "Release helper\nTracks the release and verifies artifacts.",
		Repo:      Repo{Name: "cc-collaboration"},
		Capsule: &Capsule{
			SourceAgent:   "codex",
			Visibility:    CapsulePublic,
			ProjectID:     "project-1",
			HasTranscript: true,
			HasPersona:    true,
			UpdatedAt:     updatedAt,
		},
		Attachments: []Attachment{
			{Name: "release" + CapsuleSkillPackSuffix},
			{Name: CapsulePersonaName},
			{Name: "review" + CapsuleSkillPackSuffix},
		},
	}

	item := NewCapsuleListItem(pkg)
	if item.Headline != "Release helper" || item.Summary != pkg.SummaryMD {
		t.Fatalf("summary projection = (%q, %q)", item.Headline, item.Summary)
	}
	if item.SkillPackCount != 2 {
		t.Fatalf("skill pack count = %d, want 2", item.SkillPackCount)
	}
	if item.ProjectID != "project-1" {
		t.Fatalf("project id = %q, want project-1", item.ProjectID)
	}
	if !item.UpdatedAt.Equal(updatedAt) {
		t.Fatalf("updated_at = %s, want %s", item.UpdatedAt, updatedAt)
	}

	pkg.Capsule.UpdatedAt = time.Time{}
	if fallback := NewCapsuleListItem(pkg).UpdatedAt; !fallback.Equal(createdAt) {
		t.Fatalf("legacy updated_at fallback = %s, want %s", fallback, createdAt)
	}
}

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
