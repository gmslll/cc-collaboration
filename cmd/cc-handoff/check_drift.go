package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/drift"
	"github.com/cc-collaboration/internal/transport"
)

func runCheckDrift(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("check-drift", flag.ContinueOnError)
	to := fs.String("to", "", "limit baseline search to handoffs sent to this recipient (default: identity.partner from .cc-handoff.toml)")
	limit := fs.Int("limit", 20, "how many sent items to scan looking for a baseline")
	asJSON := fs.Bool("json", false, "emit JSON (full APIDelta) instead of a human summary")
	if err := fs.Parse(args); err != nil {
		return err
	}

	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return err
	}

	recipient := res.Partner
	if *to != "" {
		recipient = *to
	}

	client := transport.New(res.RelayURL, res.Token)
	result, err := drift.Detect(ctx, client, recipient, config.ResolveSwaggerPath(config.RepoRoot(cwd), res.Swagger), *limit)
	if err != nil {
		if errors.Is(err, drift.ErrNoSpec) {
			fmt.Println("no swagger spec configured (set paths.swagger in .cc-handoff.toml).")
			return nil
		}
		return relayCompatError(err, "check-drift")
	}

	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(result)
	}
	fmt.Println(result.Summary(recipient))
	return nil
}
