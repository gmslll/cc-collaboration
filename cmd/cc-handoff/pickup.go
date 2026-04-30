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
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() < 1 {
		return fmt.Errorf("usage: cc-handoff pickup <handoff-id> [--no-ack]")
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

	mat, err := inbox.Materialize(inbox.InboxDir(config.RepoRoot(cwd), res.InboxOverride), pkg)
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
	fmt.Printf("Open %s/prompt.md and feed it to your %s session.\n", mat.Dir, res.Agent.Name())
	return nil
}
