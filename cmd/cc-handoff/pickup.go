package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/inbox"
	gitsrc "github.com/cc-collaboration/internal/sources/git"
	"github.com/cc-collaboration/internal/transport"
)

// pickupJSON is the --json output: a stable machine contract the GUI front-end
// (the Flutter app) depends on, so it's a typed struct rather than a map literal.
type pickupJSON struct {
	WorktreeDir    string `json:"worktree_dir"`
	MaterializeDir string `json:"materialize_dir"`
	AgentCmd       string `json:"agent_cmd"`
	Acked          bool   `json:"acked"`
}

func runPickup(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("pickup", flag.ContinueOnError)
	noAck := fs.Bool("no-ack", false, "do not mark as picked on the relay")
	direct := fs.Bool("direct", false, "skip docs/integrations/<id>.md and instruct the receiver to modify code directly (default: write integration doc and stop for review)")
	repoPath := fs.String("repo", "", "repo path to materialize into (default: current working directory). Useful when one identity owns multiple receiver repos.")
	worktree := fs.Bool("worktree", false, "create an isolated git worktree for this handoff (under <repo>/.worktrees) and materialize into it, so you integrate on a dedicated branch")
	open := fs.Bool("open", false, "with --worktree, launch the agent in the new worktree (in-place; replaces this shell)")
	window := fs.Bool("window", false, "with --open, open a new terminal window instead of replacing this shell")
	asJSON := fs.Bool("json", false, "output machine-readable JSON (worktree_dir, materialize_dir, agent_cmd, acked) and skip the human text — for GUI front-ends")
	pos, err := parseFlexible(fs, args)
	if err != nil {
		return err
	}
	if len(pos) < 1 {
		return fmt.Errorf("usage: cc-handoff pickup <handoff-id> [--no-ack] [--direct] [--repo PATH] [--worktree [--open [--window]]]")
	}
	id := pos[0]

	cwd, err := resolveRepoFlag(*repoPath, "--repo")
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

	mode := inbox.ModeDocFirst
	if *direct {
		mode = inbox.ModeDirect
	}

	// Default: materialize into the repo's inbox. With --worktree: carve an
	// isolated worktree on a dedicated branch and materialize into it, so the
	// integration happens off the main checkout.
	repoRoot := config.RepoRoot(cwd)
	materializeRoot := repoRoot
	var worktreeDir string
	if *worktree {
		branch := config.HandoffWorktreeBranch(pkg.ID, pkg.Repo.Branch)
		worktreeDir = config.WorktreeDir(repoRoot, branch)
		if err := gitsrc.CarveWorktree(ctx, repoRoot, worktreeDir, branch, ""); err != nil {
			return err
		}
		if !*asJSON {
			fmt.Printf("✓ created worktree %s\n", worktreeDir)
		}
		materializeRoot = worktreeDir
	}

	mat, err := inbox.Materialize(inbox.InboxDir(materializeRoot, res.InboxOverride), pkg, mode)
	if err != nil {
		return err
	}
	if !*asJSON {
		fmt.Printf("✓ materialized %s\n", mat.Dir)
	}

	if err := inbox.DownloadAttachments(ctx, client, mat.Dir, pkg); err != nil {
		fmt.Fprintf(os.Stderr, "warning: download attachments: %v\n", err)
	}

	acked := false
	if !*noAck {
		if err := client.Ack(ctx, id); err != nil {
			fmt.Fprintf(os.Stderr, "warning: ack failed: %v\n", err)
		} else {
			acked = true
			if !*asJSON {
				fmt.Println("✓ acked on relay")
			}
		}
	}

	if *asJSON {
		// Machine-readable output for GUI front-ends (e.g. the Flutter app): the
		// worktree dir + the interactive agent command to run in an embedded
		// terminal. stdout stays pure JSON (progress/warnings go to stderr).
		agentCmd := res.Agent.POSIXPromptCmd(materializeRoot, "", "", true)
		return json.NewEncoder(os.Stdout).Encode(pickupJSON{
			WorktreeDir:    worktreeDir,
			MaterializeDir: mat.Dir,
			AgentCmd:       agentCmd,
			Acked:          acked,
		})
	}

	if *worktree && *open {
		// Launch the agent directly in the worktree. exec replaces this process
		// on success, so this does not return.
		p := config.Project{Name: pkg.ID, Path: worktreeDir}
		return launchProject(ctx, nil, config.Workspace{}, p, *window)
	}

	fmt.Println()
	fmt.Printf("Materialized at %s\n", mat.Dir)
	if *worktree {
		fmt.Printf("\nNext: launch your %s session in the worktree:\n", res.Agent.Name())
		fmt.Printf("  cd %s && %s\n", worktreeDir, res.Agent.CLI())
	} else {
		fmt.Printf("\nNext: launch your %s session on this handoff:\n", res.Agent.Name())
		fmt.Printf("  cc-handoff open %s\n", id)
	}
	fmt.Println()
	fmt.Println("Or read prompt.md and paste it into an existing session manually.")
	return nil
}
