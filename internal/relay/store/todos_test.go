package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/cc-collaboration/pkg/todoschema"
)

func mustCreateTodo(t *testing.T, st *Store, td *todoschema.Todo) {
	t.Helper()
	if err := st.CreateTodo(context.Background(), td); err != nil {
		t.Fatalf("create todo %s: %v", td.ID, err)
	}
}

// --- personal todo visibility: only the owner has any access ---

func TestTodoPersonalVisibility(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	td := &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "buy milk"}
	mustCreateTodo(t, st, td)

	got, err := st.GetTodo(ctx, "td1", "alice@x")
	if err != nil {
		t.Fatalf("owner GetTodo: %v", err)
	}
	if got.Title != "buy milk" || got.Status != todoschema.StatusPending || got.Priority != todoschema.PriorityNormal {
		t.Fatalf("got %+v", got)
	}

	if _, err := st.GetTodo(ctx, "td1", "bob@x"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("stranger GetTodo: want ErrForbidden, got %v", err)
	}
	if _, err := st.GetTodo(ctx, "missing", "alice@x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing todo: want ErrNotFound, got %v", err)
	}

	mine, err := st.ListTodos(ctx, "alice@x", TodoListFilter{Scope: "personal"})
	if err != nil || len(mine) != 1 || mine[0].ID != "td1" {
		t.Fatalf("owner ListTodos personal: %+v err=%v", mine, err)
	}
	theirs, err := st.ListTodos(ctx, "bob@x", TodoListFilter{Scope: "personal"})
	if err != nil || len(theirs) != 0 {
		t.Fatalf("stranger ListTodos personal should be empty: %+v err=%v", theirs, err)
	}

	if _, err := st.UpdateTodoFields(ctx, "td1", "bob@x", TodoPatch{}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("stranger edit: want ErrForbidden, got %v", err)
	}
	newTitle := "buy oat milk"
	updated, err := st.UpdateTodoFields(ctx, "td1", "alice@x", TodoPatch{Title: &newTitle})
	if err != nil || updated.Title != newTitle {
		t.Fatalf("owner edit: %+v err=%v", updated, err)
	}

	if err := st.DeleteTodo(ctx, "td1", "bob@x"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("stranger delete: want ErrForbidden, got %v", err)
	}

	// Global admin sees (and can edit) a personal todo it doesn't own.
	if err := st.CreateUser(ctx, User{Identity: "admin@x", IsAdmin: true}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetTodo(ctx, "td1", "admin@x"); err != nil {
		t.Fatalf("admin GetTodo: %v", err)
	}
	if _, err := st.UpdateTodoFields(ctx, "td1", "admin@x", TodoPatch{Title: &newTitle}); err != nil {
		t.Fatalf("admin edit: %v", err)
	}

	if err := st.DeleteTodo(ctx, "td1", "alice@x"); err != nil {
		t.Fatalf("owner delete: %v", err)
	}
	if _, err := st.GetTodo(ctx, "td1", "alice@x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleted todo: want ErrNotFound, got %v", err)
	}
}

// --- team todo visibility: gated by project role, admin bypasses ---

