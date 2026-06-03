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
	case "status":
		err = runStatus(ctx, args)
	case "sent":
		err = runSent(ctx, args)
	case "history":
		err = runHistory(ctx, args)
	case "check-drift":
		err = runCheckDrift(ctx, args)
	case "retract":
		err = runRetract(ctx, args)
	case "link-linear":
		err = runLinkLinear(ctx, args)
	case "linear-sync":
		err = runLinearSync(ctx, args)
	case "inbox":
		err = runInbox(ctx, args)
	case "open":
		err = runOpen(ctx, args)
	case "online":
		err = runOnline(ctx, args)
	case "ui":
		err = runUI(ctx, args)
	case "desktop":
		err = runDesktop(ctx, args)
	case "workspace", "ws":
		err = runWorkspace(ctx, args)
	case "worktree", "wt":
		err = runWorktree(ctx, args)
	case "logs":
		err = runLogs(ctx, args)
	case "alert":
		err = runAlert(ctx, args)
	case "stop-hook":
		err = runStopHook(ctx, args)
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
	fmt.Fprint(os.Stderr, `cc-handoff — cross-machine AI agent handoff

Setup:
  cc-handoff init     [--agent claude|codex|manual] [--with-mcp] [--with-commands] [--with-instructions]

Sender flow:
  cc-handoff submit       [--to ID] [--urgent] [--note TEXT] [--base REF] [--amends ID]
  cc-handoff sent         [--limit N] [--json]          list my recent sent handoffs
  cc-handoff status       <id> [--json]                 show state / picked_at / comments
  cc-handoff retract      <id> [--reason TEXT]          cancel a still-pending handoff
  cc-handoff check-drift  [--to ID] [--limit N] [--json] swagger drifted since the last handoff?

Receiver flow:
  cc-handoff list     [--json]                          inbox: pending handoffs on relay
  cc-handoff pickup   <id> [--no-ack] [--direct] [--repo PATH] [--worktree [--open [--window]]]
                                                        fetch + materialize + ack (--worktree integrates on an isolated branch worktree)
  cc-handoff inbox    [--json]                          local: already-materialized handoffs
  cc-handoff history  [--limit N] [--json]              relay: handoffs you've picked up (cross-repo)
  cc-handoff open     <id> [--dry]                      re-launch the agent on a picked handoff
  cc-handoff watch    [--no-notify] [--no-launch] [--no-catchup] [--no-materialize] [--workdir PATH] [--stop-after N]
  cc-handoff watch    print-unit [--platform launchd|systemd|windows-task] [--workdir PATH] [--bin PATH]

Both sides:
  cc-handoff comment      <id> <body...>                post a comment
  cc-handoff comment      --list <id>                   list comments on a handoff
  cc-handoff online       [--json]                      show registered identities + who is currently watching
  cc-handoff ui           [--open] [--show-token]       print/open the relay management UI
  cc-handoff desktop      [--width N] [--height N] [--chrome PATH]
                                                        open the UI in a Chromium app window (Chrome/Edge/Brave)
  cc-handoff workspace    list | create <name> [--path DIR] | add <name> <github-url|path> | open <project> [--window]
                                                        manage + launch one-click targets (open: in-place exec, or --window)
  cc-handoff worktree     add <project> <branch> [--start REF] [--open] | list <project> | open <project> <branch> | remove <project> <branch> [--prune-merged --base main]
                                                        manage + launch branch worktrees (remove --prune-merged sweeps merged ones)
  cc-handoff logs         <project> [--workspace NAME] [--grep RE] [--context N] [--open [--window]]
                                                        pull the project's configured log source, extract the latest error, optionally launch the agent to triage
  cc-handoff alert        --to <identity> --project <name> [--message TEXT | --file PATH] [--level LVL]
                                                        forward a server log alert to a teammate's watch (server-side hook entry point)
  cc-handoff link-linear  --handoff <id> --issue <ENG-XXX> [--url URL]
                                                        record a Linear issue ↔ handoff binding locally
  cc-handoff linear-sync  [--no-notify] [--json]        pull new Linear @-mentions and fire desktop notifications

Run cc-handoff <subcommand> --help for details.
`)
}
