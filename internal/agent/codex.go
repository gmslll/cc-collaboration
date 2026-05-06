package agent

import (
	"context"
	"errors"
	"fmt"
	"io"

	"github.com/cc-collaboration/internal/setup"
)

// codexAgent drives OpenAI's Codex CLI:
//   - non-interactive prompt:  codex exec "<prompt body>"   (positional, not -p)
//   - MCP register:            edit ~/.codex/config.toml manually
//     (the [mcp_servers.<name>] block; printing the
//     snippet beats automated TOML editing, which would
//     clobber comments and formatting in the user's file)
//   - slash commands:          n/a — Codex has no slash command mechanism;
//     users invoke the MCP tools directly
//   - project instructions:    AGENTS.md (industry standard adopted by Codex,
//     Cursor, Aider, GitHub Copilot, …)
type codexAgent struct{}

func (codexAgent) Name() string    { return "codex" }
func (codexAgent) CLI() string     { return "codex" }
func (codexAgent) Available() bool { return onPath("codex") }

func (codexAgent) POSIXPromptCmd(cwd, promptFile string) string {
	return "cd " + POSIXSingleQuote(cwd) +
		` && codex exec "$(cat ` + POSIXSingleQuote(promptFile) + `)"`
}

func (codexAgent) PowerShellPromptCmd(cwd, promptFile string) string {
	return "Set-Location -LiteralPath " + PSSingleQuote(cwd) +
		"; codex exec (Get-Content -Raw -LiteralPath " + PSSingleQuote(promptFile) + ")"
}

func (codexAgent) InstructionsFile() (string, string) {
	return "AGENTS.md", instructionsSnippet
}

func (codexAgent) SupportsCommands() bool { return false }

func (codexAgent) SupportsHooks() bool { return false }

func (codexAgent) InstallCommands(_, _ string, _ setup.PromptFunc, _ io.Writer) (setup.CopyResult, error) {
	return setup.CopyResult{}, nil
}

// RegisterMCP prints the TOML snippet the user should append to
// ~/.codex/config.toml. We deliberately do NOT auto-edit the file: TOML
// libraries don't preserve comments or layout, so a round-trip would clobber
// the user's other entries. The snippet is short enough to copy-paste.
func (codexAgent) RegisterMCP(_ context.Context, opts setup.MCPRegisterOptions, out io.Writer) error {
	if opts.BinPath == "" {
		return errors.New("MCPRegisterOptions.BinPath is required")
	}
	if out == nil {
		out = io.Discard
	}
	name := opts.Name
	if name == "" {
		name = "cc-handoff"
	}
	fmt.Fprintln(out, "agent=codex: append this to ~/.codex/config.toml then restart codex:")
	fmt.Fprintln(out)
	fmt.Fprintf(out, "[mcp_servers.%s]\n", name)
	fmt.Fprintf(out, "command = %q\n", opts.BinPath)
	fmt.Fprintln(out, "args = []")
	return nil
}
