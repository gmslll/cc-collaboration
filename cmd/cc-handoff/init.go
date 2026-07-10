package main

import (
	"bufio"
	"cmp"
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/cc-collaboration/internal/agent"
	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/inbox"
	"github.com/cc-collaboration/internal/setup"
	"github.com/cc-collaboration/internal/version"
)

// triState captures a flag that can be unset, explicitly true, or explicitly
// false. We need this for --with-mcp / --no-mcp because boolean flags can't
// express "user didn't say either way."
type triState int

const (
	triUnset triState = iota
	triYes
	triNo
)

func parseTriState(yes, no bool, name string) (triState, error) {
	switch {
	case yes && no:
		return triUnset, fmt.Errorf("--with-%s and --no-%s are mutually exclusive", name, name)
	case yes:
		return triYes, nil
	case no:
		return triNo, nil
	default:
		return triUnset, nil
	}
}

func runInit(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("init", flag.ContinueOnError)
	relay := fs.String("relay", "", "relay URL, e.g. https://your-vps.example.com")
	token := fs.String("token", "", "bearer token issued by the relay admin")
	me := fs.String("me", "", "your identity, e.g. you@backend")
	partner := fs.String("partner", "", "optional legacy point-to-point partner identity, e.g. alex@frontend")
	repoName := fs.String("repo", "", "repo name (default: basename of repo root)")
	base := fs.String("base", "origin/main", "git base ref for diff/log")
	swagger := fs.String("swagger", "", "path to OpenAPI/Swagger file relative to repo root (optional)")
	terminalApp := fs.String("terminal", "", "terminal app for auto-launch: terminal | iterm2 (macOS) or windows-terminal | powershell (Windows)")
	agentName := fs.String("agent", "", "AI agent: claude | codex | manual (default: auto-detect on PATH)")
	nonInteractive := fs.Bool("non-interactive", false, "fail instead of prompting for missing values")

	withMCP := fs.Bool("with-mcp", false, "register cc-handoff as an MCP server with the chosen agent")
	noMCP := fs.Bool("no-mcp", false, "skip MCP server registration")
	withCommands := fs.Bool("with-commands", false, "install per-agent workflow helpers (Claude slash commands; Codex skill)")
	noCommands := fs.Bool("no-commands", false, "skip workflow helper install")
	withInstructions := fs.Bool("with-instructions", false, "append cc-handoff usage snippet to the agent's project-level instructions file (CLAUDE.md / AGENTS.md)")
	noInstructions := fs.Bool("no-instructions", false, "skip the instructions snippet")
	withWake := fs.Bool("with-wake-on-comment", false, "enable wake-on-comment: install a Claude Code Stop hook so partner replies pull this Claude session back into a turn (Claude only)")
	noWake := fs.Bool("no-wake-on-comment", false, "do not install the wake-on-comment Stop hook")

	if err := fs.Parse(args); err != nil {
		return err
	}

	mcpChoice, err := parseTriState(*withMCP, *noMCP, "mcp")
	if err != nil {
		return err
	}
	cmdsChoice, err := parseTriState(*withCommands, *noCommands, "commands")
	if err != nil {
		return err
	}
	instrChoice, err := parseTriState(*withInstructions, *noInstructions, "instructions")
	if err != nil {
		return err
	}
	wakeChoice, err := parseTriState(*withWake, *noWake, "wake-on-comment")
	if err != nil {
		return err
	}

	ag, err := resolveAgent(*agentName)
	if err != nil {
		return err
	}
	fmt.Printf("agent: %s", ag.Name())
	if !ag.Available() && ag.Name() != "manual" {
		fmt.Printf(" (CLI %q not found on PATH; pure-CLI flow still works)", ag.CLI())
	}
	fmt.Println()

	cwd, err := os.Getwd()
	if err != nil {
		return err
	}

	user, _, err := config.LoadUser()
	if err != nil {
		return err
	}
	if user == nil {
		user = &config.User{}
	}
	if *relay != "" {
		user.RelayURL = *relay
	}
	if *token != "" {
		user.Token = *token
	}
	if *me != "" {
		user.Identity = *me
	}
	if *agentName != "" {
		user.Agent = ag.Name()
	} else if user.Agent == "" {
		// First-time install with auto-detected agent: persist the
		// detection so future runs don't rely on PATH state.
		user.Agent = ag.Name()
	}

	rd := bufio.NewReader(os.Stdin)
	prompt := func(label, current string) string {
		if *nonInteractive {
			return current
		}
		if current != "" {
			fmt.Printf("%s [%s]: ", label, current)
		} else {
			fmt.Printf("%s: ", label)
		}
		line, _ := rd.ReadString('\n')
		line = strings.TrimSpace(line)
		if line == "" {
			return current
		}
		return line
	}

	user.RelayURL = prompt("Relay URL", user.RelayURL)
	user.Token = prompt("Bearer token", user.Token)
	user.Identity = prompt("Your identity (e.g. you@backend)", user.Identity)
	if user.RelayURL == "" || user.Token == "" || user.Identity == "" {
		return fmt.Errorf("relay/token/identity all required")
	}

	userPath, err := config.SaveUser(user)
	if err != nil {
		return fmt.Errorf("save user config: %w", err)
	}
	fmt.Printf("✓ wrote %s\n", userPath)

	repoCfg, _, err := config.LoadRepo(cwd)
	if err != nil {
		return err
	}
	if repoCfg == nil {
		repoCfg = &config.Repo{}
	}

	if *partner != "" {
		repoCfg.Identity.Partner = *partner
	}
	repoCfg.Identity.Partner = prompt("Legacy partner identity (optional, e.g. alex@frontend)", repoCfg.Identity.Partner)

	if *repoName == "" {
		repoCfg.Paths.Repo = prompt("Repo name", cmp.Or(repoCfg.Paths.Repo, filepath.Base(config.RepoRoot(cwd))))
	} else {
		repoCfg.Paths.Repo = *repoName
	}
	repoCfg.Paths.Base = cmp.Or(*base, repoCfg.Paths.Base, "origin/main")
	if *swagger != "" {
		repoCfg.Paths.Swagger = *swagger
	}
	if *terminalApp != "" {
		repoCfg.Triggers.TerminalApp = *terminalApp
	}
	switch wakeChoice {
	case triYes:
		repoCfg.Triggers.WakeOnComment = true
	case triNo:
		repoCfg.Triggers.WakeOnComment = false
	}

	repoPath := config.RepoConfigPath(cwd)
	if err := config.SaveRepo(repoPath, repoCfg); err != nil {
		return fmt.Errorf("save repo config: %w", err)
	}
	fmt.Printf("✓ wrote %s\n", repoPath)

	repoRoot := config.RepoRoot(cwd)
	runRegisterMCP(ctx, ag, mcpChoice, *nonInteractive, rd)
	runInstallCommands(ag, cmdsChoice, *nonInteractive, rd, repoRoot)
	runAppendInstructions(ag, instrChoice, *nonInteractive, rd, repoRoot)
	runEnsureWakeHook(ag, repoCfg.Triggers.WakeOnComment, repoRoot)

	inboxDir := inbox.InboxDir(repoRoot, repoCfg.Inbox.Dir)
	fmt.Println()
	fmt.Println("Done. Next steps:")
	fmt.Println()
	fmt.Println("  As sender:")
	fmt.Println("    1. Write a Markdown summary to " + filepath.Join(inboxDir, ".draft-summary.md"))
	fmt.Println("    2. cc-handoff submit  [--urgent --note \"...\"]")
	fmt.Println("       (defaults to the current team project; use --to only for explicit point-to-point delivery)")
	fmt.Println("    3. cc-handoff status <id>     # check whether the recipient has picked it up")
	fmt.Println("    4. cc-handoff retract <id>    # if you sent the wrong thing")
	fmt.Println()
	fmt.Println("  As receiver:")
	fmt.Println("    1. Start the watch daemon:  cc-handoff watch print-unit > <plist|service|xml>")
	fmt.Println("       and load it with launchd / systemd / Task Scheduler (see docs/deployment.md)")
	fmt.Println("    2. cc-handoff list            # what's pending in my inbox")
	fmt.Println("    3. cc-handoff pickup <id>     # fetch + materialize")
	fmt.Println("    4. cc-handoff inbox / open <id>   # revisit a previously picked handoff")
	return nil
}

