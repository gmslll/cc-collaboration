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
//   - workflow prompts:        $CODEX_HOME/skills/cc-handoff-*/SKILL.md,
//     invoked by natural language ("use cc-handoff-handoff …")
//   - project instructions:    AGENTS.md (industry standard adopted by Codex,
//     Cursor, Aider, GitHub Copilot, …)
type codexAgent struct{}

func (codexAgent) Name() string    { return "codex" }
func (codexAgent) CLI() string     { return "codex" }
func (codexAgent) Available() bool { return onPath("codex") }

// codexBypass vouches for cc-handoff's own bus hook so codex doesn't show its
// blocking "trust hooks" dialog (which would stall a non-interactive launch).
// Global flag → goes right after `codex`, before any subcommand.
const codexBypass = "codex --dangerously-bypass-hook-trust"

func (codexAgent) POSIXPromptCmd(cwd, promptFile, preLaunch string, interactive bool) string {
	invocation := codexBypass
	if !interactive {
		invocation = codexBypass + ` exec "$(cat ` + POSIXSingleQuote(promptFile) + `)"`
	}
	return posixCompose(cwd, preLaunch, invocation)
}

func (codexAgent) PowerShellPromptCmd(cwd, promptFile, preLaunch string, interactive bool) string {
	invocation := codexBypass
	if !interactive {
		invocation = codexBypass + " exec (Get-Content -Raw -LiteralPath " + PSSingleQuote(promptFile) + ")"
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
	dest, err := codexSkillsDir()
	if err != nil {
		return setup.CopyResult{}, err
	}
	res, err := setup.CopyCodexSkills(dest, version, prompt, out)
	if err == nil {
		fmt.Fprintf(out, "  ✓ installed cc-handoff Codex skills under %s\n", dest)
		fmt.Fprintln(out, "    Restart Codex, then ask it to use a workflow skill (for example: \"use cc-handoff-handoff for this API change\").")
	}
	return res, err
}

func (codexAgent) RegisterMCP(ctx context.Context, opts setup.MCPRegisterOptions, out io.Writer) error {
	return setup.RegisterCodex(ctx, opts, out)
}

// InstallBusHooks merges the bus PostToolUse + Stop hooks into
// $CODEX_HOME/hooks.json (default ~/.codex/hooks.json). Codex's features.hooks
// defaults on, so this fires in every Codex session — the $CC_BUS_DIR env guard
// in the command keeps it a no-op outside app-spawned sessions. (Note: an
// automated/non-interactive Codex launch may also need
// --dangerously-bypass-hook-trust; the desktop app passes it.)
func (a codexAgent) InstallBusHooks(out io.Writer) error {
	path, err := a.BusHookConfigPath()
	if err != nil {
		return err
	}
	res, err := setup.EnsureCodexBusHooks(path)
	if err != nil {
		return err
	}
	reportBusHook(out, "codex", path, res)
	return nil
}

// BusHookConfigPath is $CODEX_HOME/hooks.json (default ~/.codex/hooks.json).
func (codexAgent) BusHookConfigPath() (string, error) {
	home, err := codexHome()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "hooks.json"), nil
}

// codexHome resolves $CODEX_HOME (default ~/.codex), the root for Codex's
// config, skills, and hooks.
func codexHome() (string, error) {
	if home := os.Getenv("CODEX_HOME"); home != "" {
		return home, nil
	}
	userHome, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home directory for Codex: %w", err)
	}
	return filepath.Join(userHome, ".codex"), nil
}

func codexSkillsDir() (string, error) {
	home, err := codexHome()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "skills"), nil
}
