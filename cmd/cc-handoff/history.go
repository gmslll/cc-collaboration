package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/transport"
)

func runHistory(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("history", flag.ContinueOnError)
	limit := fs.Int("limit", 20, "max items to fetch (relay caps at 500)")
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
	client := transport.New(res.RelayURL, res.Token)
	items, err := client.ListHistory(ctx, *limit)
	if err != nil {
		return relayCompatError(err, "history")
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(items)
	}
	if len(items) == 0 {
		fmt.Println("no picked-up handoffs in your history yet.")
		return nil
	}
	fmt.Printf("%-32s  %-22s  %-22s  %-7s  %-19s  %s\n", "ID", "FROM", "REPO", "URG", "WHEN", "HEADLINE")
	for _, it := range items {
		fmt.Printf("%-32s  %-22s  %-22s  %-7s  %-19s  %s\n",
			it.ID,
			truncRight(it.Sender, 22),
			truncRight(it.RepoName, 22),
			it.Urgency,
			it.CreatedAt.Local().Format(time.RFC3339[:19]),
			truncRight(it.Headline, 80),
		)
	}
	return nil
}