func TestTodoTeamVisibilityByRole(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateProject(ctx, "p1", "Kunlun", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "p1", "member@x", RoleMember); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "p1", "viewer@x", RoleViewer); err != nil {
		t.Fatal(err)
	}

	// A viewer cannot create a team todo.
	viewerTodo := &todoschema.Todo{ID: "tdv", ProjectID: "p1", OwnerIdentity: "viewer@x", Title: "nope"}
	if err := st.CreateTodo(ctx, viewerTodo); !errors.Is(err, ErrForbidden) {
		t.Fatalf("viewer create: want ErrForbidden, got %v", err)
	}
	// A non-member cannot create one either.
	strangerTodo := &todoschema.Todo{ID: "tds", ProjectID: "p1", OwnerIdentity: "stranger@x", Title: "nope"}
	if err := st.CreateTodo(ctx, strangerTodo); !errors.Is(err, ErrForbidden) {
		t.Fatalf("stranger create: want ErrForbidden, got %v", err)
	}

	td := &todoschema.Todo{ID: "td2", ProjectID: "p1", OwnerIdentity: "owner@x", Title: "ship the release"}
	mustCreateTodo(t, st, td)

	// View: owner, member, and viewer can all see it; a non-member cannot.
	for _, who := range []string{"owner@x", "member@x", "viewer@x"} {
		if _, err := st.GetTodo(ctx, "td2", who); err != nil {
			t.Errorf("%s should be able to view td2: %v", who, err)
		}
	}
	if _, err := st.GetTodo(ctx, "td2", "stranger@x"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("non-member view: want ErrForbidden, got %v", err)
	}

	listed, err := st.ListTodos(ctx, "viewer@x", TodoListFilter{Scope: "project", ProjectID: "p1"})
	if err != nil || len(listed) != 1 {
		t.Fatalf("viewer ListTodos project=p1: %+v err=%v", listed, err)
	}
	if _, err := st.ListTodos(ctx, "stranger@x", TodoListFilter{Scope: "project", ProjectID: "p1"}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("non-member ListTodos project=p1: want ErrForbidden, got %v", err)
	}
	// scope=project with no project id unions every project the caller belongs to.
	union, err := st.ListTodos(ctx, "member@x", TodoListFilter{Scope: "project"})
	if err != nil || len(union) != 1 || union[0].ID != "td2" {
		t.Fatalf("member ListTodos project union: %+v err=%v", union, err)
	}

	// Edit: owner and member can; viewer (read-only) cannot.
	newTitle := "ship the release today"
	if _, err := st.UpdateTodoFields(ctx, "td2", "member@x", TodoPatch{Title: &newTitle}); err != nil {
		t.Fatalf("member edit: %v", err)
	}
	if _, err := st.UpdateTodoFields(ctx, "td2", "viewer@x", TodoPatch{Title: &newTitle}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("viewer edit: want ErrForbidden, got %v", err)
	}
	if _, err := st.SetTodoStatus(ctx, "td2", "viewer@x", todoschema.StatusInProgress); !errors.Is(err, ErrForbidden) {
		t.Fatalf("viewer status change: want ErrForbidden, got %v", err)
	}

	// Comment: owner and member can; viewer (read-only) cannot.
	if _, err := st.InsertTodoComment(ctx, "td2", "member@x", "on it"); err != nil {
		t.Fatalf("member comment: %v", err)
	}
	if _, err := st.InsertTodoComment(ctx, "td2", "viewer@x", "nope"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("viewer comment: want ErrForbidden, got %v", err)
	}

	// Delete: member cannot (edit != delete); owner can.
	if err := st.DeleteTodo(ctx, "td2", "member@x"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member delete: want ErrForbidden, got %v", err)
	}
	if err := st.DeleteTodo(ctx, "td2", "owner@x"); err != nil {
		t.Fatalf("owner delete: %v", err)
	}
}

// --- admin scope=all sees everything regardless of ownership/membership ---

func TestTodoAdminScopeAll(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateProject(ctx, "p1", "Kunlun", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	mustCreateTodo(t, st, &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "personal"})
	mustCreateTodo(t, st, &todoschema.Todo{ID: "td2", ProjectID: "p1", OwnerIdentity: "owner@x", Title: "team"})

	if err := st.CreateUser(ctx, User{Identity: "admin@x", IsAdmin: true}, now); err != nil {
		t.Fatal(err)
	}

	if _, err := st.ListTodos(ctx, "alice@x", TodoListFilter{Scope: "all"}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("non-admin scope=all: want ErrForbidden, got %v", err)
	}

	all, err := st.ListTodos(ctx, "admin@x", TodoListFilter{Scope: "all"})
	if err != nil || len(all) != 2 {
		t.Fatalf("admin scope=all: %+v err=%v", all, err)
	}
}

// --- PATCH due_at null-vs-absent semantics ---

func TestTodoPatchDueAtNullVsAbsent(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	due := time.Now().Add(24 * time.Hour).UTC().Truncate(time.Millisecond)
	td := &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "t", DueAt: &due}
	mustCreateTodo(t, st, td)

	// Field absent (zero-value TodoPatch, DueAt.Set=false) leaves due_at untouched.
	otherTitle := "t2"
	got, err := st.UpdateTodoFields(ctx, "td1", "alice@x", TodoPatch{Title: &otherTitle})
	if err != nil {
		t.Fatal(err)
	}
	if got.DueAt == nil || !got.DueAt.Equal(due) {
		t.Fatalf("absent due_at should be untouched, got %+v", got.DueAt)
	}

	// Field sent as null clears it.
	got, err = st.UpdateTodoFields(ctx, "td1", "alice@x", TodoPatch{DueAt: OptionalTime{Set: true, Value: nil}})
	if err != nil {
		t.Fatal(err)
	}
	if got.DueAt != nil {
		t.Fatalf("null due_at should clear it, got %+v", got.DueAt)
	}

	// Field sent with a value sets it.
	newDue := time.Now().Add(48 * time.Hour).UTC().Truncate(time.Millisecond)
	got, err = st.UpdateTodoFields(ctx, "td1", "alice@x", TodoPatch{DueAt: OptionalTime{Set: true, Value: &newDue}})
	if err != nil {
		t.Fatal(err)
	}
	if got.DueAt == nil || !got.DueAt.Equal(newDue) {
		t.Fatalf("due_at not set, got %+v", got.DueAt)
	}
}

