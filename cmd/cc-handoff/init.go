package main

import (
	"bufio"
	"cmp"
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/cc-collaboration/internal/config"
)

func runInit(_ context.Context, args []string) error {
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
	if err := fs.Parse(args); err != nil {
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
	fmt.Println("Done. Try `cc-handoff submit` after writing .claude/handoff-inbox/.draft-summary.md.")
	return nil
}
