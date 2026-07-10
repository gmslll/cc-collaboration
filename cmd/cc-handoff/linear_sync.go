package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/linear"
	"github.com/cc-collaboration/internal/notify"
)

func runLinearSync(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("linear-sync", flag.ContinueOnError)
	noNotify := fs.Bool("no-notify", false, "skip desktop notifications, only print to stdout")
	asJSON := fs.Bool("json", false, "output new notifications as JSON instead of human-readable text")
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
	if res.LinearPersonalToken == "" {
		return fmt.Errorf("linear_personal_token not set in user config (~/.config/cc-handoff/config.toml). " +
			"Generate one at Linear → Account → Security & Access → Personal API Keys.")
	}

	cursorPath, err := linear.CursorPath()
	if err != nil {
		return err
	}
	since, err := linear.LoadCursor(cursorPath)
	if err != nil {
		return err
	}

	client := linear.NewClient(res.LinearPersonalToken)
	items, newCursor, err := linear.PollOnce(ctx, client, since, res.Linear.Notifications.Types)
	if err != nil {
		return err
	}
	if err := linear.SaveCursor(cursorPath, newCursor); err != nil {
		return fmt.Errorf("save cursor: %w", err)
	}

	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(items)
	}

	if len(items) == 0 {
		fmt.Println("No new Linear notifications.")
		return nil
	}
	for _, it := range items {
		fmt.Printf("[%s] %s in %s — %s\n", it.Type, it.ActorName, it.IssueIdent, it.IssueTitle)
		if it.Snippet != "" {
			fmt.Printf("    %s\n", it.Snippet)
		}
		if it.IssueURL != "" {
			fmt.Printf("    %s\n", it.IssueURL)
		}
	}
	if !*noNotify {
		for _, it := range items {
			_ = notify.Show(ctx, linear.ToNotify(it))
		}
	}
	return nil
}
