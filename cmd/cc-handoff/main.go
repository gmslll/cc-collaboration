package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	sub := os.Args[1]
	args := os.Args[2:]

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var err error
	switch sub {
	case "init":
		err = runInit(ctx, args)
	case "submit":
		err = runSubmit(ctx, args)
	case "list":
		err = runList(ctx, args)
	case "pickup":
		err = runPickup(ctx, args)
	case "watch":
		err = runWatch(ctx, args)
	case "comment":
		err = runComment(ctx, args)
	case "version", "-v", "--version":
		runVersion()
	case "help", "-h", "--help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand %q\n\n", sub)
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `cc-handoff — cross-machine Claude Code collaboration

Usage:
  cc-handoff init     [--relay URL --token T --me ID --partner ID --repo NAME --base REF] [--non-interactive]
  cc-handoff submit   [--to ID] [--urgent] [--note TEXT] [--base REF]
  cc-handoff list     [--json]
  cc-handoff pickup   <handoff-id> [--no-ack]
  cc-handoff watch    [--no-notify] [--no-launch] [--stop-after N]
  cc-handoff comment  <handoff-id> <body...>
  cc-handoff comment  --list <handoff-id>

Run cc-handoff <subcommand> --help for details.
`)
}
