package agent

import (
	"context"
	"io"
	"path/filepath"

	"github.com/cc-collaboration/internal/setup"
)

// codexAgent drives OpenAI's Codex CLI:
//   - non-interactive prompt:  codex exec "<prompt body>"   (positional, not -p)
//   - MCP register:            codex mcp add <name> -- <bin>
//   - commands:                .codex/plugins/cc-handoff/commands/*.md
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
	dest := filepath.Join(repoRoot, ".codex", "plugins", "cc-handoff")
	return setup.CopyCodexPlugin(dest, version, prompt, out)
}

func (codexAgent) RegisterMCP(ctx context.Context, opts setup.MCPRegisterOptions, out io.Writer) error {
	return setup.RegisterCodex(ctx, opts, out)
}
