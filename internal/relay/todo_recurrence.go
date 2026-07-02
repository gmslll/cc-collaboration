package relay

import (
	"context"
	"log/slog"
	"time"

	"github.com/cc-collaboration/internal/relay/sse"
)

// RunTodoRecurrenceSweep runs sweepDueTodos every interval until ctx is
// cancelled. Intended to be started as
// `go relay.RunTodoRecurrenceSweep(ctx, srv, time.Minute)` bound to the
// same shutdown context the HTTP server's Shutdown call uses, so the
// goroutine exits cleanly alongside the server on SIGINT/SIGTERM instead of
// leaking past process shutdown.
func RunTodoRecurrenceSweep(ctx context.Context, srv *Server, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			sweepDueTodos(ctx, srv, time.Now().UTC())
		}
	}
}

// sweepDueTodos resets every done, recurring todo whose next_occurrence_at
// has elapsed as of now back to pending (via Store.DueRecurringTodos /
// Store.ResetRecurringTodo — see the recurrence semantics note on those
// methods in internal/relay/store/todos.go) and publishes a
// todo.status_changed SSE event for each one reset, via the same
// Server.publishTodoEvent fan-out the HTTP handlers use (see
// internal/relay/todos.go) so team todos reach every project member and
// personal todos reach only their owner.
func sweepDueTodos(ctx context.Context, srv *Server, now time.Time) {
	due, err := srv.Store.DueRecurringTodos(ctx, now)
	if err != nil {
		slog.Error("todo recurrence sweep: list due todos", "err", err)
		return
	}
	for _, t := range due {
		reset, err := srv.Store.ResetRecurringTodo(ctx, t.ID, now)
		if err != nil {
			slog.Error("todo recurrence sweep: reset todo", "todo_id", t.ID, "err", err)
			continue
		}
		srv.publishTodoEvent(ctx, sse.EventTypeTodoStatusChanged, reset)
	}
}
