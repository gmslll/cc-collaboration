package main

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/cc-collaboration/internal/agent"
	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/inbox"
	"github.com/cc-collaboration/internal/linear"
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
	noMaterialize := fs.Bool("no-materialize", false, "do not pre-materialize handoffs into the local inbox; notify only (useful when one identity owns multiple receiver repos and pickup picks the target)")
	workdir := fs.String("workdir", "", "repo path to watch from (default: current working directory)")
	stopAfter := fs.Int("stop-after", 0, "stop after N events (0 = run forever)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	cwd, err := resolveRepoFlag(*workdir, "--workdir")
	if err != nil {
		return err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return err
	}

	repoRoot := config.RepoRoot(cwd)
	h := &watchHandler{
		client:        transport.New(res.RelayURL, res.Token),
		repoRoot:      repoRoot,
		inboxDir:      inbox.InboxDir(repoRoot, res.InboxOverride),
		res:           res,
		noNotify:      *noNotify,
		noLaunch:      *noLaunch,
		noMaterialize: *noMaterialize,
		stopAfter:     *stopAfter,
		seen:          map[string]bool{},
	}

	fmt.Printf("watching for handoffs to %s on %s …\n", res.Me, res.RelayURL)
	if *noMaterialize && res.Triggers.AutoLaunch {
		fmt.Fprintln(os.Stderr, "warning: --no-materialize disables auto_launch — no terminal will be opened for urgent handoffs in this session")
	}

	if !*noCatchup {
		if err := h.catchUp(ctx); err != nil {
			fmt.Fprintf(os.Stderr, "warning: catch-up failed: %v\n", err)
		}
	}

	if interval, ok := parseLinearPollInterval(res); ok {
		fmt.Printf("polling Linear notifications every %s\n", interval)
		go runLinearPoller(ctx, res, interval, *noNotify)
	}

	return h.client.Subscribe(ctx, res.Me, h.dispatch(ctx))
}

// parseLinearPollInterval returns the configured Linear poll interval, or
// (0, false) when the feature is off (empty / "0" / unparseable / no token /
// missing personal token). Returning false means "don't even spawn the
// goroutine" rather than spawning a no-op one.
func parseLinearPollInterval(res *config.Resolved) (time.Duration, bool) {
	raw := res.Linear.Notifications.PollInterval
	if raw == "" || raw == "0" {
		return 0, false
	}
	if res.LinearPersonalToken == "" {
		fmt.Fprintln(os.Stderr, "warning: linear notifications poll_interval set but linear_personal_token missing in user config; skipping poller")
		return 0, false
	}
	d, err := time.ParseDuration(raw)
	if err != nil || d <= 0 {
		fmt.Fprintf(os.Stderr, "warning: invalid linear poll_interval %q: %v\n", raw, err)
		return 0, false
	}
	return d, true
}

// runLinearPoller drives a ticker loop that pulls new Linear notifications
// every `interval` and fires desktop notifications for each. Errors trigger
// exponential backoff up to 5 minutes — Linear API hiccups (rate limits,
// transient 5xx) shouldn't kill the watch process.
func runLinearPoller(ctx context.Context, res *config.Resolved, interval time.Duration, noNotify bool) {
	cursorPath, err := linear.CursorPath()
	if err != nil {
		fmt.Fprintf(os.Stderr, "linear poller: cursor path: %v\n", err)
		return
	}
	client := linear.NewClient(res.LinearPersonalToken)
	const maxBackoff = 5 * time.Minute
	// First tick fires immediately so a fresh `watch` doesn't wait the full
	// interval before establishing baseline; subsequent ticks use `interval`.
	delay := time.Duration(0)

	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(delay):
		}

		since, err := linear.LoadCursor(cursorPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "linear poller: load cursor: %v\n", err)
			delay = backoff(maxDuration(delay, time.Second), maxBackoff)
			continue
		}
		items, newCursor, err := linear.PollOnce(ctx, client, since, res.Linear.Notifications.Types)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return
			}
			fmt.Fprintf(os.Stderr, "linear poller: %v (backing off)\n", err)
			delay = backoff(maxDuration(delay, time.Second), maxBackoff)
			continue
		}
		if !newCursor.Equal(since) {
			if err := linear.SaveCursor(cursorPath, newCursor); err != nil {
				fmt.Fprintf(os.Stderr, "linear poller: save cursor: %v\n", err)
			}
		}
		for _, it := range items {
			fmt.Printf("📬 Linear @%s in %s — %s\n", it.ActorName, it.IssueIdent, it.IssueTitle)
			if !noNotify {
				_ = notify.Show(ctx, linear.ToNotify(it))
			}
		}
		delay = interval
	}
}