// resolveAgent maps the --agent flag (or empty for auto-detect) into an Agent
// implementation. Errors when the user names something we don't know — better
// than silently falling back to manual.
func resolveAgent(name string) (agent.Agent, error) {
	if name == "" {
		return agent.Detect(), nil
	}
	return agent.Resolve(name)
}

// shouldRunOptional resolves a triState + interactive prompt into a single
// "go ahead?" decision. Returns true when the user opted in (or accepted the
// default Y), false on triNo / non-interactive-unset / negative answer.
func shouldRunOptional(choice triState, nonInteractive bool, rd *bufio.Reader, question string) bool {
	if choice == triNo {
		return false
	}
	if choice == triYes {
		return true
	}
	if nonInteractive {
		return false
	}
	return confirmYN(rd, question, true)
}

// Errors are non-fatal: init has already saved configs, the user can re-run
// install steps manually.
func runRegisterMCP(ctx context.Context, ag agent.Agent, choice triState, nonInteractive bool, rd *bufio.Reader) {
	question := fmt.Sprintf("Register cc-handoff MCP server with %s?", ag.Name())
	if !shouldRunOptional(choice, nonInteractive, rd, question) {
		return
	}

	exe, err := setup.CurrentBinary()
	if err != nil {
		fmt.Fprintf(os.Stderr, "  ! resolve current binary: %v; skipping MCP register\n", err)
		return
	}
	binPath, err := setup.ResolveMCPBinary(exe)
	if err != nil {
		fmt.Fprintf(os.Stderr, "  ! %v; install cc-handoff-mcp then re-run with --with-mcp\n", err)
		return
	}

	fmt.Println()
	if err := ag.RegisterMCP(ctx, setup.MCPRegisterOptions{BinPath: binPath}, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "  ! %v\n", err)
	}
}

