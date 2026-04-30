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

	"github.com/cc-collaboration/internal/config"
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
	partner := fs.String("partner", "", "partner identity, e.g. alex@frontend")
	repoName := fs.String("repo", "", "repo name (default: basename of repo root)")
	base := fs.String("base", "origin/main", "git base ref for diff/log")
	swagger := fs.String("swagger", "", "path to OpenAPI/Swagger file relative to repo root (optional)")
	terminalApp := fs.String("terminal", "", "terminal app for auto-launch: terminal | iterm2")
	nonInteractive := fs.Bool("non-interactive", false, "fail instead of prompting for missing values")

	withMCP := fs.Bool("with-mcp", false, "register cc-handoff with Claude Code as an MCP server (user scope)")
	noMCP := fs.Bool("no-mcp", false, "skip MCP server registration even if claude CLI is available")
	withCommands := fs.Bool("with-commands", false, "copy /handoff /handoff-module /pickup slash commands into ./.claude/commands/")
	noCommands := fs.Bool("no-commands", false, "skip slash command copy")

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
	repoCfg.Identity.Partner = prompt("Partner identity (e.g. alex@frontend)", repoCfg.Identity.Partner)
	if repoCfg.Identity.Partner == "" {
		return fmt.Errorf("partner identity required")
	}

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

	repoPath := config.RepoConfigPath(cwd)
	if err := config.SaveRepo(repoPath, repoCfg); err != nil {
		return fmt.Errorf("save repo config: %w", err)
	}
	fmt.Printf("✓ wrote %s\n", repoPath)

	runRegisterMCP(ctx, mcpChoice, *nonInteractive, rd)
	runCopyCommands(cmdsChoice, *nonInteractive, rd, config.RepoRoot(cwd))

	fmt.Println("Done. Try `cc-handoff submit` after writing .claude/handoff-inbox/.draft-summary.md.")
	return nil
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
func runRegisterMCP(ctx context.Context, choice triState, nonInteractive bool, rd *bufio.Reader) {
	if !setup.ClaudeAvailable() {
		if choice == triYes {
			fmt.Fprintln(os.Stderr, "  ! --with-mcp set but `claude` CLI not on PATH; skipping")
		}
		return
	}
	if !shouldRunOptional(choice, nonInteractive, rd, "Register cc-handoff MCP server with Claude Code (user scope)?") {
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
	fmt.Println("Registering MCP server with Claude Code:")
	fmt.Printf("  claude mcp remove cc-handoff --scope user\n")
	fmt.Printf("  claude mcp add --scope user --transport stdio cc-handoff -- %s\n", binPath)

	if err := setup.Register(ctx, setup.MCPRegisterOptions{BinPath: binPath}, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "  ! %v\n", err)
	}
}

func runCopyCommands(choice triState, nonInteractive bool, rd *bufio.Reader, repoRoot string) {
	if !shouldRunOptional(choice, nonInteractive, rd, "Copy /handoff /handoff-module /pickup slash commands to ./.claude/commands/?") {
		return
	}
	dest := filepath.Join(repoRoot, ".claude", "commands")
	fmt.Printf("\nCopying slash commands to %s …\n", dest)

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

	if _, err := setup.CopyCommands(dest, version.Version, conflictPrompt, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "  ! %v\n", err)
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
