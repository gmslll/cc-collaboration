package setup

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// execCommand is the package-level injection point for tests. Production code
// uses exec.CommandContext; tests substitute a stub that records arguments.
var execCommand = exec.CommandContext

// CurrentBinary returns the path of the running binary with symlinks resolved.
// init.go's MCP registration and watch.go's print-unit both need it to plumb
// the absolute path of cc-handoff into Claude Code config or systemd units.
func CurrentBinary() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		return resolved, nil
	}
	return exe, nil
}

// MCPRegisterOptions controls Register's behavior.
type MCPRegisterOptions struct {
	// Scope is "user" or "project". User scope writes to ~/.claude.json so the
	// MCP server is available across all projects; project scope writes a local
	// .mcp.json. Defaults to "user".
	Scope string
	// BinPath is the absolute path to the cc-handoff-mcp binary that Claude
	// Code will spawn over stdio. Resolve via ResolveMCPBinary if blank.
	BinPath string
	// Name is the registered MCP server name. Empty means "cc-handoff".
	Name string
}

// ResolveMCPBinary returns the path to cc-handoff-mcp. Search order:
//  1. Sibling of the currently-running cc-handoff binary (same directory).
//  2. PATH lookup of "cc-handoff-mcp".
//
// Returns an empty string and a wrapped error if neither resolves.
func ResolveMCPBinary(currentBin string) (string, error) {
	if currentBin != "" {
		sib := filepath.Join(filepath.Dir(currentBin), "cc-handoff-mcp")
		if info, err := os.Stat(sib); err == nil && !info.IsDir() {
			return sib, nil
		}
	}
	if p, err := exec.LookPath("cc-handoff-mcp"); err == nil {
		return p, nil
	}
	return "", errors.New("cc-handoff-mcp not found next to cc-handoff or on PATH")
}

// Register registers cc-handoff with Claude Code's MCP config. It runs the
// equivalent of:
//
//	claude mcp remove <name> --scope <scope>     # ignore failures
//	claude mcp add --scope <scope> --transport stdio <name> -- <BinPath>
//
// This matches scripts/install-mcp.sh's behavior. Removal failure (e.g. the
// entry didn't exist) is non-fatal; only the final add error propagates.
func Register(ctx context.Context, opts MCPRegisterOptions, out io.Writer) error {
	if out == nil {
		out = io.Discard
	}
	scope := opts.Scope
	if scope == "" {
		scope = "user"
	}
	name := opts.Name
	if name == "" {
		name = "cc-handoff"
	}
	if opts.BinPath == "" {
		return errors.New("MCPRegisterOptions.BinPath is required")
	}

	rm := execCommand(ctx, "claude", "mcp", "remove", name, "--scope", scope)
	if err := rm.Run(); err != nil {
		fmt.Fprintf(out, "  · `claude mcp remove %s --scope %s` returned %v (ignored)\n", name, scope, err)
	}

	add := execCommand(ctx, "claude", "mcp", "add", "--scope", scope, "--transport", "stdio", name, "--", opts.BinPath)
	addOut, err := add.CombinedOutput()
	if err != nil {
		return fmt.Errorf("claude mcp add: %w (output: %s)", err, string(addOut))
	}
	fmt.Fprintf(out, "  ✓ registered %s MCP server (scope=%s) -> %s\n", name, scope, opts.BinPath)
	if len(addOut) > 0 {
		fmt.Fprintf(out, "    %s", indentLines(string(addOut), "    "))
	}
	return nil
}

// RegisterCodex registers cc-handoff with Codex CLI's MCP config. It runs:
//
//	codex mcp remove <name>     # ignore failures
//	codex mcp add <name> -- <BinPath>
//
// This mirrors Register's remove-then-add behavior, but uses Codex's native
// MCP subcommand instead of asking users to edit ~/.codex/config.toml.
func RegisterCodex(ctx context.Context, opts MCPRegisterOptions, out io.Writer) error {
	if out == nil {
		out = io.Discard
	}
	name := opts.Name
	if name == "" {
		name = "cc-handoff"
	}
	if opts.BinPath == "" {
		return errors.New("MCPRegisterOptions.BinPath is required")
	}

	rm := execCommand(ctx, "codex", "mcp", "remove", name)
	if err := rm.Run(); err != nil {
		fmt.Fprintf(out, "  · `codex mcp remove %s` returned %v (ignored)\n", name, err)
	}

	add := execCommand(ctx, "codex", "mcp", "add", name, "--", opts.BinPath)
	addOut, err := add.CombinedOutput()
	if err != nil {
		return fmt.Errorf("codex mcp add: %w (output: %s)", err, string(addOut))
	}
	fmt.Fprintf(out, "  ✓ registered %s MCP server for codex -> %s\n", name, opts.BinPath)
	if len(addOut) > 0 {
		fmt.Fprintf(out, "    %s", indentLines(string(addOut), "    "))
	}
	return nil
}

// indentLines prefixes each line after the first with prefix so claude CLI
// output stays visually attached to our own status lines.
func indentLines(s, prefix string) string {
	if s == "" {
		return ""
	}
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	return strings.Join(lines, "\n"+prefix) + "\n"
}
