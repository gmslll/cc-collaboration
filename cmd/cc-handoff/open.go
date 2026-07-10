package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/inbox"
	"github.com/cc-collaboration/internal/notify"
)

func runOpen(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("open", flag.ContinueOnError)
	dry := fs.Bool("dry", false, "print what would be launched without spawning a window")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() < 1 {
		return fmt.Errorf("usage: cc-handoff open <handoff-id> [--dry]")
	}
	id := fs.Arg(0)

	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	res, err := config.ResolveRelay(cwd)
	if err != nil {
		return err
	}
	repoRoot := config.RepoRoot(cwd)
	dir := inbox.PackageDir(inbox.InboxDir(repoRoot, res.InboxOverride), id)
	prompt := filepath.Join(dir, "prompt.md")
	if _, err := os.Stat(prompt); err != nil {
		return fmt.Errorf("no materialized handoff at %s — has it been picked up? (try `cc-handoff pickup %s`)", dir, id)
	}

	return notify.LaunchTerminal(ctx, buildLaunchOpts(res, repoRoot, prompt, id, *dry))
}
