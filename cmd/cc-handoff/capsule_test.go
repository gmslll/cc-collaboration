package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunCapsule_Dispatch(t *testing.T) {
	ctx := context.Background()
	if err := runCapsule(ctx, nil); err == nil {
		t.Error("no subcommand should error with usage")
	}
	err := runCapsule(ctx, []string{"frobnicate"})
	if err == nil || !strings.Contains(err.Error(), "unknown capsule subcommand") {
		t.Errorf("unknown subcommand: got %v", err)
	}
}

// runCapsuleSubmit validates --source-agent before touching config/relay, so
// this is assertable without a configured environment.
func TestRunCapsuleSubmit_RequiresSourceAgent(t *testing.T) {
	err := runCapsuleSubmit(context.Background(), []string{"--public", "--persona", "/x"})
	if err == nil || !strings.Contains(err.Error(), "source-agent") {
		t.Errorf("missing --source-agent should error, got %v", err)
	}
}

func TestReadCapsuleFile(t *testing.T) {
	// Empty path → absent payload, no error.
	b, err := readCapsuleFile("")
	if err != nil || b != nil {
		t.Errorf("empty path: got (%v, %v), want (nil, nil)", b, err)
	}

	dir := t.TempDir()
	p := filepath.Join(dir, "persona.md")
	if err := os.WriteFile(p, []byte("ROLE"), 0o644); err != nil {
		t.Fatal(err)
	}
	b, err = readCapsuleFile(p)
	if err != nil || string(b) != "ROLE" {
		t.Errorf("present file: got (%q, %v)", b, err)
	}

	if _, err := readCapsuleFile(filepath.Join(dir, "missing.md")); err == nil {
		t.Error("missing file should error")
	}
}
