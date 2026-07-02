package relay

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
	"github.com/cc-collaboration/pkg/todoschema"
)

// EventTypeTodoStatusChanged is published when the recurrence sweep resets
// a due recurring todo back to pending. Track A (internal/relay/todos.go)
// is expected to define the sibling todo.created/updated/assigned/deleted/
// comment_created constants and may end up owning a shared
// publishTodoEvent helper that supersedes the minimal one here — see
// publishTodoStatusChanged.
const EventTypeTodoStatusChanged = "todo.status_changed"

// RunTodoRecurrenceSweep runs sweepDueTodos every interval until ctx is
// cancelled. Intended to be started as
// `go relay.RunTodoRecurrenceSweep(ctx, st, hub, time.Minute)` bound to the
// same shutdown context the HTTP server's Shutdown call uses, so the
// goroutine exits cleanly alongside the server on SIGINT/SIGTERM instead of
// leaking past process shutdown.
func RunTodoRecurrenceSweep(ctx context.Context, st *store.Store, hub *sse.Hub, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			sweepDueTodos(ctx, st, hub, time.Now().UTC())
		}
	}
}

// sweepDueTodos resets every done, recurring todo whose next_occurrence_at
// has elapsed as of now back to pending (via Store.DueRecurringTodos /
// Store.ResetRecurringTodo — see the recurrence semantics note on those
// methods in internal/relay/store/todos.go) and publishes a
// todo.status_changed SSE event for each one reset. Split out from
// RunTodoRecurrenceSweep so tests can drive the sweep logic directly with
// an explicit `now` instead of waiting on a real ticker/time.Sleep.
func sweepDueTodos(ctx context.Context, st *store.Store, hub *sse.Hub, now time.Time) {
	due, err := st.DueRecurringTodos(ctx, now)
	if err != nil {
		slog.Error("todo recurrence sweep: list due todos", "err", err)
		return
	}
	for _, t := range due {
		reset, err := st.ResetRecurringTodo(ctx, t.ID, now)
		if err != nil {
			slog.Error("todo recurrence sweep: reset todo", "todo_id", t.ID, "err", err)
			continue
		}
		publishTodoStatusChanged(ctx, st, hub, reset)
	}
}

// publishTodoStatusChanged fans a todo.status_changed SSE event (full Todo
// JSON payload, per the plan's "SSE 事件" contract) out to whoever can see
// t: every member of its project for a team todo, or just its owner for a
// personal one. This is a minimal, self-contained fan-out written against
// Store.ListMembers directly because Track A's general
// todoTargets/publishTodoEvent helper (internal/relay/todos.go) doesn't
// exist yet in this worktree — once it lands, this should probably be
// deduped against it rather than kept as a second implementation.
func publishTodoStatusChanged(ctx context.Context, st *store.Store, hub *sse.Hub, t todoschema.Todo) {
	if hub == nil {
		return
	}
	targets, err := todoRecipients(ctx, st, t)
	if err != nil {
		slog.Error("todo recurrence sweep: resolve recipients", "todo_id", t.ID, "err", err)
		return
	}
	if len(targets) == 0 {
		return
	}
	data, err := json.Marshal(t)
	if err != nil {
		slog.Error("todo recurrence sweep: marshal todo", "todo_id", t.ID, "err", err)
		return
	}
	for _, rec := range targets {
		hub.Publish(sse.Event{Type: EventTypeTodoStatusChanged, Recipient: rec, Data: data})
	}
}

// todoRecipients returns the identities who should receive an SSE event
// about t: every member of its project for a team todo (t.ProjectID set),
// or just the owner for a personal todo.
func todoRecipients(ctx context.Context, st *store.Store, t todoschema.Todo) ([]string, error) {
	if t.ProjectID == "" {
		if t.OwnerIdentity == "" {
			return nil, nil
		}
		return []string{t.OwnerIdentity}, nil
	}
	members, err := st.ListMembers(ctx, t.ProjectID)
	if err != nil {
		return nil, err
	}
	targets := make([]string, 0, len(members))
	for _, m := range members {
		targets = append(targets, m.Identity)
	}
	return targets, nil
}
