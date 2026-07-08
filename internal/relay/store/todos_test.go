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
	if got.Title != "buy milk" || got.Status != todoschema.StatusTodo || got.Priority != todoschema.PriorityNormal {
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
	p, err := st.GetProject(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, p.OrgID, "org-admin@x", OrgRoleAdmin); err != nil {
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
	adminTodo := &todoschema.Todo{ID: "tda", ProjectID: "p1", OwnerIdentity: "org-admin@x", Title: "admin task"}
	mustCreateTodo(t, st, adminTodo)

	// View: owner, member, and viewer can all see it; a non-member cannot.
	for _, who := range []string{"owner@x", "member@x", "viewer@x", "org-admin@x"} {
		if _, err := st.GetTodo(ctx, "td2", who); err != nil {
			t.Errorf("%s should be able to view td2: %v", who, err)
		}
	}
	if _, err := st.GetTodo(ctx, "td2", "stranger@x"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("non-member view: want ErrForbidden, got %v", err)
	}

	listed, err := st.ListTodos(ctx, "viewer@x", TodoListFilter{Scope: "project", ProjectID: "p1"})
	if err != nil || len(listed) != 2 {
		t.Fatalf("viewer ListTodos project=p1: %+v err=%v", listed, err)
	}
	adminListed, err := st.ListTodos(ctx, "org-admin@x", TodoListFilter{Scope: "project", ProjectID: "p1"})
	if err != nil || len(adminListed) != 2 {
		t.Fatalf("org admin ListTodos project=p1: %+v err=%v", adminListed, err)
	}
	if _, err := st.ListTodos(ctx, "stranger@x", TodoListFilter{Scope: "project", ProjectID: "p1"}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("non-member ListTodos project=p1: want ErrForbidden, got %v", err)
	}
	// scope=project with no project id unions every project the caller belongs to.
	union, err := st.ListTodos(ctx, "member@x", TodoListFilter{Scope: "project"})
	if err != nil || len(union) != 2 {
		t.Fatalf("member ListTodos project union: %+v err=%v", union, err)
	}
	adminUnion, err := st.ListTodos(ctx, "org-admin@x", TodoListFilter{Scope: "project"})
	if err != nil || len(adminUnion) != 2 {
		t.Fatalf("org admin ListTodos project union: %+v err=%v", adminUnion, err)
	}

	// Edit: owner and member can; viewer (read-only) cannot.
	newTitle := "ship the release today"
	if _, err := st.UpdateTodoFields(ctx, "td2", "member@x", TodoPatch{Title: &newTitle}); err != nil {
		t.Fatalf("member edit: %v", err)
	}
	if _, err := st.UpdateTodoFields(ctx, "td2", "org-admin@x", TodoPatch{Title: &newTitle}); err != nil {
		t.Fatalf("org admin edit: %v", err)
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
	if _, err := st.InsertTodoComment(ctx, "td2", "org-admin@x", "on it"); err != nil {
		t.Fatalf("org admin comment: %v", err)
	}
	if _, err := st.InsertTodoComment(ctx, "td2", "viewer@x", "nope"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("viewer comment: want ErrForbidden, got %v", err)
	}

	// Delete: member cannot (edit != delete); owner can.
	if err := st.DeleteTodo(ctx, "td2", "member@x"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member delete: want ErrForbidden, got %v", err)
	}
	if err := st.DeleteTodo(ctx, "tda", "org-admin@x"); err != nil {
		t.Fatalf("org admin delete: %v", err)
	}
	if err := st.DeleteTodo(ctx, "td2", "owner@x"); err != nil {
		t.Fatalf("owner delete: %v", err)
	}
}

func TestTodoAssignRequiresScopedAssignee(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateProject(ctx, "p1", "Kunlun", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "p1", "member@x", RoleMember); err != nil {
		t.Fatal(err)
	}
	p, err := st.GetProject(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, p.OrgID, "org-admin@x", OrgRoleAdmin); err != nil {
		t.Fatal(err)
	}
	mustCreateTodo(t, st, &todoschema.Todo{ID: "team", ProjectID: "p1", OwnerIdentity: "owner@x", Title: "team task"})
	mustCreateTodo(t, st, &todoschema.Todo{ID: "personal", OwnerIdentity: "owner@x", Title: "private task"})

	if _, err := st.AssignTodo(ctx, "team", "owner@x", "member@x", "", "", "", "", ""); err != nil {
		t.Fatalf("assign team todo to project member: %v", err)
	}
	if _, err := st.AssignTodo(ctx, "team", "owner@x", "stranger@x", "", "", "", "", ""); !errors.Is(err, ErrForbidden) {
		t.Fatalf("assign team todo to non-member: want ErrForbidden, got %v", err)
	}
	if err := st.CreateUser(ctx, User{Identity: "disabled@x", Disabled: true}, now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "p1", "disabled@x", RoleMember); err != nil {
		t.Fatal(err)
	}
	if _, err := st.AssignTodo(ctx, "team", "owner@x", "disabled@x", "", "", "", "", ""); !errors.Is(err, ErrForbidden) {
		t.Fatalf("assign team todo to disabled member: want ErrForbidden, got %v", err)
	}
	if _, err := st.AssignTodo(ctx, "team", "owner@x", "org-admin@x", "", "", "", "", ""); err != nil {
		t.Fatalf("assign team todo to org admin: %v", err)
	}
	assignedAdmin, err := st.ListTodos(ctx, "org-admin@x", TodoListFilter{Scope: "assigned"})
	if err != nil {
		t.Fatal(err)
	}
	if len(assignedAdmin) != 1 || assignedAdmin[0].ID != "team" {
		t.Fatalf("assigned scope should show org admin's team todo: %+v", assignedAdmin)
	}
	if _, err := st.AssignTodo(ctx, "team", "owner@x", "member@x", "", "", "", "", ""); err != nil {
		t.Fatalf("reassign team todo to project member: %v", err)
	}
	if _, err := st.AssignTodo(ctx, "personal", "owner@x", "owner@x", "", "", "", "", ""); err != nil {
		t.Fatalf("assign personal todo to owner: %v", err)
	}
	if err := st.CreateUser(ctx, User{Identity: "disabled-owner@x", Disabled: true}, now); err != nil {
		t.Fatal(err)
	}
	mustCreateTodo(t, st, &todoschema.Todo{ID: "disabled-personal", OwnerIdentity: "disabled-owner@x", Title: "disabled private task"})
	if _, err := st.AssignTodo(ctx, "disabled-personal", "disabled-owner@x", "disabled-owner@x", "", "", "", "", ""); !errors.Is(err, ErrForbidden) {
		t.Fatalf("assign personal todo to disabled owner: want ErrForbidden, got %v", err)
	}
	if _, err := st.AssignTodo(ctx, "personal", "owner@x", "member@x", "", "", "", "", ""); !errors.Is(err, ErrForbidden) {
		t.Fatalf("assign personal todo to another identity: want ErrForbidden, got %v", err)
	}
	assigned, err := st.ListTodos(ctx, "member@x", TodoListFilter{Scope: "assigned"})
	if err != nil {
		t.Fatal(err)
	}
	if len(assigned) != 1 || assigned[0].ID != "team" {
		t.Fatalf("assigned scope should show member's team todo: %+v", assigned)
	}

	// Defense in depth for old rows written before assignee validation:
	// assigned scope must still enforce the todo's visibility boundary.
	if _, err := st.db.ExecContext(ctx, `UPDATE todos SET assignee_identity = ? WHERE id = ?`, "member@x", "personal"); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx, `UPDATE todos SET assignee_identity = ? WHERE id = ?`, "stranger@x", "team"); err != nil {
		t.Fatal(err)
	}
	assigned, err = st.ListTodos(ctx, "member@x", TodoListFilter{Scope: "assigned"})
	if err != nil {
		t.Fatal(err)
	}
	if len(assigned) != 0 {
		t.Fatalf("assigned scope leaked inaccessible todos to member: %+v", assigned)
	}
	assigned, err = st.ListTodos(ctx, "stranger@x", TodoListFilter{Scope: "assigned"})
	if err != nil {
		t.Fatal(err)
	}
	if len(assigned) != 0 {
		t.Fatalf("assigned scope leaked team todo to stranger: %+v", assigned)
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
	if reset.Status != todoschema.StatusTodo || reset.CompletedAt != nil || reset.NextOccurrenceAt != nil {
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

// --- assign/status are independent dimensions (no auto-status nudge) ---

// TestTodoAssignDoesNotChangeStatus locks in the taxonomy-rework decision:
// assignee and status used to be coupled (assigning a pending todo flipped it
// to "assigned"; clearing reverted it) back when Status had an "assigned"
// value of its own. That value is gone from the new 8-value taxonomy, and
// AssignTodo no longer touches status at all under any circumstance —
// assignee ("who") and status ("what stage") are independent dimensions now,
// matching Linear's own model.
func TestTodoAssignDoesNotChangeStatus(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	td := &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "delegate this"}
	mustCreateTodo(t, st, td)

	got, err := st.AssignTodo(ctx, "td1", "alice@x", "alice@x", "", "", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != todoschema.StatusTodo || got.AssigneeIdentity != "alice@x" {
		t.Fatalf("assigning must leave status untouched: %+v", got)
	}

	got, err = st.AssignTodo(ctx, "td1", "alice@x", "", "", "", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != todoschema.StatusTodo || got.AssigneeIdentity != "" {
		t.Fatalf("clearing assignment must leave status untouched: %+v", got)
	}

	// Once work is underway, (un)assigning still must not clobber status.
	if _, err := st.SetTodoStatus(ctx, "td1", "alice@x", todoschema.StatusInProgress); err != nil {
		t.Fatal(err)
	}
	got, err = st.AssignTodo(ctx, "td1", "alice@x", "alice@x", "", "", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != todoschema.StatusInProgress {
		t.Fatalf("assigning an in-progress todo must not change status: %+v", got)
	}
}

// --- Phase 0: Linear-import source_ref + session-resume assignee fields ---

func TestFindTodoBySourceRef(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	// Not found: no todo has this source_ref yet, and that's not an error —
	// the caller (an import command) should go on to create one.
	_, found, err := st.FindTodoBySourceRef(ctx, "alice@x", "linear:ENG-456", "")
	if err != nil {
		t.Fatalf("FindTodoBySourceRef on empty store: %v", err)
	}
	if found {
		t.Fatal("FindTodoBySourceRef should report not-found before any import")
	}

	td := &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "ENG-456: fix the thing", SourceRef: "linear:ENG-456", SourceURL: "https://linear.app/x/issue/ENG-456"}
	mustCreateTodo(t, st, td)

	got, found, err := st.FindTodoBySourceRef(ctx, "alice@x", "linear:ENG-456", "")
	if err != nil || !found {
		t.Fatalf("FindTodoBySourceRef should find imported todo: found=%v err=%v", found, err)
	}
	if got.ID != "td1" || got.SourceRef != "linear:ENG-456" || got.SourceURL != "https://linear.app/x/issue/ENG-456" {
		t.Fatalf("got %+v", got)
	}

	// A stranger with no view access gets found=false, so one user's personal
	// Linear import does not block another user importing the same issue.
	_, found, err = st.FindTodoBySourceRef(ctx, "bob@x", "linear:ENG-456", "")
	if err != nil {
		t.Fatalf("stranger FindTodoBySourceRef: %v", err)
	}
	if found {
		t.Fatal("stranger should not see alice's personal source_ref")
	}

	// A different source_ref that nothing matches is still "not found".
	_, found, err = st.FindTodoBySourceRef(ctx, "alice@x", "linear:ENG-999", "")
	if err != nil {
		t.Fatal(err)
	}
	if found {
		t.Fatal("unrelated source_ref should not be found")
	}
}

func TestFindTodoBySourceRefScopesToDestination(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()
	if err := st.CreateProject(ctx, "p1", "Kunlun", "alice@x", now); err != nil {
		t.Fatal(err)
	}

	mustCreateTodo(t, st, &todoschema.Todo{ID: "personal", OwnerIdentity: "alice@x", Title: "personal", SourceRef: "linear:ENG-456"})
	mustCreateTodo(t, st, &todoschema.Todo{ID: "team", ProjectID: "p1", OwnerIdentity: "alice@x", Title: "team", SourceRef: "linear:ENG-456"})

	got, found, err := st.FindTodoBySourceRef(ctx, "alice@x", "linear:ENG-456", "")
	if err != nil || !found || got.ID != "personal" {
		t.Fatalf("personal by-source = %+v found=%v err=%v", got, found, err)
	}
	got, found, err = st.FindTodoBySourceRef(ctx, "alice@x", "linear:ENG-456", "p1")
	if err != nil || !found || got.ID != "team" {
		t.Fatalf("project by-source = %+v found=%v err=%v", got, found, err)
	}
}

func TestAssignTodoResumeFields(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	mustCreateTodo(t, st, &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "delegate this"})

	got, err := st.AssignTodo(ctx, "td1", "alice@x", "alice@x", "sess-1", "alice laptop",
		"11111111-1111-1111-1111-111111111111", "/Users/alice/repo", "claude")
	if err != nil {
		t.Fatal(err)
	}
	if got.AssigneeAgentSessionID != "11111111-1111-1111-1111-111111111111" ||
		got.AssigneeWorkdir != "/Users/alice/repo" || got.AssigneeAgentKind != "claude" {
		t.Fatalf("AssignTodo did not return resume fields: %+v", got)
	}
	if got.Status != todoschema.StatusTodo {
		t.Fatalf("assigning via resume fields alone must not change status: %+v", got)
	}

	// Fetched independently, GetTodo must see the same values (i.e. they
	// really landed in the todos table, not just the in-memory return value).
	reloaded, err := st.GetTodo(ctx, "td1", "alice@x")
	if err != nil {
		t.Fatal(err)
	}
	if reloaded.AssigneeAgentSessionID != "11111111-1111-1111-1111-111111111111" ||
		reloaded.AssigneeWorkdir != "/Users/alice/repo" || reloaded.AssigneeAgentKind != "claude" {
		t.Fatalf("GetTodo did not persist resume fields: %+v", reloaded)
	}
}

func TestCreateTodoWithSourceRef(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	td := &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "ENG-456: fix the thing", SourceRef: "linear:ENG-456", SourceURL: "https://linear.app/x/issue/ENG-456"}
	mustCreateTodo(t, st, td)

	got, err := st.GetTodo(ctx, "td1", "alice@x")
	if err != nil {
		t.Fatal(err)
	}
	if got.SourceRef != "linear:ENG-456" || got.SourceURL != "https://linear.app/x/issue/ENG-456" {
		t.Fatalf("CreateTodo did not persist source fields: %+v", got)
	}

	found, ok, err := st.FindTodoBySourceRef(ctx, "alice@x", "linear:ENG-456", "")
	if err != nil || !ok || found.ID != "td1" {
		t.Fatalf("newly created todo should be findable by source_ref: found=%+v ok=%v err=%v", found, ok, err)
	}
}

// --- optional workspace/repo binding ---

func TestCreateTodoWithWorkspaceRepo(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	td := &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "bound", WorkspaceName: "kunlun", RepoName: "cc-collaboration"}
	mustCreateTodo(t, st, td)

	got, err := st.GetTodo(ctx, "td1", "alice@x")
	if err != nil {
		t.Fatal(err)
	}
	if got.WorkspaceName != "kunlun" || got.RepoName != "cc-collaboration" {
		t.Fatalf("CreateTodo did not persist workspace/repo binding: %+v", got)
	}

	// A todo created without a binding round-trips as empty, not some other
	// zero value.
	mustCreateTodo(t, st, &todoschema.Todo{ID: "td2", OwnerIdentity: "alice@x", Title: "unbound"})
	got2, err := st.GetTodo(ctx, "td2", "alice@x")
	if err != nil {
		t.Fatal(err)
	}
	if got2.WorkspaceName != "" || got2.RepoName != "" {
		t.Fatalf("unbound todo should have empty workspace/repo: %+v", got2)
	}
}

func TestUpdateTodoFieldsWorkspaceRepo(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	mustCreateTodo(t, st, &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "rebindable"})

	ws, repo := "kunlun", "cc-collaboration"
	got, err := st.UpdateTodoFields(ctx, "td1", "alice@x", TodoPatch{WorkspaceName: &ws, RepoName: &repo})
	if err != nil {
		t.Fatal(err)
	}
	if got.WorkspaceName != "kunlun" || got.RepoName != "cc-collaboration" {
		t.Fatalf("PATCH did not set workspace/repo binding: %+v", got)
	}

	// A patch that doesn't mention workspace_name/repo_name at all (nil
	// pointers) leaves the existing binding untouched.
	otherTitle := "rebindable, retitled"
	got, err = st.UpdateTodoFields(ctx, "td1", "alice@x", TodoPatch{Title: &otherTitle})
	if err != nil {
		t.Fatal(err)
	}
	if got.WorkspaceName != "kunlun" || got.RepoName != "cc-collaboration" {
		t.Fatalf("field-absent patch should leave binding untouched: %+v", got)
	}

	// Sending empty strings for both explicitly clears the binding.
	empty := ""
	got, err = st.UpdateTodoFields(ctx, "td1", "alice@x", TodoPatch{WorkspaceName: &empty, RepoName: &empty})
	if err != nil {
		t.Fatal(err)
	}
	if got.WorkspaceName != "" || got.RepoName != "" {
		t.Fatalf("empty-string patch should clear binding: %+v", got)
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

	assigned, err := st.AssignTodo(ctx, "td1", "alice@x", "alice@x", "", "", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(assigned.Attachments) != 1 || assigned.Attachments[0].Name != "photo.png" {
		t.Fatalf("AssignTodo should return Attachments: %+v", assigned.Attachments)
	}
}

// --- todo groups: free-form string field, no separate table ---

func TestListTodoGroupsPersonalScope(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	mustCreateTodo(t, st, &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "a", GroupName: "我的日常"})
	mustCreateTodo(t, st, &todoschema.Todo{ID: "td2", OwnerIdentity: "alice@x", Title: "b", GroupName: "我的日常"})
	mustCreateTodo(t, st, &todoschema.Todo{ID: "td3", OwnerIdentity: "alice@x", Title: "c", GroupName: "xxx项目"})
	mustCreateTodo(t, st, &todoschema.Todo{ID: "td4", OwnerIdentity: "alice@x", Title: "ungrouped"})
	mustCreateTodo(t, st, &todoschema.Todo{ID: "td5", OwnerIdentity: "bob@x", Title: "not alice's", GroupName: "我的日常"})

	groups, err := st.ListTodoGroups(ctx, "alice@x", "")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, g := range groups {
		got[g] = true
	}
	if !got["我的日常"] || !got["xxx项目"] || len(got) != 2 {
		t.Fatalf("ListTodoGroups(alice) = %v, want exactly [我的日常, xxx项目]", groups)
	}

	// bob only sees his own group, not alice's.
	bobGroups, err := st.ListTodoGroups(ctx, "bob@x", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(bobGroups) != 1 || bobGroups[0] != "我的日常" {
		t.Fatalf("ListTodoGroups(bob) = %v", bobGroups)
	}
}

func TestListTodoGroupsProjectScope(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateProject(ctx, "p1", "Kunlun", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "p1", "viewer@x", RoleViewer); err != nil {
		t.Fatal(err)
	}
	p, err := st.GetProject(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, p.OrgID, "org-admin@x", OrgRoleAdmin); err != nil {
		t.Fatal(err)
	}
	mustCreateTodo(t, st, &todoschema.Todo{ID: "td1", ProjectID: "p1", OwnerIdentity: "owner@x", Title: "a", GroupName: "sprint-1"})

	// A project viewer can list groups — listing is a read op (view tier),
	// same as ListTodos' scope="project" branch.
	groups, err := st.ListTodoGroups(ctx, "viewer@x", "p1")
	if err != nil || len(groups) != 1 || groups[0] != "sprint-1" {
		t.Fatalf("viewer ListTodoGroups: %+v err=%v", groups, err)
	}
	groups, err = st.ListTodoGroups(ctx, "org-admin@x", "p1")
	if err != nil || len(groups) != 1 || groups[0] != "sprint-1" {
		t.Fatalf("org admin ListTodoGroups: %+v err=%v", groups, err)
	}

	if _, err := st.ListTodoGroups(ctx, "stranger@x", "p1"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("non-member ListTodoGroups: want ErrForbidden, got %v", err)
	}
}

func TestRenameTodoGroup(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	mustCreateTodo(t, st, &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "a", GroupName: "old-name"})
	mustCreateTodo(t, st, &todoschema.Todo{ID: "td2", OwnerIdentity: "alice@x", Title: "b", GroupName: "old-name"})
	mustCreateTodo(t, st, &todoschema.Todo{ID: "td3", OwnerIdentity: "alice@x", Title: "c", GroupName: "other"})

	if err := st.RenameTodoGroup(ctx, "alice@x", "", "old-name", "new-name"); err != nil {
		t.Fatal(err)
	}
	td1, _ := st.GetTodo(ctx, "td1", "alice@x")
	td2, _ := st.GetTodo(ctx, "td2", "alice@x")
	td3, _ := st.GetTodo(ctx, "td3", "alice@x")
	if td1.GroupName != "new-name" || td2.GroupName != "new-name" {
		t.Fatalf("rename did not apply to both todos: td1=%q td2=%q", td1.GroupName, td2.GroupName)
	}
	if td3.GroupName != "other" {
		t.Fatalf("rename leaked into an unrelated group: %q", td3.GroupName)
	}
}

func TestClearTodoGroup(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	mustCreateTodo(t, st, &todoschema.Todo{ID: "td1", OwnerIdentity: "alice@x", Title: "a", GroupName: "temp"})

	if err := st.ClearTodoGroup(ctx, "alice@x", "", "temp"); err != nil {
		t.Fatal(err)
	}
	td1, err := st.GetTodo(ctx, "td1", "alice@x")
	if err != nil {
		t.Fatal(err)
	}
	if td1.GroupName != "" {
		t.Fatalf("group not cleared: %q", td1.GroupName)
	}
	if td1.Title != "a" {
		t.Fatalf("ClearTodoGroup should not delete the todo itself")
	}
}

func TestRenameClearTodoGroupRequiresEditorTierInProjectScope(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := st.CreateProject(ctx, "p1", "Kunlun", "owner@x", now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddMember(ctx, "p1", "viewer@x", RoleViewer); err != nil {
		t.Fatal(err)
	}
	p, err := st.GetProject(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AddOrganizationMember(ctx, p.OrgID, "org-admin@x", OrgRoleAdmin); err != nil {
		t.Fatal(err)
	}
	mustCreateTodo(t, st, &todoschema.Todo{ID: "td1", ProjectID: "p1", OwnerIdentity: "owner@x", Title: "a", GroupName: "sprint-1"})

	if err := st.RenameTodoGroup(ctx, "viewer@x", "p1", "sprint-1", "sprint-2"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("viewer rename: want ErrForbidden, got %v", err)
	}
	if err := st.ClearTodoGroup(ctx, "viewer@x", "p1", "sprint-1"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("viewer clear: want ErrForbidden, got %v", err)
	}
	if err := st.RenameTodoGroup(ctx, "org-admin@x", "p1", "sprint-1", "sprint-2"); err != nil {
		t.Fatalf("org admin rename: %v", err)
	}
	if err := st.ClearTodoGroup(ctx, "org-admin@x", "p1", "sprint-2"); err != nil {
		t.Fatalf("org admin clear: %v", err)
	}
	mustCreateTodo(t, st, &todoschema.Todo{ID: "td2", ProjectID: "p1", OwnerIdentity: "owner@x", Title: "b", GroupName: "sprint-1"})
	if err := st.RenameTodoGroup(ctx, "owner@x", "p1", "sprint-1", "sprint-2"); err != nil {
		t.Fatalf("owner rename: %v", err)
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