func maxDuration(a, b time.Duration) time.Duration {
	if a > b {
		return a
	}
	return b
}

func backoff(current, max time.Duration) time.Duration {
	next := current * 2
	if next > max {
		return max
	}
	return next
}

// watchHandler bundles per-session state shared by both event types.
type watchHandler struct {
	client        *transport.Client
	repoRoot      string
	inboxDir      string // resolved once at start; used for Materialize / cursor / PackageDir
	res           *config.Resolved
	noNotify      bool
	noLaunch      bool
	noMaterialize bool // notify-only mode; skips package fetch + on-disk materialize. Auto-launch and retract markers are also gated since they depend on the materialized dir.
	stopAfter     int
	dispatched    int             // count of events dispatched this session (used by --stop-after)
	seen          map[string]bool // handoff IDs already dispatched this session, for catch-up + SSE dedup
	cursor        inbox.WatchCursor
	batchCursor   bool // true while catch-up is replaying comments; defers cursor save to per-page flush
	inCatchUp     bool // notifyOnly suppresses per-item notifications while true; catchUp emits one summary at the end
	catchUpCount  int  // number of pending handoffs surfaced during catch-up; reset before each catchUp call
}

const catchUpPageSize = 100

func (h *watchHandler) dispatch(ctx context.Context) func(transport.SSEEvent) error {
	return func(ev transport.SSEEvent) error {
		switch ev.Type {
		case sse.EventTypeHandoffCreated:
			return h.onHandoffCreated(ctx, ev)
		case sse.EventTypeCommentCreated:
			return h.onCommentCreated(ctx, ev)
		case sse.EventTypeHandoffRetracted:
			return h.onHandoffRetracted(ctx, ev)
		case sse.EventTypeUserOnline:
			return h.onUserPresence(ctx, ev, true)
		case sse.EventTypeUserOffline:
			return h.onUserPresence(ctx, ev, false)
		case sse.EventTypeLogAlert:
			return h.onLogAlert(ctx, ev)
		default:
			return nil
		}
	}
}

// onHandoffRetracted is fired when the sender retracts a handoff that was
// addressed to us. We don't delete the materialized files (the user might
// want to glance at what was sent) — instead, we drop a marker file and
// pop a notification, so the next time anyone runs `cc-handoff inbox` they
// see the RET flag and don't waste time thinking it's still actionable.
func (h *watchHandler) onHandoffRetracted(ctx context.Context, ev transport.SSEEvent) error {
	var ret handoffschema.RetractEvent
	if err := json.Unmarshal(ev.Data, &ret); err != nil {
		fmt.Fprintf(os.Stderr, "warning: bad retract payload: %v\n", err)
		return nil
	}
	if !h.noMaterialize {
		dir := inbox.PackageDir(h.inboxDir, ret.ID)
		if err := writeRetractedMarker(dir, ret); err != nil {
			fmt.Fprintf(os.Stderr, "warning: write RETRACTED.md %s: %v\n", ret.ID, err)
		}
	}
	fmt.Printf("⚠ %s retracted handoff %s\n", ret.Sender, ret.ID)

	if !h.noNotify {
		body := ret.Sender + " retracted handoff " + ret.ID
		if ret.Reason != "" {
			body += ": " + ret.Reason
		}
		_ = notify.Show(ctx, notify.Notification{
			Title:    "cc-handoff retracted",
			Subtitle: ret.ID,
			Body:     body,
		})
	}
	return h.bumpAndMaybeStop()
}

