package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/inbox"
	"github.com/cc-collaboration/internal/notify"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/setup"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

func runWatch(ctx context.Context, args []string) error {
	if len(args) > 0 && args[0] == "print-unit" {
		return runWatchPrintUnit(args[1:])
	}

	fs := flag.NewFlagSet("watch", flag.ContinueOnError)
	noNotify := fs.Bool("no-notify", false, "skip desktop notification (useful for CI / e2e tests)")
	noLaunch := fs.Bool("no-launch", false, "log auto-launch invocations instead of opening a terminal")
	noCatchup := fs.Bool("no-catchup", false, "skip the startup catch-up that drains pending handoffs / unread comments")
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
		seen:      map[string]bool{},
	}

	fmt.Printf("watching for handoffs to %s on %s …\n", res.Me, res.RelayURL)

	if !*noCatchup {
		if err := h.catchUp(ctx); err != nil {
			fmt.Fprintf(os.Stderr, "warning: catch-up failed: %v\n", err)
		}
	}

	return h.client.Subscribe(ctx, res.Me, h.dispatch(ctx))
}

// watchHandler bundles per-session state shared by both event types.
type watchHandler struct {
	client      *transport.Client
	repoRoot    string
	res         *config.Resolved
	noNotify    bool
	noLaunch    bool
	stopAfter   int
	dispatched  int             // count of events dispatched this session (used by --stop-after)
	seen        map[string]bool // handoff IDs already dispatched this session, for catch-up + SSE dedup
	cursor      inbox.WatchCursor
	batchCursor bool // true while catch-up is replaying comments; defers cursor save to per-page flush
}

const catchUpPageSize = 100

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
	if h.seen[notice.ID] {
		return nil
	}
	h.seen[notice.ID] = true
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

	h.advanceCommentCursor(c.ID)
	return h.bumpAndMaybeStop()
}

// advanceCommentCursor pushes the persisted cursor forward so a watch restart
// resumes from the latest comment seen, not whatever was in the file at boot.
// During catch-up, batchCursor=true skips the per-event fsync; the caller
// flushes once per page.
func (h *watchHandler) advanceCommentCursor(id int64) {
	if id <= h.cursor.LastCommentID {
		return
	}
	h.cursor.LastCommentID = id
	if h.batchCursor {
		return
	}
	if err := inbox.SaveCursor(h.repoRoot, h.cursor); err != nil {
		fmt.Fprintf(os.Stderr, "warning: save cursor: %v\n", err)
	}
}

func (h *watchHandler) bumpAndMaybeStop() error {
	h.dispatched++
	if h.stopAfter > 0 && h.dispatched >= h.stopAfter {
		return errStop
	}
	return nil
}

// catchUp drains anything that piled up while watch was offline:
//   - pending handoffs addressed to me, dispatched through the same SSE handler
//     so notify / materialize / auto-launch all fire as if they just arrived;
//   - comments newer than the persisted cursor, replayed in id order.
//
// First run (no cursor file) bootstraps the cursor to the relay's current max
// comment id without dispatching, so freshly-installed watch doesn't replay
// year-old comments.
func (h *watchHandler) catchUp(ctx context.Context) error {
	if err := h.replayPendingHandoffs(ctx); err != nil {
		return err
	}

	cursor, exists, err := inbox.LoadCursor(h.repoRoot)
	if err != nil {
		return fmt.Errorf("load cursor: %w", err)
	}
	h.cursor = cursor

	if !exists {
		return h.bootstrapCommentCursor(ctx)
	}
	return h.replayCommentsSinceCursor(ctx)
}

func (h *watchHandler) replayPendingHandoffs(ctx context.Context) error {
	items, err := h.client.List(ctx, h.res.Me)
	if err != nil {
		return fmt.Errorf("list pending: %w", err)
	}
	for _, it := range items {
		data, err := json.Marshal(it)
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: marshal list item %s: %v\n", it.ID, err)
			continue
		}
		ev := transport.SSEEvent{Type: sse.EventTypeHandoffCreated, Data: data}
		if err := h.onHandoffCreated(ctx, ev); err != nil {
			if errors.Is(err, errStop) {
				return nil
			}
			return err
		}
	}
	return nil
}

func (h *watchHandler) bootstrapCommentCursor(ctx context.Context) error {
	_, maxID, err := h.client.ListInboxComments(ctx, 0, 0)
	if err != nil {
		return fmt.Errorf("bootstrap comment cursor: %w", err)
	}
	h.cursor.LastCommentID = maxID
	if err := inbox.SaveCursor(h.repoRoot, h.cursor); err != nil {
		return fmt.Errorf("save bootstrap cursor: %w", err)
	}
	if maxID > 0 {
		fmt.Printf("first run: bootstrapped comment cursor at id=%d (skipping history)\n", maxID)
	}
	return nil
}

func (h *watchHandler) replayCommentsSinceCursor(ctx context.Context) error {
	h.batchCursor = true
	defer func() { h.batchCursor = false }()

	for {
		comments, _, err := h.client.ListInboxComments(ctx, h.cursor.LastCommentID, catchUpPageSize)
		if err != nil {
			return fmt.Errorf("list inbox comments: %w", err)
		}
		if len(comments) == 0 {
			return nil
		}
		for _, c := range comments {
			data, err := json.Marshal(c)
			if err != nil {
				fmt.Fprintf(os.Stderr, "warning: marshal comment %d: %v\n", c.ID, err)
				continue
			}
			ev := transport.SSEEvent{Type: sse.EventTypeCommentCreated, Data: data}
			if err := h.onCommentCreated(ctx, ev); err != nil {
				if errors.Is(err, errStop) {
					_ = inbox.SaveCursor(h.repoRoot, h.cursor)
					return nil
				}
				return err
			}
		}
		if err := inbox.SaveCursor(h.repoRoot, h.cursor); err != nil {
			fmt.Fprintf(os.Stderr, "warning: save cursor: %v\n", err)
		}
		if len(comments) < catchUpPageSize {
			return nil
		}
	}
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

// runWatchPrintUnit renders the launchd plist or systemd user unit for the
// receiver-side watch daemon to stdout. It does not write any system files —
// piping the output to ~/Library/LaunchAgents/ or ~/.config/systemd/user/ is
// the user's job.
func runWatchPrintUnit(args []string) error {
	fs := flag.NewFlagSet("watch print-unit", flag.ContinueOnError)
	platform := fs.String("platform", "", "launchd | systemd (default: launchd on macOS, systemd elsewhere)")
	workDir := fs.String("workdir", "", "absolute path to the receiving repo (default: current working directory)")
	binPath := fs.String("bin", "", "absolute path to the cc-handoff binary (default: the running binary)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	if *platform == "" {
		if runtime.GOOS == "darwin" {
			*platform = string(setup.PlatformLaunchd)
		} else {
			*platform = string(setup.PlatformSystemd)
		}
	}
	if *workDir == "" {
		cwd, err := os.Getwd()
		if err != nil {
			return err
		}
		*workDir = cwd
	}
	if *binPath == "" {
		bin, err := setup.CurrentBinary()
		if err != nil {
			return fmt.Errorf("resolve current binary: %w", err)
		}
		*binPath = bin
	}
	return setup.RenderUnit(setup.Platform(*platform), setup.UnitParams{
		BinPath: *binPath,
		WorkDir: *workDir,
	}, os.Stdout)
}