func runInstallCommands(ag agent.Agent, choice triState, nonInteractive bool, rd *bufio.Reader, repoRoot string) {
	if !ag.SupportsCommands() {
		return
	}
	question := fmt.Sprintf("Install %s commands?", ag.Name())
	if ag.Name() == "codex" {
		question = "Install cc-handoff Codex workflow skills?"
	}
	if !shouldRunOptional(choice, nonInteractive, rd, question) {
		return
	}
	fmt.Printf("\nInstalling %s commands …\n", ag.Name())
	if ag.Name() == "codex" {
		fmt.Println("  · Codex does not support custom slash commands; installing workflow skills that call cc-handoff MCP tools.")
	}

	var conflictPrompt setup.PromptFunc
	if !nonInteractive {
		conflictPrompt = func(name string, reason setup.ConflictReason, existingVer, newVer string) (rune, error) {
			switch reason {
			case setup.ConflictUnstamped:
				fmt.Printf("  ! %s exists but has no cc-handoff version marker (likely hand-edited).\n", name)
			case setup.ConflictOlder:
				fmt.Printf("  ! %s is at v%s on disk, binary ships v%s.\n", name, existingVer, newVer)
			}
			fmt.Printf("    [o]verwrite / [s]kip / [b]ackup-then-overwrite (default skip): ")
			line, err := rd.ReadString('\n')
			if err != nil && err != io.EOF {
				return 's', err
			}
			line = strings.TrimSpace(line)
			if line == "" {
				return 's', nil
			}
			return rune(line[0]), nil
		}
	}

	if _, err := ag.InstallCommands(repoRoot, version.Version, conflictPrompt, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "  ! %v\n", err)
	}
}

func runAppendInstructions(ag agent.Agent, choice triState, nonInteractive bool, rd *bufio.Reader, repoRoot string) {
	filename, snippet := ag.InstructionsFile()
	if filename == "" {
		return
	}
	question := fmt.Sprintf("Append cc-handoff usage snippet to %s?", filename)
	if !shouldRunOptional(choice, nonInteractive, rd, question) {
		return
	}
	path := filepath.Join(repoRoot, filename)
	res, err := setup.AppendSnippet(path, snippet)
	if err != nil {
		fmt.Fprintf(os.Stderr, "  ! %v\n", err)
		return
	}
	if res == setup.SnippetWritten {
		fmt.Printf("  ✓ wrote cc-handoff snippet into %s\n", path)
	} else {
		fmt.Printf("  · %s already has cc-handoff snippet, skipped\n", path)
	}
}

// runEnsureWakeHook wires the cc-handoff Stop hook into .claude/settings.json
// when the receiver opted into wake-on-comment AND is on Claude Code (the
// only agent that supports Stop hooks). Disabling wake-on-comment later does
// NOT auto-remove the hook because the hook is a no-op when the config flag
// is off — leaving it installed costs nothing.
func runEnsureWakeHook(ag agent.Agent, enabled bool, repoRoot string) {
	if !enabled {
		return
	}
	if !ag.SupportsHooks() {
		fmt.Printf("  · wake_on_comment=true noted; Stop hook install skipped (agent %q has no equivalent)\n", ag.Name())
		return
	}
	res, err := setup.EnsureStopHook(repoRoot)
	if err != nil {
		fmt.Fprintf(os.Stderr, "  ! wire Stop hook: %v\n", err)
		return
	}
	target := filepath.Join(repoRoot, ".claude", "settings.json")
	switch res {
	case setup.EnsureWritten:
		fmt.Printf("  ✓ wired wake-on-comment Stop hook into %s\n", target)
	case setup.EnsureAlreadyPresent:
		fmt.Printf("  · %s already has cc-handoff Stop hook, skipped\n", target)
	}
}

func confirmYN(rd *bufio.Reader, question string, defaultYes bool) bool {
	suffix := " [Y/n]: "
	if !defaultYes {
		suffix = " [y/N]: "
	}
	fmt.Printf("\n%s%s", question, suffix)
	line, err := rd.ReadString('\n')
	if err != nil && err != io.EOF {
		return false
	}
	line = strings.TrimSpace(line)
	if line == "" {
		return defaultYes
	}
	c := line[0]
	return c == 'y' || c == 'Y'
}