// writeRetractedMarker drops a RETRACTED.md inside the materialized handoff
// dir so `cc-handoff inbox` can flag it. Idempotent: re-creates with newer
// timestamp on duplicate events (relay shouldn't fire twice, but SSE replay
// after reconnect is a thing).
func writeRetractedMarker(dir string, ret handoffschema.RetractEvent) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	body := fmt.Sprintf("# Retracted by %s\n\nReason: %s\nAt: %s\n",
		ret.Sender,
		cmp.Or(ret.Reason, "(none given)"),
		time.Now().Format("2006-01-02 15:04:05 MST"),
	)
	return os.WriteFile(filepath.Join(dir, "RETRACTED.md"), []byte(body), 0o644)
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

	if h.noMaterialize {
		return h.notifyOnly(ctx, notice)
	}

	pkg, err := h.client.Get(ctx, notice.ID)
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: fetch %s: %v\n", notice.ID, err)
		return nil
	}
	// Default to doc-first; pickup re-materializes with the user's actual choice.
	mat, err := inbox.Materialize(h.inboxDir, pkg, inbox.ModeDocFirst)
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: materialize %s: %v\n", notice.ID, err)
		return nil
	}
	if err := inbox.DownloadAttachments(ctx, h.client, mat.Dir, pkg); err != nil {
		fmt.Fprintf(os.Stderr, "warning: download attachments for %s: %v\n", notice.ID, err)
	}
	fmt.Printf("⇣ %s from %s → %s\n", pkg.ID, pkg.Sender, mat.Dir)

	if !h.noNotify {
		_ = notify.Show(ctx, buildHandoffNotice(notice))
	}

	if h.res.Triggers.AutoLaunch && (pkg.Urgency == handoffschema.UrgencyUrgent || h.res.Triggers.AutoLaunchNormal) {
		err := notify.LaunchTerminal(ctx, buildLaunchOpts(h.res, h.repoRoot, filepath.Join(mat.Dir, "prompt.md"), notice.ID, h.noLaunch))
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: auto-launch failed: %v\n", err)
		}
	}

	return h.bumpAndMaybeStop()
}

// notifyOnly is the --no-materialize branch: skip the full package fetch and
// on-disk write so multi-repo receivers can route handoffs at pickup time
// without watch pre-materializing into whichever repo it happens to live in.
// During catch-up, individual notifications are suppressed — catchUp emits
// one aggregate "N 条待处理" notice once the replay finishes so a long-offline
// receiver doesn't get hit with N native banners in a row.
func (h *watchHandler) notifyOnly(ctx context.Context, notice handoffschema.ListItem) error {
	fmt.Printf("⇣ %s from %s (notify-only, not materialized)\n", notice.ID, notice.Sender)

	if h.inCatchUp {
		h.catchUpCount++
		return h.bumpAndMaybeStop()
	}

	if !h.noNotify {
		_ = notify.Show(ctx, buildHandoffNotice(notice))
	}

	return h.bumpAndMaybeStop()
}

// buildHandoffNotice composes the desktop notification payload used by both
// the materialize and notify-only paths so a future tweak to format lands in
// one place. Sender / Urgency / RepoName are populated by both REST (List)
// and SSE (NoticeListItem); Headline only became reliable on SSE after the
// schema fix in pkg/handoffschema/package.go — old relays will still send
// empty Headline, in which case the fallback body kicks in.
func buildHandoffNotice(item handoffschema.ListItem) notify.Notification {
	sender := item.Sender
	if sender == "" {
		sender = "someone"
	}
	body := sender + ": " + item.Headline
	if item.Headline == "" {
		body = sender + " sent a handoff (" + item.RepoName + ")"
	}
	subtitle := string(item.Urgency)
	if item.Urgency == handoffschema.UrgencyNormal {
		subtitle = item.RepoName
	}
	return notify.Notification{
		Title:    "cc-handoff",
		Subtitle: subtitle,
		Body:     body,
	}
}