// --- status/recurrence sweep ---

func TestTodoRecurrenceSweep(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	td := &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "water plants", Recurrence: todoschema.RecurrenceDaily}
	mustCreateTodo(t, st, td)

	got, err := st.SetTodoStatus(ctx, "td1", "alice@x", todoschema.StatusDone)
	if err != nil {
		t.Fatal(err)
	}
	if got.CompletedAt == nil {
		t.Fatal("completed_at not set")
	}
	if got.NextOccurrenceAt == nil || !got.NextOccurrenceAt.Equal(got.CompletedAt.AddDate(0, 0, 1)) {
		t.Fatalf("next_occurrence_at not advanced by one day: %+v", got)
	}

	// Not due yet.
	due, err := st.DueRecurringTodos(ctx, got.CompletedAt.Add(1*time.Hour))
	if err != nil || len(due) != 0 {
		t.Fatalf("should not be due yet: %+v err=%v", due, err)
	}

	// Due now.
	due, err = st.DueRecurringTodos(ctx, got.NextOccurrenceAt.Add(time.Minute))
	if err != nil || len(due) != 1 || due[0].ID != "td1" {
		t.Fatalf("should be due: %+v err=%v", due, err)
	}

	reset, err := st.ResetRecurringTodo(ctx, "td1", got.NextOccurrenceAt.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if reset.Status != todoschema.StatusPending || reset.CompletedAt != nil || reset.NextOccurrenceAt != nil {
		t.Fatalf("recurring todo not reset cleanly: %+v", reset)
	}

	// A non-recurring, in-progress todo is left alone by the sweep query
	// entirely (it's never status=done in the first place).
	mustCreateTodo(t, st, &todoschema.Todo{ID: "td2", OwnerIdentity: "alice@x", Title: "one-shot"})
	if _, err := st.SetTodoStatus(ctx, "td2", "alice@x", todoschema.StatusInProgress); err != nil {
		t.Fatal(err)
	}
	due, err = st.DueRecurringTodos(ctx, time.Now().Add(365*24*time.Hour))
	if err != nil || len(due) != 0 {
		t.Fatalf("in-progress non-recurring todo should never be swept: %+v err=%v", due, err)
	}
}

// --- assign auto-status nudge ---

