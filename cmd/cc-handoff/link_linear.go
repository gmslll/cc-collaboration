package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/inbox"
)

// linearLink is the on-disk record that ties a handoff to a Linear issue.
// Written by `cc-handoff link-linear`, read by anyone who later wants to know
// which Linear issue a given handoff belongs to (status_handoff prints this,
// and the various Linear sync prompts in MCP tool outputs reference it).
type linearLink struct {
	HandoffID  string    `json:"handoff_id"`
	Identifier string    `json:"identifier"`
	URL        string    `json:"url,omitempty"`
	LinkedAt   time.Time `json:"linked_at"`
}

func runLinkLinear(_ context.Context, args []string) error {
	fs := flag.NewFlagSet("link-linear", flag.ContinueOnError)
	handoffID := fs.String("handoff", "", "handoff id (e.g. h_20260512_ABCD1234)")
	issue := fs.String("issue", "", "Linear issue identifier (e.g. ENG-456)")
	url := fs.String("url", "", "Linear issue URL (optional)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *handoffID == "" || *issue == "" {
		return fmt.Errorf("usage: cc-handoff link-linear --handoff <id> --issue <ENG-XXX> [--url <URL>]")
	}

	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return err
	}
	repoRoot := config.RepoRoot(cwd)
	target := filepath.Join(inbox.InboxDir(repoRoot, res.InboxOverride), "sent", *handoffID)
	if err := os.MkdirAll(target, 0o755); err != nil {
		return fmt.Errorf("create %s: %w", target, err)
	}

	link := linearLink{
		HandoffID:  *handoffID,
		Identifier: *issue,
		URL:        *url,
		LinkedAt:   time.Now().UTC(),
	}
	out := filepath.Join(target, "linear.json")
	data, err := json.MarshalIndent(link, "", "  ")
	if err != nil {
		return err
	}
	tmp := out + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", tmp, err)
	}
	if err := os.Rename(tmp, out); err != nil {
		return fmt.Errorf("rename %s: %w", out, err)
	}
	fmt.Printf("✓ linked %s → %s (%s)\n", *handoffID, *issue, out)
	return nil
}
