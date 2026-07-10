package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/statusfmt"
	"github.com/cc-collaboration/internal/transport"
)

func runStatus(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "emit JSON instead of human-readable output")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() < 1 {
		return fmt.Errorf("usage: cc-handoff status <handoff-id>")
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
	st, err := client.Status(ctx, id)
	if err != nil {
		return relayCompatError(err, "status")
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(st)
	}

	fmt.Print(statusfmt.CLI(st))
	return nil
}