func TestTodoAssignAutoStatus(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	td := &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "delegate this"}
	mustCreateTodo(t, st, td)

	got, err := st.AssignTodo(ctx, "td1", "alice@x", "bob@x", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != todoschema.StatusAssigned || got.AssigneeIdentity != "bob@x" {
		t.Fatalf("assign should flip pending->assigned: %+v", got)
	}

	got, err = st.AssignTodo(ctx, "td1", "alice@x", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != todoschema.StatusPending || got.AssigneeIdentity != "" {
		t.Fatalf("clearing assignment should revert assigned->pending: %+v", got)
	}

	// Once work is underway, (un)assigning must not clobber status.
	if _, err := st.SetTodoStatus(ctx, "td1", "alice@x", todoschema.StatusInProgress); err != nil {
		t.Fatal(err)
	}
	got, err = st.AssignTodo(ctx, "td1", "alice@x", "carol@x", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != todoschema.StatusInProgress {
		t.Fatalf("assigning an in-progress todo must not change status: %+v", got)
	}
}

// --- comments/attachments round trip + counts surfaced on the todo ---

func TestTodoCommentsAndAttachments(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	td := &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "with attachments"}
	mustCreateTodo(t, st, td)

	if _, err := st.InsertTodoComment(ctx, "td1", "alice@x", "first"); err != nil {
		t.Fatal(err)
	}
	if _, err := st.InsertTodoComment(ctx, "td1", "alice@x", "second"); err != nil {
		t.Fatal(err)
	}
	comments, err := st.ListTodoComments(ctx, "td1", "alice@x")
	if err != nil || len(comments) != 2 || comments[0].Body != "first" || comments[1].Body != "second" {
		t.Fatalf("got %+v err=%v", comments, err)
	}

	if err := st.PutTodoAttachment(ctx, "td1", "alice@x", "photo.png", "deadbeef", []byte("bytes")); err != nil {
		t.Fatal(err)
	}
	content, sum, size, err := st.GetTodoAttachment(ctx, "td1", "alice@x", "photo.png")
	if err != nil || string(content) != "bytes" || sum != "deadbeef" || size != 5 {
		t.Fatalf("got content=%q sum=%q size=%d err=%v", content, sum, size, err)
	}
	if _, _, _, err := st.GetTodoAttachment(ctx, "td1", "bob@x", "photo.png"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("stranger attachment read: want ErrForbidden, got %v", err)
	}

	atts, err := st.ListTodoAttachments(ctx, "td1", "alice@x")
	if err != nil || len(atts) != 1 || atts[0].Name != "photo.png" || atts[0].SHA256 != "deadbeef" {
		t.Fatalf("got %+v err=%v", atts, err)
	}

	// Counts are reflected on both GetTodo and ListTodos, and ListTodos
	// leaves Attachments nil (only GET-by-id populates it).
	single, err := st.GetTodo(ctx, "td1", "alice@x")
	if err != nil {
		t.Fatal(err)
	}
	if single.CommentCount != 2 || single.AttachmentCount != 1 {
		t.Fatalf("counts not reflected on GetTodo: %+v", single)
	}
	if len(single.Attachments) != 1 || single.Attachments[0].Name != "photo.png" {
		t.Fatalf("GetTodo should populate Attachments: %+v", single.Attachments)
	}

	listed, err := st.ListTodos(ctx, "alice@x", TodoListFilter{Scope: "personal"})
	if err != nil || len(listed) != 1 {
		t.Fatalf("got %+v err=%v", listed, err)
	}
	if listed[0].CommentCount != 2 || listed[0].AttachmentCount != 1 {
		t.Fatalf("counts not reflected on ListTodos: %+v", listed[0])
	}
	if listed[0].Attachments != nil {
		t.Fatalf("ListTodos should not populate Attachments: %+v", listed[0].Attachments)
	}
}

// TestTodoMutatorsReturnAttachments locks in a regression: UpdateTodoFields,
// SetTodoStatus and AssignTodo all used to return getTodoRow's result
// directly, which never populates Attachments (only GetTodo joined it in) —
// so every PATCH/status/assign response silently reported an empty
// attachment list even though attachment_count was correct. Track 1's
// inline-image body view hit this: saving a title/body edit after pasting an
// image wiped the client's loaded attachment metadata and the image showed
// as "failed to load". Fixed via the shared withAttachments helper.
func TestTodoMutatorsReturnAttachments(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	mustCreateTodo(t, st, &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "t"})
	if err := st.PutTodoAttachment(ctx, "td1", "alice@x", "photo.png", "deadbeef", []byte("bytes")); err != nil {
		t.Fatal(err)
	}

	title := "renamed"
	patched, err := st.UpdateTodoFields(ctx, "td1", "alice@x", TodoPatch{Title: &title})
	if err != nil {
		t.Fatal(err)
	}
	if len(patched.Attachments) != 1 || patched.Attachments[0].Name != "photo.png" {
		t.Fatalf("UpdateTodoFields should return Attachments: %+v", patched.Attachments)
	}

	statused, err := st.SetTodoStatus(ctx, "td1", "alice@x", todoschema.StatusInProgress)
	if err != nil {
		t.Fatal(err)
	}
	if len(statused.Attachments) != 1 || statused.Attachments[0].Name != "photo.png" {
		t.Fatalf("SetTodoStatus should return Attachments: %+v", statused.Attachments)
	}

	assigned, err := st.AssignTodo(ctx, "td1", "alice@x", "bob@x", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(assigned.Attachments) != 1 || assigned.Attachments[0].Name != "photo.png" {
		t.Fatalf("AssignTodo should return Attachments: %+v", assigned.Attachments)
	}
}

// --- project deletion cascades its team todos, personal todos untouched ---

func TestTodoProjectDeleteCascade(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateProject(ctx, "p1", "Kunlun", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	mustCreateTodo(t, st, &todoschema.Todo{ID: "personal", OwnerIdentity: "owner@x", Title: "personal"})
	mustCreateTodo(t, st, &todoschema.Todo{ID: "team", ProjectID: "p1", OwnerIdentity: "owner@x", Title: "team"})

	if err := st.DeleteProject(ctx, "p1"); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetTodo(ctx, "team", "owner@x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("team todo should cascade-delete with its project: %v", err)
	}
	if _, err := st.GetTodo(ctx, "personal", "owner@x"); err != nil {
		t.Fatalf("personal todo should survive an unrelated project delete: %v", err)
	}
}
