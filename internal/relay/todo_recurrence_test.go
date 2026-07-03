package relay

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
	"github.com/cc-collaboration/pkg/todoschema"
)

func newTodoTestStore(t *testing.T) *store.Store {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	return st
}

// recvEvent waits briefly for an event on sub and fails the test if none
// arrives — used to assert an identity WAS notified without depending on
// real wall-clock sleeps for pacing (a real ticker/time.Sleep is never used
// to drive the sweep itself in these tests, only this short bound on
// draining an in-memory channel that Publish already wrote to
// synchronously).
func recvEvent(t *testing.T, sub *sse.Subscriber) sse.Event {
	t.Helper()
	select {
	case e := <-sub.C():
		return e
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for SSE event")
		return sse.Event{}
	}
}

func assertNoEvent(t *testing.T, sub *sse.Subscriber) {
	t.Helper()
	select {
	case e := <-sub.C():
		t.Fatalf("unexpected SSE event: %+v", e)
	default:
	}
}

// --- sweepDueTodos ---

func TestSweepDueTodosResetsPersonalTodoAndNotifiesOwner(t *testing.T) {
	st := newTodoTestStore(t)
	ctx := context.Background()
	hub := sse.NewHub()

	sub, cancel := hub.Subscribe("alice@x")
	defer cancel()

	srv := &Server{Store: st, Hub: hub}

	completedAt := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	next := completedAt.AddDate(0, 0, 1)
	td := &todoschema.Todo{
		ID:               "td1",
		OwnerIdentity:    "alice@x",
		Title:            "water plants",
		Status:           todoschema.StatusDone,
		Recurrence:       todoschema.RecurrenceDaily,
		CompletedAt:      &completedAt,
		NextOccurrenceAt: &next,
	}
	if err := st.CreateTodo(ctx, td); err != nil {
		t.Fatalf("create todo: %v", err)
	}

	// Not yet due: sweeping before next_occurrence_at is a no-op.
	sweepDueTodos(ctx, srv, completedAt.Add(time.Hour))
	assertNoEvent(t, sub)
	got, err := st.GetTodo(ctx, "td1", "alice@x")
	if err != nil {
		t.Fatalf("get after early sweep: %v", err)
	}
	if got.Status != todoschema.StatusDone {
		t.Fatalf("status after early sweep = %q, want done", got.Status)
	}

	// Due: sweeping at/after next_occurrence_at resets it and notifies the owner.
	sweepDueTodos(ctx, srv, next.Add(time.Minute))

	got, err = st.GetTodo(ctx, "td1", "alice@x")
	if err != nil {
		t.Fatalf("get after due sweep: %v", err)
	}
	if got.Status != todoschema.StatusTodo {
		t.Fatalf("status after due sweep = %q, want pending", got.Status)
	}
	if got.CompletedAt != nil || got.NextOccurrenceAt != nil {
		t.Fatalf("expected completed_at/next_occurrence_at cleared, got %+v / %+v", got.CompletedAt, got.NextOccurrenceAt)
	}

	e := recvEvent(t, sub)
	if e.Type != sse.EventTypeTodoStatusChanged {
		t.Fatalf("event type = %q, want %q", e.Type, sse.EventTypeTodoStatusChanged)
	}
	var payload todoschema.Todo
	if err := json.Unmarshal(e.Data, &payload); err != nil {
		t.Fatalf("unmarshal event payload: %v", err)
	}
	if payload.ID != "td1" || payload.Status != todoschema.StatusTodo {
		t.Fatalf("event payload = %+v, want reset td1/pending", payload)
	}

	// Second sweep at the same or later `now` is a harmless no-op (already pending).
	sweepDueTodos(ctx, srv, next.Add(time.Hour))
	assertNoEvent(t, sub)
}

func TestSweepDueTodosNotifiesEveryProjectMemberForTeamTodo(t *testing.T) {
	st := newTodoTestStore(t)
	ctx := context.Background()
	hub := sse.NewHub()
	srv := &Server{Store: st, Hub: hub}
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	if err := st.CreateProject(ctx, "p1", "Kunlun", "owner@x", now); err != nil {
		t.Fatalf("create project: %v", err)
	}
	if err := st.AddMember(ctx, "p1", "dev@x", store.RoleMember); err != nil {
		t.Fatalf("add member: %v", err)
	}
	if err := st.AddMember(ctx, "p1", "qa@x", store.RoleViewer); err != nil {
		t.Fatalf("add viewer: %v", err)
	}

	subOwner, cancelOwner := hub.Subscribe("owner@x")
	defer cancelOwner()
	subDev, cancelDev := hub.Subscribe("dev@x")
	defer cancelDev()
	subQA, cancelQA := hub.Subscribe("qa@x")
	defer cancelQA()
	subStranger, cancelStranger := hub.Subscribe("stranger@x")
	defer cancelStranger()

	completedAt := now.Add(-25 * time.Hour)
	next := completedAt.AddDate(0, 0, 1) // due 1h ago relative to `now`
	td := &todoschema.Todo{
		ID:               "td2",
		ProjectID:        "p1",
		OwnerIdentity:    "owner@x",
		Title:            "team standup notes",
		Status:           todoschema.StatusDone,
		Recurrence:       todoschema.RecurrenceDaily,
		CompletedAt:      &completedAt,
		NextOccurrenceAt: &next,
	}
	if err := st.CreateTodo(ctx, td); err != nil {
		t.Fatalf("create team todo: %v", err)
	}

	sweepDueTodos(ctx, srv, now)

	for _, sub := range []*sse.Subscriber{subOwner, subDev, subQA} {
		e := recvEvent(t, sub)
		if e.Type != sse.EventTypeTodoStatusChanged {
			t.Fatalf("event type = %q, want %q", e.Type, sse.EventTypeTodoStatusChanged)
		}
	}
	assertNoEvent(t, subStranger)

	got, err := st.GetTodo(ctx, "td2", "owner@x")
	if err != nil {
		t.Fatalf("get after sweep: %v", err)
	}
	if got.Status != todoschema.StatusTodo {
		t.Fatalf("status after sweep = %q, want pending", got.Status)
	}
}

func TestSweepDueTodosNilHubIsNoop(t *testing.T) {
	st := newTodoTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	completedAt := now.Add(-25 * time.Hour)
	next := completedAt.AddDate(0, 0, 1)
	td := &todoschema.Todo{
		ID:               "td3",
		OwnerIdentity:    "alice@x",
		Title:            "no hub",
		Status:           todoschema.StatusDone,
		Recurrence:       todoschema.RecurrenceDaily,
		CompletedAt:      &completedAt,
		NextOccurrenceAt: &next,
	}
	if err := st.CreateTodo(ctx, td); err != nil {
		t.Fatalf("create todo: %v", err)
	}

	// Must not panic with a nil hub (e.g. a deployment that never wires SSE).
	sweepDueTodos(ctx, &Server{Store: st}, now)

	got, err := st.GetTodo(ctx, "td3", "alice@x")
	if err != nil {
		t.Fatalf("get after sweep: %v", err)
	}
	if got.Status != todoschema.StatusTodo {
		t.Fatalf("status after sweep = %q, want pending", got.Status)
	}
}

// --- RunTodoRecurrenceSweep ---

func TestRunTodoRecurrenceSweepExitsOnContextCancel(t *testing.T) {
	st := newTodoTestStore(t)
	hub := sse.NewHub()
	srv := &Server{Store: st, Hub: hub}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		RunTodoRecurrenceSweep(ctx, srv, time.Hour)
		close(done)
	}()

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("RunTodoRecurrenceSweep did not exit after context cancel")
	}
}
