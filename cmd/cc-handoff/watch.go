package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/inbox"
	"github.com/cc-collaboration/internal/notify"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

func runWatch(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("watch", flag.ContinueOnError)
	noNotify := fs.Bool("no-notify", false, "skip desktop notification (useful for CI / e2e tests)")
	noLaunch := fs.Bool("no-launch", false, "log auto-launch invocations instead of opening a terminal")
	stopAfter := fs.Int("stop-after", 0, "stop after N events (0 = run forever)")
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

	h := &watchHandler{
		client:    transport.New(res.RelayURL, res.Token),
		repoRoot:  config.RepoRoot(cwd),
		res:       res,
		noNotify:  *noNotify,
		noLaunch:  *noLaunch,
		stopAfter: *stopAfter,
	}

	fmt.Printf("watching for handoffs to %s on %s …\n", res.Me, res.RelayURL)
	return h.client.Subscribe(ctx, res.Me, h.dispatch(ctx))
}

// watchHandler bundles per-session state shared by both event types.
type watchHandler struct {
	client    *transport.Client
	repoRoot  string
	res       *config.Resolved
	noNotify  bool
	noLaunch  bool
	stopAfter int
	seen      int
}

func (h *watchHandler) dispatch(ctx context.Context) func(transport.SSEEvent) error {
	return func(ev transport.SSEEvent) error {
		switch ev.Type {
		case sse.EventTypeHandoffCreated:
			return h.onHandoffCreated(ctx, ev)
		case sse.EventTypeCommentCreated:
			return h.onCommentCreated(ctx, ev)
		default:
			return nil
		}
	}
}

func (h *watchHandler) onHandoffCreated(ctx context.Context, ev transport.SSEEvent) error {
	var notice handoffschema.ListItem
	if err := json.Unmarshal(ev.Data, &notice); err != nil {
		fmt.Fprintf(os.Stderr, "warning: bad event payload: %v\n", err)
		return nil
	}
	pkg, err := h.client.Get(ctx, notice.ID)
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: fetch %s: %v\n", notice.ID, err)
		return nil
	}
	mat, err := inbox.Materialize(h.repoRoot, pkg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: materialize %s: %v\n", notice.ID, err)
		return nil
	}
	if err := inbox.DownloadAttachments(ctx, h.client, mat.Dir, pkg); err != nil {
		fmt.Fprintf(os.Stderr, "warning: download attachments for %s: %v\n", notice.ID, err)
	}
	fmt.Printf("⇣ %s from %s → %s\n", pkg.ID, pkg.Sender, mat.Dir)

	if !h.noNotify {
		body := pkg.Sender + ": " + notice.Headline
		if body == pkg.Sender+": " {
			body = pkg.Sender + " sent a handoff (" + pkg.Repo.Name + ")"
		}
		subtitle := string(pkg.Urgency)
		if pkg.Urgency == handoffschema.UrgencyNormal {
			subtitle = pkg.Repo.Name
		}
		_ = notify.Show(ctx, notify.Notification{
			Title:    "cc-handoff",
			Subtitle: subtitle,
			Body:     body,
		})
	}

	if pkg.Urgency == handoffschema.UrgencyUrgent && h.res.Triggers.AutoLaunch {
		err := notify.LaunchTerminal(ctx, notify.LaunchOpts{
			App:        h.res.Triggers.TerminalApp,
			CWD:        h.repoRoot,
			PromptFile: filepath.Join(mat.Dir, "prompt.md"),
			Dry:        h.noLaunch,
		})
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: auto-launch failed: %v\n", err)
		}
	}

	return h.bumpAndMaybeStop()
}

// onCommentCreated appends the comment to comments.md inside the previously-
// materialized inbox dir (creating it on demand for the sender side, who
// won't have one until the first comment arrives).
func (h *watchHandler) onCommentCreated(ctx context.Context, ev transport.SSEEvent) error {
	var c handoffschema.Comment
	if err := json.Unmarshal(ev.Data, &c); err != nil {
		fmt.Fprintf(os.Stderr, "warning: bad comment event payload: %v\n", err)
		return nil
	}
	dir := inbox.PackageDir(h.repoRoot, c.HandoffID)
	if err := appendCommentToFile(dir, c); err != nil {
		fmt.Fprintf(os.Stderr, "warning: append comment %s: %v\n", c.HandoffID, err)
	}
	fmt.Printf("💬 %s on %s: %s\n", c.Sender, c.HandoffID, firstLine(c.Body))

	if !h.noNotify {
		_ = notify.Show(ctx, notify.Notification{
			Title:    "cc-handoff comment",
			Subtitle: c.HandoffID,
			Body:     c.Sender + ": " + firstLine(c.Body),
		})
	}

	return h.bumpAndMaybeStop()
}

func (h *watchHandler) bumpAndMaybeStop() error {
	h.seen++
	if h.stopAfter > 0 && h.seen >= h.stopAfter {
		return errStop
	}
	return nil
}

func appendCommentToFile(dir string, c handoffschema.Comment) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	path := filepath.Join(dir, "comments.md")
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = fmt.Fprintf(f, "## %s — %s\n\n%s\n\n",
		c.Sender, c.CreatedAt.Format("2006-01-02 15:04:05 MST"), c.Body)
	return err
}

func firstLine(s string) string {
	first, _, _ := strings.Cut(s, "\n")
	return first
}

// errStop signals the SSE loop to exit cleanly (used by --stop-after).
var errStop = fmt.Errorf("watch: requested stop")
