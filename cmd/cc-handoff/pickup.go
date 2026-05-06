package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/inbox"
	"github.com/cc-collaboration/internal/transport"
)

func runPickup(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("pickup", flag.ContinueOnError)
	noAck := fs.Bool("no-ack", false, "do not mark as picked on the relay")
	direct := fs.Bool("direct", false, "skip docs/integrations/<id>.md and instruct the receiver to modify code directly (default: write integration doc and stop for review)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() < 1 {
		return fmt.Errorf("usage: cc-handoff pickup <handoff-id> [--no-ack] [--direct]")
	}
	id := fs.Arg(0)

	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return err
	}
	client := transport.New(res.RelayURL, res.Token)
	pkg, err := client.Get(ctx, id)
	if err != nil {
		return err
	}

	mode := inbox.ModeDocFirst
	if *direct {
		mode = inbox.ModeDirect
	}
	mat, err := inbox.Materialize(inbox.InboxDir(config.RepoRoot(cwd), res.InboxOverride), pkg, mode)
	if err != nil {
		return err
	}
	fmt.Printf("✓ materialized %s\n", mat.Dir)

	if err := inbox.DownloadAttachments(ctx, client, mat.Dir, pkg); err != nil {
		fmt.Fprintf(os.Stderr, "warning: download attachments: %v\n", err)
	}

	if !*noAck {
		if err := client.Ack(ctx, id); err != nil {
			fmt.Fprintf(os.Stderr, "warning: ack failed: %v\n", err)
		} else {
			fmt.Println("✓ acked on relay")
		}
	}
	fmt.Println()
	fmt.Printf("Materialized at %s\n", mat.Dir)
	fmt.Printf("\nNext: launch your %s session on this handoff:\n", res.Agent.Name())
	fmt.Printf("  cc-handoff open %s\n", id)
	fmt.Println()
	fmt.Println("Or read prompt.md and paste it into an existing session manually.")
	return nil
}
