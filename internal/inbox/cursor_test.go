package inbox

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadCursorMissingFile(t *testing.T) {
	dir := t.TempDir()
	c, exists, err := LoadCursor(dir)
	if err != nil {
		t.Fatalf("LoadCursor on empty repo: %v", err)
	}
	if exists {
		t.Errorf("exists=true on empty repo")
	}
	if c.LastCommentID != 0 {
		t.Errorf("expected zero cursor, got %+v", c)
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	dir := t.TempDir()
	want := WatchCursor{LastCommentID: 42}
	if err := SaveCursor(dir, want); err != nil {
		t.Fatalf("SaveCursor: %v", err)
	}
	got, exists, err := LoadCursor(dir)
	if err != nil {
		t.Fatalf("LoadCursor: %v", err)
	}
	if !exists {
		t.Errorf("exists=false after save")
	}
	if got != want {
		t.Errorf("got %+v want %+v", got, want)
	}

	// Tmp file must not be left behind.
	tmp := CursorPath(dir) + ".tmp"
	if _, err := os.Stat(tmp); !os.IsNotExist(err) {
		t.Errorf("expected no tmp file at %s", tmp)
	}
}

func TestSaveCursorAtomic(t *testing.T) {
	dir := t.TempDir()
	if err := SaveCursor(dir, WatchCursor{LastCommentID: 1}); err != nil {
		t.Fatalf("first save: %v", err)
	}
	// Corrupt the cursor file mid-flight by simulating a leftover .tmp; SaveCursor
	// should still succeed and produce a valid file.
	tmp := CursorPath(dir) + ".tmp"
	if err := os.WriteFile(tmp, []byte("not json"), 0o644); err != nil {
		t.Fatalf("seed tmp: %v", err)
	}
	if err := SaveCursor(dir, WatchCursor{LastCommentID: 99}); err != nil {
		t.Fatalf("second save: %v", err)
	}
	got, _, err := LoadCursor(dir)
	if err != nil {
		t.Fatalf("LoadCursor: %v", err)
	}
	if got.LastCommentID != 99 {
		t.Errorf("got %d want 99", got.LastCommentID)
	}
}

func TestLoadCursorBadJSON(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Dir(CursorPath(dir)), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(CursorPath(dir), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := LoadCursor(dir); err == nil {
		t.Error("expected error on bad json")
	}
}
