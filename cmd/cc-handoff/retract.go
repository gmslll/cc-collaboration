package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/transport"
)

func runRetract(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("retract", flag.ContinueOnError)
	reason := fs.String("reason", "", "optional human-readable reason; surfaced to recipient via SSE")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() < 1 {
		return fmt.Errorf("usage: cc-handoff retract <handoff-id> [--reason TEXT]")
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
	client := transport.New(res.RelayURL, res.Token)
	if err := client.Retract(ctx, id, *reason); err != nil {
		return relayCompatError(err, "retract")
	}
	fmt.Printf("✓ retracted %s. Recipient watch will be notified via SSE.\n", id)
	return nil
}