// onLogAlert handles a pushed server log alert: resolve the named project to a
// local dir, write the alert as a triage prompt (so there's always a file to
// open), pop a desktop notification, and — only when auto_launch_on_alert is
// set — launch the agent in a new terminal to start triaging. Auto-launch
// always opens a window (never in-place exec) so it doesn't replace the watch
// daemon's own process. A project we can't resolve degrades to notify-only.
func (h *watchHandler) onLogAlert(ctx context.Context, ev transport.SSEEvent) error {
	var alert handoffschema.LogAlert
	if err := json.Unmarshal(ev.Data, &alert); err != nil {
		fmt.Fprintf(os.Stderr, "warning: bad log alert payload: %v\n", err)
		return nil
	}
	from := cmp.Or(alert.Sender, "server")
	fmt.Printf("🔔 log alert from %s", from)
	if alert.Project != "" {
		fmt.Printf(" → %s", alert.Project)
	}
	fmt.Println()

	ws, p, promptFile := h.resolveAlertTriage(alert, from)

	if !h.noNotify {
		_ = notify.Show(ctx, notify.Notification{
			Title:    "cc-handoff log alert",
			Subtitle: cmp.Or(alert.Level, alert.Project, from),
			Body:     from + ": " + firstLine(alert.Message),
		})
	}

	if h.res.Triggers.AutoLaunchOnAlert && promptFile != "" {
		if h.noLaunch {
			fmt.Printf("  [no-launch] would launch agent in %s on %s\n", p.Path, promptFile)
		} else {
			ag := h.res.Agent
			if ws.Agent != "" {
				if a, err := agent.Resolve(ws.Agent); err == nil {
					ag = a
				}
			}
			if err := launchAgentWithPrompt(ctx, ag, p.Path, promptFile, ws.PreLaunch, true); err != nil {
				fmt.Fprintf(os.Stderr, "warning: alert auto-launch failed: %v\n", err)
			}
		}
	}

	return h.bumpAndMaybeStop()
}

