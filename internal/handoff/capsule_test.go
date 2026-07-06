package handoff

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"

	"github.com/cc-collaboration/pkg/handoffschema"
)

// TestBuildCapsule_TeamScoped confirms a capsule assembles the reserved payload
// attachments with correct integrity metadata, derives the HasTranscript /
// HasPersona flags from which payloads are present, and leaves ID/CreatedAt
// unset for the relay to stamp.
func TestBuildCapsule_TeamScoped(t *testing.T) {
	transcript := []byte(`{"type":"user","text":"hi"}` + "\n")
	transcriptTxt := []byte("USER: hi\nASSISTANT: hello\n")
	persona := []byte("# 专职修 windows 闪退\n规矩: ...\n")

	pkg, attachments, err := BuildCapsule(CapsuleOptions{
		RepoName:        "demo",
		Sender:          "alice",
		Visibility:      handoffschema.CapsulePublic,
		SourceAgent:     "claude",
		OriginSessionID: "sess-abc",
		SummaryMD:       "把摸透 windows 闪退的会话冻结成胶囊",
		TranscriptJSONL: transcript,
		TranscriptText:  transcriptTxt,
		Persona:         persona,
	})
	if err != nil {
		t.Fatalf("BuildCapsule: %v", err)
	}

	if pkg.Kind != handoffschema.KindCapsule {
		t.Errorf("Kind = %q, want %q", pkg.Kind, handoffschema.KindCapsule)
	}
	if pkg.ID != "" || !pkg.CreatedAt.IsZero() {
		t.Errorf("ID/CreatedAt should be relay-stamped, got ID=%q CreatedAt=%v", pkg.ID, pkg.CreatedAt)
	}
	if pkg.Capsule == nil {
		t.Fatal("Capsule metadata is nil")
	}
	c := pkg.Capsule
	if c.SourceAgent != "claude" || c.OriginSessionID != "sess-abc" || c.Visibility != handoffschema.CapsulePublic {
		t.Errorf("Capsule meta mismatch: %+v", c)
	}
	if !c.HasTranscript || !c.HasPersona {
		t.Errorf("HasTranscript=%v HasPersona=%v, want both true", c.HasTranscript, c.HasPersona)
	}

	// Every reserved payload we passed must appear as an attachment with a
	// matching sha256 + size so the receiver can verify before download.
	want := map[string][]byte{
		handoffschema.CapsuleTranscriptJSONLName: transcript,
		handoffschema.CapsuleTranscriptTextName:  transcriptTxt,
		handoffschema.CapsulePersonaName:         persona,
	}
	if len(attachments) != len(want) {
		t.Errorf("attachments count = %d, want %d", len(attachments), len(want))
	}
	byName := map[string]handoffschema.Attachment{}
	for _, a := range pkg.Attachments {
		byName[a.Name] = a
	}
	for name, body := range want {
		if got, ok := attachments[name]; !ok || string(got) != string(body) {
			t.Errorf("attachment blob %q missing or wrong", name)
		}
		meta, ok := byName[name]
		if !ok {
			t.Errorf("attachment meta %q missing from pkg.Attachments", name)
			continue
		}
		sum := sha256.Sum256(body)
		if meta.SHA256 != hex.EncodeToString(sum[:]) || meta.Size != len(body) {
			t.Errorf("attachment %q meta mismatch: %+v", name, meta)
		}
	}
	if _, ok := attachments[handoffschema.CapsuleSeedName]; ok {
		t.Error("seed was not supplied but landed as an attachment")
	}
}

// TestBuildCapsule_PersonaOnly confirms a distilled-role-only capsule is valid
// (② without ①) and reports HasTranscript=false.
func TestBuildCapsule_PersonaOnly(t *testing.T) {
	pkg, _, err := BuildCapsule(CapsuleOptions{
		RepoName:    "demo",
		Sender:      "alice",
		SourceAgent: "codex",
		Persona:     []byte("role"),
	})
	if err != nil {
		t.Fatalf("BuildCapsule: %v", err)
	}
	if pkg.Capsule.HasTranscript || !pkg.Capsule.HasPersona {
		t.Errorf("want persona-only, got HasTranscript=%v HasPersona=%v",
			pkg.Capsule.HasTranscript, pkg.Capsule.HasPersona)
	}
	// Visibility defaults to private (via EffectiveVisibility) when unset.
	if pkg.Capsule.EffectiveVisibility() != handoffschema.CapsulePrivate {
		t.Errorf("default visibility = %q, want private", pkg.Capsule.EffectiveVisibility())
	}
}

func TestBuildCapsule_Rejections(t *testing.T) {
	cases := []struct {
		name string
		opts CapsuleOptions
	}{
		{"bad source_agent", CapsuleOptions{RepoName: "d", Sender: "a", SourceAgent: "gemini", Persona: []byte("x")}},
		{"empty capsule", CapsuleOptions{RepoName: "d", Sender: "a", SourceAgent: "claude"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, _, err := BuildCapsule(tc.opts); err == nil {
				t.Errorf("expected error for %s, got nil", tc.name)
			}
		})
	}
}
