package setup

import (
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestResolveMCPBinary_PrefersSibling(t *testing.T) {
	dir := t.TempDir()
	cli := filepath.Join(dir, "cc-handoff")
	mcp := filepath.Join(dir, "cc-handoff-mcp")
	if err := os.WriteFile(cli, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(mcp, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := ResolveMCPBinary(cli)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if got != mcp {
		t.Errorf("got %q, want sibling %q", got, mcp)
	}
}

func TestResolveMCPBinary_NoneAvailable(t *testing.T) {
	dir := t.TempDir()
	cli := filepath.Join(dir, "cc-handoff")
	if err := os.WriteFile(cli, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", "/nonexistent-dir-cc-handoff-test")
	if _, err := ResolveMCPBinary(cli); err == nil {
		t.Errorf("expected error when no mcp binary found")
	}
}

type capturedCall struct {
	name string
	args []string
}

func TestRegister_CallsRemoveThenAdd(t *testing.T) {
	var calls []capturedCall
	saved := execCommand
	defer func() { execCommand = saved }()
	execCommand = func(ctx context.Context, name string, args ...string) *exec.Cmd {
		calls = append(calls, capturedCall{name: name, args: args})
		return exec.CommandContext(ctx, "/usr/bin/true")
	}

	err := Register(context.Background(), MCPRegisterOptions{
		BinPath: "/usr/local/bin/cc-handoff-mcp",
	}, io.Discard)
	if err != nil {
		t.Fatalf("Register: %v", err)
	}

	if len(calls) != 2 {
		t.Fatalf("expected 2 calls, got %d: %v", len(calls), calls)
	}

	want := []string{"mcp", "remove", "cc-handoff", "--scope", "user"}
	if !equalSlice(calls[0].args, want) {
		t.Errorf("call 1 args = %v, want %v", calls[0].args, want)
	}

	want2 := []string{"mcp", "add", "--scope", "user", "--transport", "stdio", "cc-handoff", "--", "/usr/local/bin/cc-handoff-mcp"}
	if !equalSlice(calls[1].args, want2) {
		t.Errorf("call 2 args = %v, want %v", calls[1].args, want2)
	}
}

func TestRegister_RemoveFailureIsIgnored(t *testing.T) {
	var calls int
	saved := execCommand
	defer func() { execCommand = saved }()
	execCommand = func(ctx context.Context, name string, args ...string) *exec.Cmd {
		calls++
		if calls == 1 {
			return exec.CommandContext(ctx, "/usr/bin/false")
		}
		return exec.CommandContext(ctx, "/usr/bin/true")
	}
	err := Register(context.Background(), MCPRegisterOptions{
		BinPath: "/usr/local/bin/cc-handoff-mcp",
	}, io.Discard)
	if err != nil {
		t.Errorf("expected nil err when only remove fails, got %v", err)
	}
}

func TestRegister_AddFailurePropagates(t *testing.T) {
	var calls int
	saved := execCommand
	defer func() { execCommand = saved }()
	execCommand = func(ctx context.Context, name string, args ...string) *exec.Cmd {
		calls++
		return exec.CommandContext(ctx, "/usr/bin/false")
	}
	err := Register(context.Background(), MCPRegisterOptions{
		BinPath: "/usr/local/bin/cc-handoff-mcp",
	}, io.Discard)
	if err == nil {
		t.Errorf("expected add failure to propagate")
	}
}

func TestRegister_RequiresBinPath(t *testing.T) {
	if err := Register(context.Background(), MCPRegisterOptions{}, io.Discard); err == nil {
		t.Errorf("expected error when BinPath is empty")
	}
}

func TestRegisterCodex_CallsRemoveThenAdd(t *testing.T) {
	var calls []capturedCall
	saved := execCommand
	defer func() { execCommand = saved }()
	execCommand = func(ctx context.Context, name string, args ...string) *exec.Cmd {
		calls = append(calls, capturedCall{name: name, args: args})
		return exec.CommandContext(ctx, "/usr/bin/true")
	}

	err := RegisterCodex(context.Background(), MCPRegisterOptions{
		BinPath: "/usr/local/bin/cc-handoff-mcp",
	}, io.Discard)
	if err != nil {
		t.Fatalf("RegisterCodex: %v", err)
	}

	if len(calls) != 2 {
		t.Fatalf("expected 2 calls, got %d: %v", len(calls), calls)
	}

	if calls[0].name != "codex" || !equalSlice(calls[0].args, []string{"mcp", "remove", "cc-handoff"}) {
		t.Errorf("call 1 = %s %v", calls[0].name, calls[0].args)
	}
	if calls[1].name != "codex" || !equalSlice(calls[1].args, []string{"mcp", "add", "cc-handoff", "--", "/usr/local/bin/cc-handoff-mcp"}) {
		t.Errorf("call 2 = %s %v", calls[1].name, calls[1].args)
	}
}

func TestRegisterCodex_CustomName(t *testing.T) {
	var calls []capturedCall
	saved := execCommand
	defer func() { execCommand = saved }()
	execCommand = func(ctx context.Context, name string, args ...string) *exec.Cmd {
		calls = append(calls, capturedCall{name: name, args: args})
		return exec.CommandContext(ctx, "/usr/bin/true")
	}
	err := RegisterCodex(context.Background(), MCPRegisterOptions{
		BinPath: "/x",
		Name:    "alt",
	}, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if calls[0].args[2] != "alt" || calls[1].args[2] != "alt" {
		t.Errorf("custom name not propagated: %v", calls)
	}
}

func TestRegisterCodex_AddFailurePropagates(t *testing.T) {
	saved := execCommand
	defer func() { execCommand = saved }()
	execCommand = func(ctx context.Context, name string, args ...string) *exec.Cmd {
		return exec.CommandContext(ctx, "/usr/bin/false")
	}
	err := RegisterCodex(context.Background(), MCPRegisterOptions{
		BinPath: "/usr/local/bin/cc-handoff-mcp",
	}, io.Discard)
	if err == nil {
		t.Errorf("expected add failure to propagate")
	}
}

func TestRegisterCodex_RequiresBinPath(t *testing.T) {
	if err := RegisterCodex(context.Background(), MCPRegisterOptions{}, io.Discard); err == nil {
		t.Errorf("expected error when BinPath is empty")
	}
}

func TestRegister_CustomScopeAndName(t *testing.T) {
	var calls []capturedCall
	saved := execCommand
	defer func() { execCommand = saved }()
	execCommand = func(ctx context.Context, name string, args ...string) *exec.Cmd {
		calls = append(calls, capturedCall{name: name, args: args})
		return exec.CommandContext(ctx, "/usr/bin/true")
	}
	err := Register(context.Background(), MCPRegisterOptions{
		BinPath: "/x",
		Scope:   "project",
		Name:    "alt",
	}, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if calls[0].args[2] != "alt" || calls[0].args[4] != "project" {
		t.Errorf("remove args wrong: %v", calls[0].args)
	}
	if calls[1].args[3] != "project" || calls[1].args[6] != "alt" {
		t.Errorf("add args wrong: %v", calls[1].args)
	}
}

func equalSlice(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
