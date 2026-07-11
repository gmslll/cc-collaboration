package inbox

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// TestMaterializeCapsule confirms a KindCapsule package materializes a
// loader-facing manifest.json (source tool, team scope, present payload paths)
// and a capsule-flavored prompt that advertises only the forms the payload can
// instantiate.
func TestMaterializeCapsule(t *testing.T) {
	pkg, _, err := handoff.BuildCapsule(handoff.CapsuleOptions{
		RepoName:        "demo",
		Sender:          "alice",
		Visibility:      handoffschema.CapsulePublic,
		SourceAgent:     "claude",
		OriginSessionID: "sess-abc",
		ProjectID:       "project-1",
		SummaryMD:       "冻结 windows 闪退会话",
		TranscriptJSONL: []byte("{}\n"),
		TranscriptText:  []byte("USER: hi\n"),
		Persona:         []byte("# role\n"),
	})
	if err != nil {
		t.Fatalf("BuildCapsule: %v", err)
	}
	// Relay stamps these at submit; do it by hand for the test.
	pkg.ID = "cap-1"
	pkg.CreatedAt = time.Date(2026, 7, 6, 10, 0, 0, 0, time.UTC)

	dir := t.TempDir()
	res, err := Materialize(dir, pkg, ModeDocFirst)
	if err != nil {
		t.Fatalf("Materialize: %v", err)
	}

	// manifest.json
	b, err := os.ReadFile(filepath.Join(res.Dir, "manifest.json"))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	var m CapsuleManifest
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("unmarshal manifest: %v", err)
	}
	if m.ID != "cap-1" || m.SourceAgent != "claude" || m.Visibility != handoffschema.CapsulePublic || m.ProjectID != "project-1" {
		t.Errorf("manifest identity mismatch: %+v", m)
	}
	if !m.HasTranscript || !m.HasPersona {
		t.Errorf("manifest flags: HasTranscript=%v HasPersona=%v", m.HasTranscript, m.HasPersona)
	}
	// Present payloads point under attachments/; the absent seed is not listed.
	if got := m.Payloads[handoffschema.CapsuleTranscriptJSONLName]; got != "attachments/"+handoffschema.CapsuleTranscriptJSONLName {
		t.Errorf("transcript payload path = %q", got)
	}
	if _, ok := m.Payloads[handoffschema.CapsuleSeedName]; ok {
		t.Error("absent seed should not appear in manifest payloads")
	}

	// prompt.md is capsule-flavored and offers both forms (both payloads present).
	if !strings.Contains(res.Prompt, "Session Capsule") {
		t.Errorf("prompt missing capsule header:\n%s", res.Prompt)
	}
	if strings.Contains(res.Prompt, "①不可用") || strings.Contains(res.Prompt, "②不可用") {
		t.Errorf("prompt should not mark either form unavailable when both payloads present:\n%s", res.Prompt)
	}
	if !strings.Contains(res.Prompt, "胶囊载荷") {
		t.Errorf("prompt missing payload list:\n%s", res.Prompt)
	}
}

// TestMaterializeCapsule_PersonaOnly confirms the prompt flags ① as unavailable
// when the capsule carries only a distilled persona.
func TestMaterializeCapsule_PersonaOnly(t *testing.T) {
	pkg, _, err := handoff.BuildCapsule(handoff.CapsuleOptions{
		RepoName:    "demo",
		Sender:      "alice",
		SourceAgent: "codex",
		Persona:     []byte("# role\n"),
	})
	if err != nil {
		t.Fatalf("BuildCapsule: %v", err)
	}
	pkg.ID = "cap-2"

	dir := t.TempDir()
	res, err := Materialize(dir, pkg, ModeDocFirst)
	if err != nil {
		t.Fatalf("Materialize: %v", err)
	}
	if !strings.Contains(res.Prompt, "①不可用") {
		t.Errorf("persona-only capsule should mark ① unavailable:\n%s", res.Prompt)
	}
	if strings.Contains(res.Prompt, "②不可用") {
		t.Errorf("persona-only capsule should keep ② available:\n%s", res.Prompt)
	}
}
