package agent

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/cc-collaboration/internal/setup"
)

// codexAgent drives OpenAI's Codex CLI:
//   - non-interactive prompt:  codex exec "<prompt body>"   (positional, not -p)
//   - MCP register:            codex mcp add <name> -- <bin>
//   - workflow prompts:        $CODEX_HOME/skills/cc-handoff/SKILL.md
//     plus references/*.md, invoked by natural language ("use cc-handoff …")
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
	dest, err := codexSkillDir()
	if err != nil {
		return setup.CopyResult{}, err
	}
	res, err := setup.CopyCodexSkill(dest, version, prompt, out)
	if err == nil {
		fmt.Fprintf(out, "  ✓ installed cc-handoff Codex skill at %s\n", dest)
		fmt.Fprintln(out, "    Restart Codex, then ask it to use the cc-handoff skill (for example: \"use cc-handoff to handoff this API change\").")
	}
	return res, err
}

func (codexAgent) RegisterMCP(ctx context.Context, opts setup.MCPRegisterOptions, out io.Writer) error {
	return setup.RegisterCodex(ctx, opts, out)
}

func codexSkillDir() (string, error) {
	home := os.Getenv("CODEX_HOME")
	if home == "" {
		userHome, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolve home directory for Codex skill install: %w", err)
		}
		home = filepath.Join(userHome, ".codex")
	}
	return filepath.Join(home, "skills", "cc-handoff"), nil
}
