package agent

import (
	"context"
	"errors"
	"fmt"
	"io"

	"github.com/cc-collaboration/internal/setup"
)

// manualAgent is the catch-all for users who don't want cc-handoff touching
// their agent config — or who use an agent we don't have an adapter for yet.
// The pure CLI flow (cc-handoff submit / list / pickup / comment) still works
// regardless; only the convenience integrations (auto-launch, MCP register,
// slash commands) are unavailable.
type manualAgent struct{}

func (manualAgent) Name() string    { return "manual" }
func (manualAgent) CLI() string     { return "" }
func (manualAgent) Available() bool { return true }

func (manualAgent) POSIXPromptCmd(_, _ string) string {
	return "echo 'cc-handoff: agent=manual; auto-launch is disabled, run your agent on the prompt file yourself'"
}

func (manualAgent) PowerShellPromptCmd(_, _ string) string {
	return "Write-Host 'cc-handoff: agent=manual; auto-launch is disabled, run your agent on the prompt file yourself'"
}

func (manualAgent) InstructionsFile() (string, string) { return "", "" }

func (manualAgent) SupportsCommands() bool { return false }

func (manualAgent) SupportsHooks() bool { return false }

func (manualAgent) InstallCommands(_, _ string, _ setup.PromptFunc, _ io.Writer) (setup.CopyResult, error) {
	return setup.CopyResult{}, nil
}

func (manualAgent) RegisterMCP(_ context.Context, opts setup.MCPRegisterOptions, out io.Writer) error {
	if opts.BinPath == "" {
		return errors.New("MCPRegisterOptions.BinPath is required")
	}
	if out == nil {
		out = io.Discard
	}
	fmt.Fprintln(out, "agent=manual: register cc-handoff-mcp with your tool yourself.")
	fmt.Fprintln(out, "It is a stdio MCP server; the binary is:")
	fmt.Fprintf(out, "  %s\n", opts.BinPath)
	return nil
}
