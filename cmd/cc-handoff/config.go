package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/cc-collaboration/internal/config"
)

func runConfig(ctx context.Context, args []string) error {
	if len(args) == 0 {
		configUsage()
		return fmt.Errorf("missing action")
	}
	action, rest := args[0], args[1:]
	switch action {
	case "set":
		return runConfigSet(ctx, rest)
	case "help", "-h", "--help":
		configUsage()
		return nil
	default:
		configUsage()
		return fmt.Errorf("unknown config action %q", action)
	}
}

func configUsage() {
	fmt.Fprint(os.Stderr, `cc-handoff config — edit the user config (~/.config/cc-handoff/config.toml)

  cc-handoff config set [--relay-url URL] [--token TOK] [--identity ID]
                        [--agent claude|codex|manual] [--workspace-root DIR]
                        [--grade-command CMD] [--linear-token TOK]
        set one or more user-level fields; only the flags you pass are changed,
        the rest of the config (workspaces etc.) is preserved.
`)
}

// runConfigSet mutates only the explicitly-passed user-level fields and writes
// the whole config back (LoadUser → set → SaveUser), preserving everything else.
func runConfigSet(_ context.Context, args []string) error {
	fs := flag.NewFlagSet("config set", flag.ContinueOnError)
	relayURL := fs.String("relay-url", "", "relay server URL")
	token := fs.String("token", "", "relay bearer token")
	identity := fs.String("identity", "", "your identity, e.g. you@backend")
	agent := fs.String("agent", "", "default agent: claude|codex|manual")
	wsRoot := fs.String("workspace-root", "", "base dir for workspaces")
	grade := fs.String("grade-command", "", "local AI severity grader command")
	linear := fs.String("linear-token", "", "Linear personal API token")
	if err := fs.Parse(args); err != nil {
		return err
	}

	u, err := loadUserOrFail()
	if err != nil {
		return err
	}

	var setErr error
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "relay-url":
			u.RelayURL = *relayURL
		case "token":
			u.Token = *token
		case "identity":
			u.Identity = *identity
		case "agent":
			if !validAgent(*agent) {
				setErr = fmt.Errorf("invalid agent %q (claude|codex|manual)", *agent)
				return
			}
			u.Agent = *agent
		case "workspace-root":
			u.WorkspaceRoot = *wsRoot
		case "grade-command":
			u.GradeCommand = *grade
		case "linear-token":
			u.LinearPersonalToken = *linear
		}
	})
	if setErr != nil {
		return setErr
	}

	if _, err := config.SaveUser(u); err != nil {
		return err
	}
	fmt.Println("config updated")
	return nil
}

// validAgent allows empty (clears the field) or a known agent name.
func validAgent(v string) bool {
	return v == "" || v == "claude" || v == "codex" || v == "manual"
}
