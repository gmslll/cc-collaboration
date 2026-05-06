package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/transport"
)

func runOnline(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("online", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "emit JSON instead of a table")
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
	client := transport.New(res.RelayURL, res.Token)
	users, err := client.ListOnlineUsers(ctx)
	if err != nil {
		return relayCompatError(err, "online users listing")
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(users)
	}
	if len(users) == 0 {
		fmt.Println("no identities registered on this relay.")
		return nil
	}

	online := 0
	for _, u := range users {
		if u.Online {
			online++
		}
	}
	fmt.Printf("%d online of %d known identities:\n\n", online, len(users))
	fmt.Printf("%-7s  %s\n", "STATUS", "IDENTITY")
	for _, u := range users {
		status := "offline"
		if u.Online {
			status = "ONLINE"
		}
		marker := ""
		switch u.Identity {
		case res.Me:
			marker = "  (you)"
		case res.Partner:
			marker = "  (partner)"
		}
		fmt.Printf("%-7s  %s%s\n", status, u.Identity, marker)
	}
	return nil
}
