package agent

import (
	"context"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"

	"github.com/cc-collaboration/internal/setup"
)

// codexAgent drives OpenAI's Codex CLI:
//   - non-interactive prompt:  codex exec "<prompt body>"   (positional, not -p)
//   - MCP register:            codex mcp add <name> -- <bin>
//   - commands:                .codex/.agents/plugins/marketplace.json
//     plus .codex/plugins/cc-handoff/commands/*.md, installed through
//     codex plugin marketplace/add when available
//   - project instructions:    AGENTS.md (industry standard adopted by Codex,
//     Cursor, Aider, GitHub Copilot, …)
type codexAgent struct{}

func (codexAgent) Name() string    { return "codex" }
func (codexAgent) CLI() string     { return "codex" }
func (codexAgent) Available() bool { return onPath("codex") }

func (codexAgent) POSIXPromptCmd(cwd, promptFile, preLaunch string, interactive bool) string {
	invocation := "codex"
	if !interactive {
		invocation = `codex exec "$(cat ` + POSIXSingleQuote(promptFile) + `)"`
	}
	return posixCompose(cwd, preLaunch, invocation)
}

func (codexAgent) PowerShellPromptCmd(cwd, promptFile, preLaunch string, interactive bool) string {
	invocation := "codex"
	if !interactive {
		invocation = "codex exec (Get-Content -Raw -LiteralPath " + PSSingleQuote(promptFile) + ")"
	}
	return psCompose(cwd, preLaunch, invocation)
}

func (codexAgent) InstructionsFile() (string, string) {
	return "AGENTS.md", instructionsSnippet
}

func (codexAgent) SupportsCommands() bool { return true }

func (codexAgent) SupportsHooks() bool { return false }

func (codexAgent) InstallCommands(repoRoot, version string, prompt setup.PromptFunc, out io.Writer) (setup.CopyResult, error) {
	if out == nil {
		out = io.Discard
	}
	dest := filepath.Join(repoRoot, ".codex")
	res, err := setup.CopyCodexPlugin(dest, version, prompt, out)
	if err != nil {
		return res, err
	}
	if err := installCodexPlugin(repoRoot, out); err != nil {
		fmt.Fprintf(out, "  ! codex plugin install skipped: %v\n", err)
		fmt.Fprintln(out, "    MCP tools are still available; restart codex and ask it to call submit_handoff / pickup_handoff directly.")
	}
	return res, nil
}

func (codexAgent) RegisterMCP(ctx context.Context, opts setup.MCPRegisterOptions, out io.Writer) error {
	return setup.RegisterCodex(ctx, opts, out)
}

func installCodexPlugin(repoRoot string, out io.Writer) error {
	if !onPath("codex") {
		return fmt.Errorf("codex CLI not found on PATH")
	}
	marketplace := filepath.Join(repoRoot, ".codex")
	exec.Command("codex", "plugin", "marketplace", "remove", "cc-handoff-local").Run()
	if addOut, err := exec.Command("codex", "plugin", "marketplace", "add", marketplace).CombinedOutput(); err != nil {
		return fmt.Errorf("codex plugin marketplace add: %w (output: %s)", err, string(addOut))
	}
	if addOut, err := exec.Command("codex", "plugin", "add", "cc-handoff@cc-handoff-local").CombinedOutput(); err != nil {
		return fmt.Errorf("codex plugin add: %w (output: %s)", err, string(addOut))
	}
	fmt.Fprintln(out, "  ✓ installed cc-handoff Codex plugin (marketplace=cc-handoff-local)")
	return nil
}
