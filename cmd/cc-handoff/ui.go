package main

import (
	"context"
	"flag"
	"fmt"
	"os/exec"
	"runtime"
	"strings"

	"github.com/cc-collaboration/internal/config"
)

var openBrowser = func(ctx context.Context, url string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.CommandContext(ctx, "open", url)
	case "windows":
		cmd = exec.CommandContext(ctx, "cmd.exe", "/c", "start", "", url)
	default:
		cmd = exec.CommandContext(ctx, "xdg-open", url)
	}
	return cmd.Run()
}

func runUI(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("ui", flag.ContinueOnError)
	doOpen := fs.Bool("open", false, "open the relay UI in the default browser")
	showToken := fs.Bool("show-token", false, "print the bearer token for pasting into the UI")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("usage: cc-handoff ui [--open] [--show-token]")
	}

	user, path, err := config.LoadUser()
	if err != nil {
		return err
	}
	if user == nil {
		return fmt.Errorf("user config missing at %s; run `cc-handoff init`", path)
	}
	if user.RelayURL == "" {
		return fmt.Errorf("relay_url missing in %s; run `cc-handoff init`", path)
	}

	url := relayUIURL(user.RelayURL)
	fmt.Printf("Relay UI: %s\n", url)
	if user.Identity != "" {
		fmt.Printf("Identity: %s\n", user.Identity)
	}
	if *showToken {
		if user.Token == "" {
			fmt.Println("Token: <missing>")
		} else {
			fmt.Printf("Token: %s\n", user.Token)
		}
	} else {
		fmt.Println("Token: configured; pass --show-token if you need to paste it into the browser.")
	}

	if *doOpen {
		if err := openBrowser(ctx, url); err != nil {
			return fmt.Errorf("open browser: %w", err)
		}
	}
	return nil
}

func relayUIURL(base string) string {
	return strings.TrimRight(base, "/") + "/ui/"
}
