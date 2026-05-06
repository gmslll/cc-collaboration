package auth

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestTokensIdentitiesDedupesAndSorts(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tokens.json")
	contents := `[
		{"token":"tok-bob",         "identity":"bob@platform"},
		{"token":"tok-alice-laptop","identity":"alice@backend"},
		{"token":"tok-alice-desk",  "identity":"alice@backend"}
	]`
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}

	tk := NewTokens()
	if err := tk.LoadFile(path); err != nil {
		t.Fatalf("LoadFile: %v", err)
	}

	got := tk.Identities()
	want := []string{"alice@backend", "bob@platform"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Identities = %v, want %v", got, want)
	}
}

func TestTokensIdentitiesEmpty(t *testing.T) {
	tk := NewTokens()
	if got := tk.Identities(); len(got) != 0 {
		t.Fatalf("empty Tokens.Identities = %v, want []", got)
	}
}
