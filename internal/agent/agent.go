// Package agent abstracts the AI coding agent (Claude Code, OpenAI Codex CLI,
// etc.) that cc-handoff drives — auto-launching on urgent handoffs, registering
// the cc-handoff MCP server, installing slash command templates, and writing
// project-level usage instructions.
//
// Each agent's quirks live in its own file (claude.go, codex.go, manual.go).
// The cc-handoff core only talks to the Agent interface, so adding a new
// agent (Aider, Cursor, Cline, …) is a matter of writing one adapter.
package agent

import (
	"context"
	"fmt"
	"io"
	"os/exec"

	"github.com/cc-collaboration/internal/setup"
)

// Agent is the per-tool adapter cc-handoff uses to spawn prompts, register
// the MCP server, copy slash commands, and emit project-level usage notes.
//
// All methods MUST be safe to call when the agent's CLI is not on PATH —
// they return errors or no-op as appropriate. Available() lets callers gate
// behavior on actual presence (e.g. init prints a different message when the
// chosen agent isn't installed yet).
type Agent interface {
	// Name is the stable identifier persisted in user config ("claude",
	// "codex", "manual"). Resolve(name) maps back to the implementation.
	Name() string

	// CLI returns the binary name on PATH (e.g. "claude", "codex"). manual
	// returns "".
	CLI() string

	// Available reports whether CLI() resolves on PATH right now.
	Available() bool

	// POSIXPromptCmd returns a single-line bash/zsh command that, when
	// executed in a fresh shell, cd's into cwd and runs the agent.
	//
	//   preLaunch: optional shell snippet inserted between the cd and the
	//              agent invocation (e.g. "clset 6" to switch OAuth account).
	//   interactive: when true, start the agent without a prompt arg — the
	//                caller is expected to inject promptFile content via the
	//                terminal app's API after the REPL is ready. When false,
	//                the agent runs one-shot on the file's contents and exits.
	POSIXPromptCmd(cwd, promptFile, preLaunch string, interactive bool) string

	// PowerShellPromptCmd is the same as POSIXPromptCmd but for PowerShell.
	PowerShellPromptCmd(cwd, promptFile, preLaunch string, interactive bool) string

	// InstructionsFile returns (filename, snippet) describing where to write
	// the cc-handoff usage instructions and what to put in them. filename is
	// relative to repo root ("CLAUDE.md", "AGENTS.md"); empty string means
	// the agent does not consume a project-level instructions file (manual).
	InstructionsFile() (filename, snippet string)

	// SupportsCommands reports whether InstallCommands actually does
	// anything for this agent. Init uses this to decide whether to even
	// pose the "install slash commands?" question — calling InstallCommands
	// just to discover it's a no-op is wasteful (Claude's implementation
	// would do real disk I/O on every probe).
	SupportsCommands() bool

	// SupportsHooks reports whether the agent has a Claude-Code-style
	// hook system (Stop, PreToolUse, etc.). cc-handoff's wake-on-comment
	// installs a Stop hook only when this returns true.
	SupportsHooks() bool

	// InstallCommands materializes any per-agent slash command / prompt
	// templates into the repo. No-op for agents whose SupportsCommands
	// returns false (codex, manual).
	InstallCommands(repoRoot, version string, prompt setup.PromptFunc, out io.Writer) (setup.CopyResult, error)

	// RegisterMCP wires cc-handoff-mcp into the agent's MCP config, or
	// prints the snippet the user should paste manually when automatic
	// registration would clobber user-managed config files. Always writes
	// human-readable status to out.
	RegisterMCP(ctx context.Context, opts setup.MCPRegisterOptions, out io.Writer) error
}

// Resolve returns the Agent for the given name. Empty name is treated as
// "claude" for backwards compatibility with installs predating multi-agent
// support.
func Resolve(name string) (Agent, error) {
	switch name {
	case "", "claude":
		return claudeAgent{}, nil
	case "codex":
		return codexAgent{}, nil
	case "manual":
		return manualAgent{}, nil
	default:
		return nil, fmt.Errorf("unknown agent %q (want claude, codex, or manual)", name)
	}
}

// Detect picks the first non-manual agent whose CLI is on PATH (priority
// order matches All: claude → codex). Falls back to manual when nothing is
// installed. Used by init when the user hasn't specified --agent.
func Detect() Agent {
	for _, a := range All() {
		if a.Name() == "manual" {
			continue
		}
		if a.Available() {
			return a
		}
	}
	return manualAgent{}
}

// All returns every known agent in display order (for `cc-handoff init`'s
// interactive picker and similar listing UIs). Manual is always last.
func All() []Agent {
	return []Agent{claudeAgent{}, codexAgent{}, manualAgent{}}
}

// onPath is a tiny helper agents use in Available(); inlined to keep the
// per-agent files free of imports they don't otherwise need.
func onPath(bin string) bool {
	_, err := exec.LookPath(bin)
	return err == nil
}