// resolveAlertTriage resolves a log alert's project to a local workspace
// project and writes the alert body as a triage prompt, returning the project
// and the prompt-file path. It returns an empty path (and logs a warning) when
// the alert has no project, the user config can't be loaded, the project can't
// be resolved locally, or the file write fails — the caller then degrades to
// notify-only. LoadUser is read per-alert (not cached) so a project added to
// config mid-session resolves without restarting watch.
func (h *watchHandler) resolveAlertTriage(alert handoffschema.LogAlert, from string) (config.Workspace, config.Project, string) {
	if alert.Project == "" {
		return config.Workspace{}, config.Project{}, ""
	}
	u, _, err := config.LoadUser()
	if err != nil || u == nil {
		fmt.Fprintf(os.Stderr, "warning: load user config for alert: %v\n", err)
		return config.Workspace{}, config.Project{}, ""
	}
	ws, p, err := resolveProject(u, alert.Project, "")
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: resolve project %q: %v\n", alert.Project, err)
		return config.Workspace{}, config.Project{}, ""
	}
	_, matchLine := extractLatestError(alert.Message, defaultErrorRe, 0, 0)
	f, dup := logTriageTarget(p.Path, cmp.Or(matchLine, alert.Message))
	if dup {
		fmt.Printf("  duplicate error, already backed up — %s\n", f)
		return ws, p, f
	}
	body := logTriageMarkdown(p.Name, "push alert from "+from, time.Now().Format(time.RFC3339), "", alert.Level, alert.Message)
	if err := writeTriageFile(f, body); err != nil {
		fmt.Fprintf(os.Stderr, "warning: write log triage: %v\n", err)
		return ws, p, ""
	}
	fmt.Printf("  wrote %s\n", f)
	return ws, p, f
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
	if !h.noMaterialize {
		dir := inbox.PackageDir(h.inboxDir, c.HandoffID)
		if err := appendCommentToFile(dir, c); err != nil {
			fmt.Fprintf(os.Stderr, "warning: append comment %s: %v\n", c.HandoffID, err)
		}
		if h.res.Triggers.WakeOnComment && c.Sender != h.res.Me {
			if err := inbox.WriteUnread(dir, c); err != nil {
				fmt.Fprintf(os.Stderr, "warning: write unread marker %d: %v\n", c.ID, err)
			}
		}
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

// onUserPresence surfaces user.online / user.offline events as desktop
// notifications. Reconnect blips can flap; user can mute via the
// mute_user_presence trigger. Doesn't count toward --stop-after — those
// counters target handoff/comment flows, presence is a side channel.
func (h *watchHandler) onUserPresence(ctx context.Context, ev transport.SSEEvent, online bool) error {
	if h.res.Triggers.MuteUserPresence {
		return nil
	}
	var u handoffschema.OnlineUser
	if err := json.Unmarshal(ev.Data, &u); err != nil {
		fmt.Fprintf(os.Stderr, "warning: bad presence payload: %v\n", err)
		return nil
	}
	if u.Identity == "" || u.Identity == h.res.Me {
		return nil
	}
	state := "offline"
	glyph := "⚪"
	if online {
		state = "online"
		glyph = "🟢"
	}
	fmt.Printf("%s %s is %s\n", glyph, u.Identity, state)
	if !h.noNotify {
		_ = notify.Show(ctx, notify.Notification{
			Title:    "cc-handoff",
			Subtitle: state,
			Body:     u.Identity + " is " + state,
		})
	}
	return nil
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
	if err := inbox.SaveCursor(h.inboxDir, h.cursor); err != nil {
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

// buildLaunchOpts maps the resolved [triggers] config to a notify.LaunchOpts
// for the auto-launch / `cc-handoff open` paths. Both call sites take the
// same fields; a helper keeps them in sync as new triggers are added.
func buildLaunchOpts(res *config.Resolved, cwd, promptFile, handoffID string, dry bool) notify.LaunchOpts {
	return notify.LaunchOpts{
		Agent:       res.Agent,
		App:         res.Triggers.TerminalApp,
		CWD:         cwd,
		PromptFile:  promptFile,
		Dry:         dry,
		PreLaunch:   res.Triggers.PreLaunch,
		Interactive: res.Triggers.LaunchInteractive,
		Mode:        res.Triggers.LaunchMode,
		HandoffID:   handoffID,
		AckOnLaunch: res.Triggers.AckOnLaunch,
	}
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
	h.inCatchUp = true
	h.catchUpCount = 0
	defer func() { h.inCatchUp = false }()

	if err := h.replayPendingHandoffs(ctx); err != nil {
		return err
	}
	if h.noMaterialize && !h.noNotify && h.catchUpCount > 0 {
		_ = notify.Show(ctx, notify.Notification{
			Title:    "cc-handoff",
			Subtitle: fmt.Sprintf("%d 条待处理 handoff", h.catchUpCount),
			Body:     fmt.Sprintf("watching as %s — 用 cc-handoff list 查看 / cc-handoff pickup <id> --repo <path> 物化", h.res.Me),
		})
	}

	cursor, exists, err := inbox.LoadCursor(h.inboxDir)
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
	if err := inbox.SaveCursor(h.inboxDir, h.cursor); err != nil {
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
					_ = inbox.SaveCursor(h.inboxDir, h.cursor)
					return nil
				}
				return err
			}
		}
		if err := inbox.SaveCursor(h.inboxDir, h.cursor); err != nil {
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
	platform := fs.String("platform", "", "launchd | systemd | windows-task (default: launchd on macOS, windows-task on Windows, systemd elsewhere)")
	workDir := fs.String("workdir", "", "absolute path to the receiving repo (default: current working directory)")
	binPath := fs.String("bin", "", "absolute path to the cc-handoff binary (default: the running binary)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	if *platform == "" {
		switch runtime.GOOS {
		case "darwin":
			*platform = string(setup.PlatformLaunchd)
		case "windows":
			*platform = string(setup.PlatformWindowsTask)
		default:
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
