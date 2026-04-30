package inbox

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInboxDir(t *testing.T) {
	t.Run("override absolute", func(t *testing.T) {
		got := InboxDir("/repo", "/abs/inbox")
		if got != "/abs/inbox" {
			t.Errorf("absolute override not used verbatim: %q", got)
		}
	})

	t.Run("override relative", func(t *testing.T) {
		got := InboxDir("/repo", "custom/inbox")
		want := filepath.Join("/repo", "custom/inbox")
		if got != want {
			t.Errorf("relative override = %q, want %q", got, want)
		}
	})

	t.Run("legacy exists, primary missing → legacy", func(t *testing.T) {
		repo := t.TempDir()
		if err := os.MkdirAll(filepath.Join(repo, LegacyInboxDir), 0o755); err != nil {
			t.Fatal(err)
		}
		got := InboxDir(repo, "")
		want := filepath.Join(repo, LegacyInboxDir)
		if got != want {
			t.Errorf("got %q, want legacy %q", got, want)
		}
	})

	t.Run("primary exists → primary", func(t *testing.T) {
		repo := t.TempDir()
		if err := os.MkdirAll(filepath.Join(repo, PrimaryInboxDir), 0o755); err != nil {
			t.Fatal(err)
		}
		got := InboxDir(repo, "")
		want := filepath.Join(repo, PrimaryInboxDir)
		if got != want {
			t.Errorf("got %q, want primary %q", got, want)
		}
	})

	t.Run("both exist → primary wins", func(t *testing.T) {
		repo := t.TempDir()
		if err := os.MkdirAll(filepath.Join(repo, LegacyInboxDir), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Join(repo, PrimaryInboxDir), 0o755); err != nil {
			t.Fatal(err)
		}
		got := InboxDir(repo, "")
		want := filepath.Join(repo, PrimaryInboxDir)
		if got != want {
			t.Errorf("got %q, want primary %q", got, want)
		}
	})

	t.Run("neither exists → primary default", func(t *testing.T) {
		repo := t.TempDir()
		got := InboxDir(repo, "")
		want := filepath.Join(repo, PrimaryInboxDir)
		if got != want {
			t.Errorf("got %q, want primary %q", got, want)
		}
	})
}
