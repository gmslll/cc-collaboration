package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/transport"
)

func runComment(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("comment", flag.ContinueOnError)
	listMode := fs.Bool("list", false, "list comments on the handoff instead of posting one")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() < 1 {
		return fmt.Errorf("usage: cc-handoff comment <handoff-id> <body...> | --list <handoff-id>")
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

	if *listMode {
		comments, err := client.ListComments(ctx, id)
		if err != nil {
			return err
		}
		if len(comments) == 0 {
			fmt.Println("no comments yet.")
			return nil
		}
		for _, c := range comments {
			fmt.Printf("[%s] %s: %s\n",
				c.CreatedAt.Local().Format("2006-01-02 15:04:05"), c.Sender, c.Body)
		}
		return nil
	}

	if fs.NArg() < 2 {
		return fmt.Errorf("comment body required (or pass --list)")
	}
	body := strings.Join(fs.Args()[1:], " ")
	c, err := client.Comment(ctx, id, body)
	if err != nil {
		return err
	}
	fmt.Printf("✓ posted comment #%d on %s\n", c.ID, c.HandoffID)
	return nil
}
