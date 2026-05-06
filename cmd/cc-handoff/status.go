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
	res, err := config.Resolve(cwd)
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

	fmt.Printf("handoff %s\n", st.ID)
	fmt.Printf("  state     : %s\n", st.State)
	fmt.Printf("  sender    : %s\n", st.Sender)
	fmt.Printf("  recipient : %s\n", st.Recipient)
	fmt.Printf("  created   : %s\n", st.CreatedAt.Local().Format(time.RFC3339))
	if st.PickedAt != nil {
		fmt.Printf("  picked    : %s\n", st.PickedAt.Local().Format(time.RFC3339))
	} else {
		fmt.Printf("  picked    : (not yet)\n")
	}
	fmt.Printf("  comments  : %d\n", st.CommentCount)
	if st.LastComment != nil {
		fmt.Printf("  last      : %s @ %s\n              %s\n",
			st.LastComment.Sender,
			st.LastComment.CreatedAt.Local().Format(time.RFC3339[:19]),
			st.LastComment.Body,
		)
	}
	return nil
}
