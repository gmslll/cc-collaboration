package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/inbox"
)

func runInbox(_ context.Context, args []string) error {
	fs := flag.NewFlagSet("inbox", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "emit JSON instead of a table")
	if err := fs.Parse(args); err != nil {
		return err
	}

	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	res, err := config.ResolveRelay(cwd)
	if err != nil {
		return err
	}
	repoRoot := config.RepoRoot(cwd)
	dir := inbox.InboxDir(repoRoot, res.InboxOverride)

	items, err := inbox.ListLocal(dir)
	if err != nil {
		return fmt.Errorf("read %s: %w", dir, err)
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(items)
	}
	if len(items) == 0 {
		fmt.Printf("no materialized handoffs at %s\n", dir)
		return nil
	}
	fmt.Printf("%-32s  %-22s  %-7s  %-19s  %-9s  %s\n", "ID", "FROM", "URG", "WHEN", "FLAGS", "REPO")
	for _, it := range items {
		flags := ""
		if it.Retracted {
			flags += "RET "
		}
		if it.HasComments {
			flags += "C "
		}
		if it.AmendsHandoff != "" {
			flags += "A "
		}
		if flags == "" {
			flags = "-"
		}
		fmt.Printf("%-32s  %-22s  %-7s  %-19s  %-9s  %s\n",
			it.ID,
			truncRight(it.Sender, 22),
			it.Urgency,
			it.CreatedAt.Local().Format(time.RFC3339[:19]),
			flags,
			it.Repo,
		)
	}
	return nil
}
