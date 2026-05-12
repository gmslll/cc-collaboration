package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/inbox"
)

func runLinkLinear(_ context.Context, args []string) error {
	fs := flag.NewFlagSet("link-linear", flag.ContinueOnError)
	handoffID := fs.String("handoff", "", "handoff id (e.g. h_20260512_ABCD1234)")
	issue := fs.String("issue", "", "Linear issue identifier (e.g. ENG-456)")
	url := fs.String("url", "", "Linear issue URL (optional)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *handoffID == "" || *issue == "" {
		return fmt.Errorf("usage: cc-handoff link-linear --handoff <id> --issue <ENG-XXX> [--url <URL>]")
	}

	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return err
	}
	inboxDir := inbox.InboxDir(config.RepoRoot(cwd), res.InboxOverride)
	out, err := inbox.WriteLinearLink(inboxDir, *handoffID, *issue, *url)
	if err != nil {
		return err
	}
	fmt.Printf("✓ linked %s → %s (%s)\n", *handoffID, *issue, out)
	return nil
}
