package agent

import (
	"context"
	"io"
	"path/filepath"

	"github.com/cc-collaboration/internal/setup"
)

// claudeAgent drives Anthropic's Claude Code CLI:
//   - non-interactive prompt:  claude -p "<prompt body>"
//   - MCP register:            claude mcp add --scope user --transport stdio cc-handoff -- <bin>
//   - slash commands:          .claude/commands/{handoff,handoff-module,pickup,request}.md
//   - project instructions:    CLAUDE.md
type claudeAgent struct{}

func (claudeAgent) Name() string    { return "claude" }
func (claudeAgent) CLI() string     { return "claude" }
func (claudeAgent) Available() bool { return onPath("claude") }

func (claudeAgent) POSIXPromptCmd(cwd, promptFile, preLaunch string, interactive bool) string {
	invocation := "claude"
	if !interactive {
		invocation = `claude -p "$(cat ` + POSIXSingleQuote(promptFile) + `)"`
	}
	return posixCompose(cwd, preLaunch, invocation)
}

func (claudeAgent) PowerShellPromptCmd(cwd, promptFile, preLaunch string, interactive bool) string {
	invocation := "claude"
	if !interactive {
		invocation = "claude -p (Get-Content -Raw -LiteralPath " + PSSingleQuote(promptFile) + ")"
	}
	return psCompose(cwd, preLaunch, invocation)
}

func (claudeAgent) InstructionsFile() (string, string) {
	return "CLAUDE.md", instructionsSnippet
}

func (claudeAgent) SupportsCommands() bool { return true }

func (claudeAgent) SupportsHooks() bool { return true }

// InstallCommands copies the slash command templates into <repoRoot>/.claude/commands/.
// Conflict resolution is delegated to setup.CopyCommands via the prompt callback;
// callers pass nil prompt to make it non-interactive (skip on conflict).
func (claudeAgent) InstallCommands(repoRoot, version string, prompt setup.PromptFunc, out io.Writer) (setup.CopyResult, error) {
	dest := filepath.Join(repoRoot, ".claude", "commands")
	return setup.CopyCommands(dest, version, prompt, out)
}

func (claudeAgent) RegisterMCP(ctx context.Context, opts setup.MCPRegisterOptions, out io.Writer) error {
	return setup.Register(ctx, opts, out)
}
