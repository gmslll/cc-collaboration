package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/cc-collaboration/pkg/todoschema"
)

// todoColumns is the shared SELECT list for reading a full Todo row,
// including the comment_count/attachment_count inline subqueries the API
// contract calls for (avoids an N+1 join from list views). Every query
// using it must alias the todos table "t".
const todoColumns = `t.id, t.project_id, t.owner_identity, t.title, t.body_md, t.status, t.priority,
       t.assignee_identity, t.assignee_session_id, t.assignee_session_label,
       t.assignee_agent_session_id, t.assignee_workdir, t.assignee_agent_kind,
       t.workspace_name, t.repo_name, t.recurrence, t.group_name,
       t.due_at, t.next_occurrence_at, t.created_at, t.updated_at, t.completed_at,
       t.source_ref, t.source_url, t.source_provider, t.source_team_key, t.source_project_id,
       (SELECT COUNT(*) FROM todo_comments c WHERE c.todo_id = t.id) AS comment_count,
       (SELECT COUNT(*) FROM todo_attachments a WHERE a.todo_id = t.id) AS attachment_count`

func scanTodoRow(row scanner) (todoschema.Todo, error) {
	var (
		t                          todoschema.Todo
		projectID                  sql.NullString
		dueMS, nextMS, completedMS sql.NullInt64
		createdMS, updatedMS       int64
	)
	if err := row.Scan(
		&t.ID, &projectID, &t.OwnerIdentity, &t.Title, &t.BodyMD, &t.Status, &t.Priority,
		&t.AssigneeIdentity, &t.AssigneeSessionID, &t.AssigneeSessionLabel,
		&t.AssigneeAgentSessionID, &t.AssigneeWorkdir, &t.AssigneeAgentKind,
		&t.WorkspaceName, &t.RepoName, &t.Recurrence, &t.GroupName,
		&dueMS, &nextMS, &createdMS, &updatedMS, &completedMS,
		&t.SourceRef, &t.SourceURL, &t.SourceProvider, &t.SourceTeamKey, &t.SourceProjectID,
		&t.CommentCount, &t.AttachmentCount,
	); err != nil {
		return todoschema.Todo{}, err
	}
	if projectID.Valid {
		t.ProjectID = projectID.String
	}
	t.CreatedAt = time.UnixMilli(createdMS).UTC()
	t.UpdatedAt = time.UnixMilli(updatedMS).UTC()
	if dueMS.Valid {
		v := time.UnixMilli(dueMS.Int64).UTC()
		t.DueAt = &v
	}
	if nextMS.Valid {
		v := time.UnixMilli(nextMS.Int64).UTC()
		t.NextOccurrenceAt = &v
	}
	if completedMS.Valid {
		v := time.UnixMilli(completedMS.Int64).UTC()
		t.CompletedAt = &v
	}
	return t, nil
}

func nullableString(s string) sql.NullString {
	if s == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: s, Valid: true}
}

func timeToNullMS(t *time.Time) sql.NullInt64 {
	if t == nil {
		return sql.NullInt64{}
	}
	return sql.NullInt64{Int64: t.UnixMilli(), Valid: true}
}

// getTodoRow reads a todo by id with no authorization check — internal
// helper for the exported methods below, each of which does its own
// permission check via todoPermission before or after calling this.
func (s *Store) getTodoRow(ctx context.Context, id string) (todoschema.Todo, error) {
	t, err := scanTodoRow(s.db.QueryRowContext(ctx, `SELECT `+todoColumns+` FROM todos t WHERE t.id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return todoschema.Todo{}, ErrNotFound
	}
	return t, err
}

func (s *Store) queryTodos(ctx context.Context, query string, args ...any) ([]todoschema.Todo, error) {
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (todoschema.Todo, error) { return scanTodoRow(r) })
}

// todoPerm is the set of actions callerIdentity may take on one todo.
type todoPerm struct {
	view, comment, edit, del bool
}

func fullTodoPerm() todoPerm { return todoPerm{view: true, comment: true, edit: true, del: true} }

// todoPermission derives callerIdentity's access to t. Mirrors the project
// role semantics already documented on RoleOwner/RoleMember/RoleViewer in
// projects.go ("member can view + comment; viewer is read-only"), extended
// with two decisions specific to todos (see pkg/todoschema/todo.go and the
// Phase 0 handoff note for the full rationale):
//   - "viewer is read-only" is taken literally: a viewer can list/view a
//     team todo but cannot comment or edit it, let alone delete it.
//   - delete is stricter than edit: only the project's owner role (or a
//     personal todo's own owner_identity) may delete; member can edit but
//     not delete, so team members can't casually wipe each other's todos.
//
// A global admin (users.is_admin) always gets full access, matching the
// existing "Global admin supersedes all of these" note on project roles.
func (s *Store) todoPermission(ctx context.Context, t todoschema.Todo, identity string) (todoPerm, error) {
	if identity == "" {
		return todoPerm{}, nil
	}
	isAdmin, err := s.UserIsAdmin(ctx, identity)
	if err != nil {
		return todoPerm{}, err
	}
	if isAdmin {
		return fullTodoPerm(), nil
	}
	if t.ProjectID == "" {
		if identity == t.OwnerIdentity {
			return fullTodoPerm(), nil
		}
		return todoPerm{}, nil
	}
	role, ok, err := s.MemberRole(ctx, t.ProjectID, identity)
	if err != nil {
		return todoPerm{}, err
	}
	if !ok {
		return todoPerm{}, nil
	}
	switch role {
	case RoleOwner:
		return fullTodoPerm(), nil
	case RoleMember:
		return todoPerm{view: true, comment: true, edit: true}, nil
	case RoleViewer:
		return todoPerm{view: true}, nil
	default:
		return todoPerm{}, nil
	}
}

func forbidTodo(action, identity, id string) error {
	return fmt.Errorf("%w: %s cannot %s todo %s", ErrForbidden, identity, action, id)
}

// CreateTodo inserts t, defaulting Status/Priority/timestamps when the
// caller left them zero-valued (all three Phase 1+ entry points — HTTP
// handler, MCP tool, CLI — build a Todo by hand, so defaulting here avoids
// triplicating that logic). t.OwnerIdentity is treated as the creator: for
// a team todo (ProjectID set) they must already be an owner/member of that
// project (not viewer, matching todoPermission's edit tier); personal
// todos (ProjectID empty) have no such check since owner_identity IS the
// access boundary.
func (s *Store) CreateTodo(ctx context.Context, t *todoschema.Todo) error {
	if t.ID == "" {
		return fmt.Errorf("create todo: id required")
	}
	if t.OwnerIdentity == "" {
		return fmt.Errorf("create todo: owner_identity required")
	}
	if t.Title == "" {
		return fmt.Errorf("create todo: title required")
	}
	if t.Status == "" {
		t.Status = todoschema.StatusTodo
	} else if !todoschema.ValidStatus(t.Status) {
		return fmt.Errorf("create todo: invalid status %q", t.Status)
	}
	if t.Priority == "" {
		t.Priority = todoschema.PriorityNormal
	} else if !todoschema.ValidPriority(t.Priority) {
		return fmt.Errorf("create todo: invalid priority %q", t.Priority)
	}
	if !todoschema.ValidRecurrence(t.Recurrence) {
		return fmt.Errorf("create todo: invalid recurrence %q", t.Recurrence)
	}
	now := time.Now().UTC()
	if t.CreatedAt.IsZero() {
		t.CreatedAt = now
	}
	if t.UpdatedAt.IsZero() {
		t.UpdatedAt = t.CreatedAt
	}
	if t.ProjectID != "" {
		isAdmin, err := s.UserIsAdmin(ctx, t.OwnerIdentity)
		if err != nil {
			return err
		}
		if !isAdmin {
			role, ok, err := s.MemberRole(ctx, t.ProjectID, t.OwnerIdentity)
			if err != nil {
				return err
			}
			if !ok || role == RoleViewer {
				return forbidTodo("create todos in", t.OwnerIdentity, t.ProjectID)
			}
		}
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO todos(id, project_id, owner_identity, title, body_md, status, priority,
			assignee_identity, assignee_session_id, assignee_session_label, workspace_name, repo_name, recurrence, group_name,
			due_at, next_occurrence_at, created_at, updated_at, completed_at,
			source_ref, source_url, source_provider, source_team_key, source_project_id)
		 VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		t.ID, nullableString(t.ProjectID), t.OwnerIdentity, t.Title, t.BodyMD, string(t.Status), string(t.Priority),
		t.AssigneeIdentity, t.AssigneeSessionID, t.AssigneeSessionLabel, t.WorkspaceName, t.RepoName, string(t.Recurrence), t.GroupName,
		timeToNullMS(t.DueAt), timeToNullMS(t.NextOccurrenceAt), t.CreatedAt.UnixMilli(), t.UpdatedAt.UnixMilli(), timeToNullMS(t.CompletedAt),
		t.SourceRef, t.SourceURL, t.SourceProvider, t.SourceTeamKey, t.SourceProjectID,
	)
	return err
}

// GetTodo returns todo id if callerIdentity has view access, including its
// attachment metadata (the one place Attachments is populated — see the
// field comment in pkg/todoschema/todo.go). ErrNotFound if the row doesn't
// exist; ErrForbidden if it exists but callerIdentity can't view it.
func (s *Store) GetTodo(ctx context.Context, id, callerIdentity string) (todoschema.Todo, error) {
	t, err := s.getTodoRow(ctx, id)
	if err != nil {
		return todoschema.Todo{}, err
	}
	perm, err := s.todoPermission(ctx, t, callerIdentity)
	if err != nil {
		return todoschema.Todo{}, err
	}
	if !perm.view {
		return todoschema.Todo{}, forbidTodo("view", callerIdentity, id)
	}
	return s.withAttachments(ctx, t)
}

// FindTodoBySourceRef looks up the visible todo previously imported from
// sourceRef in the requested destination scope: projectID empty means the
// caller's personal todos, non-empty means that exact relay project. This
// keeps source_ref idempotency scoped to where the import writes; source_ref
// is an external identifier, not a globally-owned unique key.
func (s *Store) FindTodoBySourceRef(ctx context.Context, callerIdentity, sourceRef, projectID string) (todoschema.Todo, bool, error) {
	if sourceRef == "" {
		return todoschema.Todo{}, false, nil
	}
	query := `SELECT ` + todoColumns + ` FROM todos t WHERE t.source_ref = ?`
	args := []any{sourceRef}
	if projectID == "" {
		query += ` AND t.project_id IS NULL AND t.owner_identity = ?`
		args = append(args, callerIdentity)
	} else {
		query += ` AND t.project_id = ?`
		args = append(args, projectID)
	}
	query += ` ORDER BY t.created_at DESC`
	items, err := s.queryTodos(ctx, query, args...)
	if err != nil {
		return todoschema.Todo{}, false, err
	}
	for _, t := range items {
		perm, err := s.todoPermission(ctx, t, callerIdentity)
		if err != nil {
			return todoschema.Todo{}, false, err
		}
		if !perm.view {
			continue
		}
		t, err = s.withAttachments(ctx, t)
		if err != nil {
			return todoschema.Todo{}, false, err
		}
		return t, true, nil
	}
	return todoschema.Todo{}, false, nil
}

// withAttachments joins t.Attachments in from listTodoAttachmentsRaw. Every
// mutator that hands a Todo back to the caller (GetTodo, UpdateTodoFields,
// SetTodoStatus, AssignTodo) must route its final getTodoRow through this —
// getTodoRow alone always returns a nil Attachments slice (it only reads the
// todos table), so skipping this silently drops attachment metadata from the
// response despite the row's attachment_count being correct. That's exactly
// the bug Track 1's inline-image work hit: after any PATCH/status/assign
// save, the client's already-loaded attachment list got clobbered by an
// empty one from the response.
func (s *Store) withAttachments(ctx context.Context, t todoschema.Todo) (todoschema.Todo, error) {
	atts, err := s.listTodoAttachmentsRaw(ctx, t.ID)
	if err != nil {
		return todoschema.Todo{}, err
	}
	t.Attachments = atts
	return t, nil
}

// TodoListFilter selects which todos ListTodos returns. Scope is one of
// "personal" (default), "project", "assigned", or "all" (admin-only) —
// mirrors the ?scope= query param in the plan's REST contract.
type TodoListFilter struct {
	Scope     string
	ProjectID string // scope="project" only; empty = union of every project callerIdentity belongs to
	Status    string // optional exact-match filter
	GroupName string // optional exact-match filter (see pkg/todoschema.Todo.GroupName)
	Limit     int
}

// ListTodos returns todos visible to callerIdentity under filter. Unlike
// GetTodo, visibility here is enforced by construction of the WHERE clause
// (each branch only ever selects rows callerIdentity is entitled to), not
// by a per-row permission check, so it stays a single query.
func (s *Store) ListTodos(ctx context.Context, callerIdentity string, f TodoListFilter) ([]todoschema.Todo, error) {
	limit := f.Limit
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	var query string
	var args []any
	switch f.Scope {
	case "", "personal":
		query = `SELECT ` + todoColumns + ` FROM todos t WHERE t.project_id IS NULL AND t.owner_identity = ?`
		args = append(args, callerIdentity)
	case "project":
		if f.ProjectID != "" {
			isAdmin, err := s.UserIsAdmin(ctx, callerIdentity)
			if err != nil {
				return nil, err
			}
			if !isAdmin {
				_, ok, err := s.MemberRole(ctx, f.ProjectID, callerIdentity)
				if err != nil {
					return nil, err
				}
				if !ok {
					return nil, forbidTodo("list", callerIdentity, "project:"+f.ProjectID)
				}
			}
			query = `SELECT ` + todoColumns + ` FROM todos t WHERE t.project_id = ?`
			args = append(args, f.ProjectID)
		} else {
			query = `SELECT ` + todoColumns + ` FROM todos t
			           JOIN project_members pm ON pm.project_id = t.project_id
			          WHERE pm.identity = ?`
			args = append(args, callerIdentity)
		}
	case "assigned":
		query = `SELECT ` + todoColumns + ` FROM todos t WHERE t.assignee_identity = ?`
		args = append(args, callerIdentity)
	case "all":
		isAdmin, err := s.UserIsAdmin(ctx, callerIdentity)
		if err != nil {
			return nil, err
		}
		if !isAdmin {
			return nil, forbidTodo("list", callerIdentity, "scope:all")
		}
		query = `SELECT ` + todoColumns + ` FROM todos t WHERE 1=1`
	default:
		return nil, fmt.Errorf("todos: unknown scope %q", f.Scope)
	}
	if f.Status != "" {
		query += ` AND t.status = ?`
		args = append(args, f.Status)
	}
	if f.GroupName != "" {
		query += ` AND t.group_name = ?`
		args = append(args, f.GroupName)
	}
	query += ` ORDER BY t.created_at DESC LIMIT ?`
	args = append(args, limit)
	return s.queryTodos(ctx, query, args...)
}

// TodoPatch is the decoded form of PATCH /v1/todos/{id}. DueAt uses
// OptionalTime rather than a plain *time.Time so the store can distinguish
// "field not sent" (leave due_at alone) from "field sent as null" (clear
// due_at) — see the plan's null-vs-absent note. The handler layer is
// expected to decode the request body as map[string]json.RawMessage and
// only set DueAt.Set when the "due_at" key was present at all.
type TodoPatch struct {
	Title      *string
	BodyMD     *string
	Priority   *todoschema.Priority
	Recurrence *todoschema.Recurrence
	DueAt      OptionalTime
	// WorkspaceName/RepoName use the same simple *string "nil = leave alone"
	// semantics as Title/BodyMD — unlike DueAt there's no meaningful
	// null-vs-absent distinction here, since an empty string already means
	// "clear the binding" (see pkg/todoschema.Todo field docs).
	WorkspaceName *string
	RepoName      *string
	// GroupName uses the same *string "nil = leave alone" semantics — an
	// empty string means "clear to ungrouped" (see pkg/todoschema.Todo field
	// docs).
	GroupName *string
	// Source metadata is set by importers and may be backfilled on re-import
	// for older rows that only had source_ref/source_url.
	SourceProvider  *string
	SourceTeamKey   *string
	SourceProjectID *string
}

type OptionalTime struct {
	Set   bool
	Value *time.Time // meaningful only when Set; nil means "clear to null"
}

// UpdateTodoFields applies patch to todo id, requiring edit access.
func (s *Store) UpdateTodoFields(ctx context.Context, id, callerIdentity string, patch TodoPatch) (todoschema.Todo, error) {
	t, err := s.getTodoRow(ctx, id)
	if err != nil {
		return todoschema.Todo{}, err
	}
	perm, err := s.todoPermission(ctx, t, callerIdentity)
	if err != nil {
		return todoschema.Todo{}, err
	}
	if !perm.edit {
		return todoschema.Todo{}, forbidTodo("edit", callerIdentity, id)
	}
	if patch.Priority != nil && !todoschema.ValidPriority(*patch.Priority) {
		return todoschema.Todo{}, fmt.Errorf("update todo: invalid priority %q", *patch.Priority)
	}
	if patch.Recurrence != nil && !todoschema.ValidRecurrence(*patch.Recurrence) {
		return todoschema.Todo{}, fmt.Errorf("update todo: invalid recurrence %q", *patch.Recurrence)
	}

	sets := []string{"updated_at = ?"}
	args := []any{time.Now().UTC().UnixMilli()}
	if patch.Title != nil {
		sets = append(sets, "title = ?")
		args = append(args, *patch.Title)
	}
	if patch.BodyMD != nil {
		sets = append(sets, "body_md = ?")
		args = append(args, *patch.BodyMD)
	}
	if patch.Priority != nil {
		sets = append(sets, "priority = ?")
		args = append(args, string(*patch.Priority))
	}
	if patch.Recurrence != nil {
		sets = append(sets, "recurrence = ?")
		args = append(args, string(*patch.Recurrence))
	}
	if patch.DueAt.Set {
		sets = append(sets, "due_at = ?")
		args = append(args, timeToNullMS(patch.DueAt.Value))
	}
	if patch.WorkspaceName != nil {
		sets = append(sets, "workspace_name = ?")
		args = append(args, *patch.WorkspaceName)
	}
	if patch.RepoName != nil {
		sets = append(sets, "repo_name = ?")
		args = append(args, *patch.RepoName)
	}
	if patch.GroupName != nil {
		sets = append(sets, "group_name = ?")
		args = append(args, *patch.GroupName)
	}
	if patch.SourceProvider != nil {
		sets = append(sets, "source_provider = ?")
		args = append(args, *patch.SourceProvider)
	}
	if patch.SourceTeamKey != nil {
		sets = append(sets, "source_team_key = ?")
		args = append(args, *patch.SourceTeamKey)
	}
	if patch.SourceProjectID != nil {
		sets = append(sets, "source_project_id = ?")
		args = append(args, *patch.SourceProjectID)
	}
	args = append(args, id)
	if _, err := s.db.ExecContext(ctx,
		`UPDATE todos SET `+strings.Join(sets, ", ")+` WHERE id = ?`, args...,
	); err != nil {
		return todoschema.Todo{}, err
	}
	updated, err := s.getTodoRow(ctx, id)
	if err != nil {
		return todoschema.Todo{}, err
	}
	return s.withAttachments(ctx, updated)
}

// SetTodoStatus transitions todo id to status, requiring edit access. When
// status becomes done it stamps completed_at and — if the todo recurs —
// computes next_occurrence_at from Recurrence.AddInterval(now). Any other
// status clears both completed_at and next_occurrence_at (reopening a done
// recurring todo cancels its pending re-appearance; the recurrence sweep,
// internal/relay/todo_recurrence.go in Phase 1, is what actually acts on
// next_occurrence_at while the todo stays done).
func (s *Store) SetTodoStatus(ctx context.Context, id, callerIdentity string, status todoschema.Status) (todoschema.Todo, error) {
	if !todoschema.ValidStatus(status) {
		return todoschema.Todo{}, fmt.Errorf("set todo status: invalid status %q", status)
	}
	t, err := s.getTodoRow(ctx, id)
	if err != nil {
		return todoschema.Todo{}, err
	}
	perm, err := s.todoPermission(ctx, t, callerIdentity)
	if err != nil {
		return todoschema.Todo{}, err
	}
	if !perm.edit {
		return todoschema.Todo{}, forbidTodo("edit", callerIdentity, id)
	}
	now := time.Now().UTC()
	var completedAt, nextAt sql.NullInt64
	if status == todoschema.StatusDone {
		completedAt = sql.NullInt64{Int64: now.UnixMilli(), Valid: true}
		if t.Recurrence != "" {
			nextAt = sql.NullInt64{Int64: t.Recurrence.AddInterval(now).UnixMilli(), Valid: true}
		}
	}
	if _, err := s.db.ExecContext(ctx,
		`UPDATE todos SET status = ?, completed_at = ?, next_occurrence_at = ?, updated_at = ? WHERE id = ?`,
		string(status), completedAt, nextAt, now.UnixMilli(), id,
	); err != nil {
		return todoschema.Todo{}, err
	}
	updated, err := s.getTodoRow(ctx, id)
	if err != nil {
		return todoschema.Todo{}, err
	}
	return s.withAttachments(ctx, updated)
}

// AssignTodo sets (or clears, when all args are empty) the assignee fields,
// requiring edit access. assigneeAgentSessionID/assigneeWorkdir/
// assigneeAgentKind are the permanent-resume trio (see the field docs on
// pkg/todoschema.Todo) — pass them alongside assigneeSessionID when the
// target is a live agent session so "open the bound session" can respawn it
// with --resume long after the bus session id itself has gone stale; pass
// all three empty to leave the todo with no resumable session recorded.
// Unlike the pre-taxonomy-rework version of this method, assignment no
// longer touches Status at all: "who" (assignee) and "what stage" (status)
// are independent dimensions now that Status has no "assigned" value of its
// own to nudge toward — matching Linear's own model, where assignee and
// state are unrelated fields.
func (s *Store) AssignTodo(ctx context.Context, id, callerIdentity, assigneeIdentity, assigneeSessionID, assigneeSessionLabel, assigneeAgentSessionID, assigneeWorkdir, assigneeAgentKind string) (todoschema.Todo, error) {
	t, err := s.getTodoRow(ctx, id)
	if err != nil {
		return todoschema.Todo{}, err
	}
	perm, err := s.todoPermission(ctx, t, callerIdentity)
	if err != nil {
		return todoschema.Todo{}, err
	}
	if !perm.edit {
		return todoschema.Todo{}, forbidTodo("assign", callerIdentity, id)
	}
	now := time.Now().UTC()
	if _, err := s.db.ExecContext(ctx,
		`UPDATE todos SET assignee_identity = ?, assignee_session_id = ?, assignee_session_label = ?,
			assignee_agent_session_id = ?, assignee_workdir = ?, assignee_agent_kind = ?,
			updated_at = ? WHERE id = ?`,
		assigneeIdentity, assigneeSessionID, assigneeSessionLabel,
		assigneeAgentSessionID, assigneeWorkdir, assigneeAgentKind,
		now.UnixMilli(), id,
	); err != nil {
		return todoschema.Todo{}, err
	}
	updated, err := s.getTodoRow(ctx, id)
	if err != nil {
		return todoschema.Todo{}, err
	}
	return s.withAttachments(ctx, updated)
}

// DeleteTodo removes todo id, requiring delete access (stricter than edit
// — see todoPermission).
func (s *Store) DeleteTodo(ctx context.Context, id, callerIdentity string) error {
	t, err := s.getTodoRow(ctx, id)
	if err != nil {
		return err
	}
	perm, err := s.todoPermission(ctx, t, callerIdentity)
	if err != nil {
		return err
	}
	if !perm.del {
		return forbidTodo("delete", callerIdentity, id)
	}
	_, err = s.db.ExecContext(ctx, `DELETE FROM todos WHERE id = ?`, id)
	return err
}

// DueRecurringTodos returns every done, recurring todo whose
// next_occurrence_at has elapsed as of now. System-level (no
// callerIdentity/permission check) — meant for the Phase 1 recurrence
// sweep ticker, not end-user-facing.
func (s *Store) DueRecurringTodos(ctx context.Context, now time.Time) ([]todoschema.Todo, error) {
	return s.queryTodos(ctx,
		`SELECT `+todoColumns+` FROM todos t
		  WHERE t.status = ? AND t.recurrence != '' AND t.next_occurrence_at IS NOT NULL AND t.next_occurrence_at <= ?
		  ORDER BY t.next_occurrence_at ASC`,
		string(todoschema.StatusDone), now.UnixMilli(),
	)
}

// ResetRecurringTodo resets a due recurring todo back to todo (its default
// creation status — see pkg/todoschema.StatusTodo), clearing completed_at/
// next_occurrence_at. Guarded on status='done' in the WHERE clause so a
// concurrent status change (e.g. someone reopened it manually between
// DueRecurringTodos and this call) is a harmless no-op rather than
// clobbering their change; system-level like DueRecurringTodos.
func (s *Store) ResetRecurringTodo(ctx context.Context, id string, now time.Time) (todoschema.Todo, error) {
	if _, err := s.db.ExecContext(ctx,
		`UPDATE todos SET status = ?, completed_at = NULL, next_occurrence_at = NULL, updated_at = ?
		  WHERE id = ? AND status = ?`,
		string(todoschema.StatusTodo), now.UnixMilli(), id, string(todoschema.StatusDone),
	); err != nil {
		return todoschema.Todo{}, err
	}
	return s.getTodoRow(ctx, id)
}

// requireTodoProjectMember checks that callerIdentity has at least view
// access to project's todos (any member role including viewer, or global
// admin) — the same tier ListTodos' scope="project" branch already uses.
func (s *Store) requireTodoProjectMember(ctx context.Context, callerIdentity, projectID string) error {
	isAdmin, err := s.UserIsAdmin(ctx, callerIdentity)
	if err != nil {
		return err
	}
	if isAdmin {
		return nil
	}
	_, ok, err := s.MemberRole(ctx, projectID, callerIdentity)
	if err != nil {
		return err
	}
	if !ok {
		return forbidTodo("list", callerIdentity, "project:"+projectID)
	}
	return nil
}

// requireTodoProjectEditor checks that callerIdentity can edit todos in
// project (owner/member, not viewer, or global admin) — the same tier
// CreateTodo requires for creating a team todo.
func (s *Store) requireTodoProjectEditor(ctx context.Context, callerIdentity, projectID string) error {
	isAdmin, err := s.UserIsAdmin(ctx, callerIdentity)
	if err != nil {
		return err
	}
	if isAdmin {
		return nil
	}
	role, ok, err := s.MemberRole(ctx, projectID, callerIdentity)
	if err != nil {
		return err
	}
	if !ok || role == RoleViewer {
		return forbidTodo("edit todo groups in", callerIdentity, projectID)
	}
	return nil
}

// ListTodoGroups returns the distinct, non-empty group names currently in
// use (see pkg/todoschema.Todo.GroupName), scoped to callerIdentity's own
// personal todos (projectID == "") or to one team project (any member role,
// including viewer, may list — same tier as ListTodos' scope="project"
// branch). Unlike ListTodos there's no "union of every project" mode: a
// group name is only meaningful within the one scope it was set in.
func (s *Store) ListTodoGroups(ctx context.Context, callerIdentity, projectID string) ([]string, error) {
	var rows *sql.Rows
	var err error
	if projectID == "" {
		rows, err = s.db.QueryContext(ctx,
			`SELECT DISTINCT group_name FROM todos WHERE project_id IS NULL AND owner_identity = ? AND group_name != '' ORDER BY group_name`,
			callerIdentity)
	} else {
		if err := s.requireTodoProjectMember(ctx, callerIdentity, projectID); err != nil {
			return nil, err
		}
		rows, err = s.db.QueryContext(ctx,
			`SELECT DISTINCT group_name FROM todos WHERE project_id = ? AND group_name != '' ORDER BY group_name`,
			projectID)
	}
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (string, error) {
		var g string
		err := r.Scan(&g)
		return g, err
	})
}

// RenameTodoGroup bulk-renames every todo currently in oldName to newName,
// scoped like ListTodoGroups but requiring edit access (owner/member, not
// viewer) since it mutates. A no-op (oldName not in use in this scope) is
// not an error. There's no dedicated "create a group" API — a todo simply
// starts pointing at a new name (see the field docs on
// pkg/todoschema.Todo.GroupName); this is only for relabeling one that
// already has todos in it.
func (s *Store) RenameTodoGroup(ctx context.Context, callerIdentity, projectID, oldName, newName string) error {
	if projectID == "" {
		_, err := s.db.ExecContext(ctx,
			`UPDATE todos SET group_name = ? WHERE project_id IS NULL AND owner_identity = ? AND group_name = ?`,
			newName, callerIdentity, oldName)
		return err
	}
	if err := s.requireTodoProjectEditor(ctx, callerIdentity, projectID); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx,
		`UPDATE todos SET group_name = ? WHERE project_id = ? AND group_name = ?`,
		newName, projectID, oldName)
	return err
}

// ClearTodoGroup bulk-clears group_name back to "" (ungrouped) on every todo
// currently in name, without deleting the todos themselves. Same
// scoping/permission tier as RenameTodoGroup.
func (s *Store) ClearTodoGroup(ctx context.Context, callerIdentity, projectID, name string) error {
	if projectID == "" {
		_, err := s.db.ExecContext(ctx,
			`UPDATE todos SET group_name = '' WHERE project_id IS NULL AND owner_identity = ? AND group_name = ?`,
			callerIdentity, name)
		return err
	}
	if err := s.requireTodoProjectEditor(ctx, callerIdentity, projectID); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx,
		`UPDATE todos SET group_name = '' WHERE project_id = ? AND group_name = ?`,
		projectID, name)
	return err
}

// InsertTodoComment posts a comment on todo id, requiring comment access
// (view+comment tier — team viewers are excluded, matching "viewer is
// read-only").
func (s *Store) InsertTodoComment(ctx context.Context, todoID, author, body string) (todoschema.Comment, error) {
	t, err := s.getTodoRow(ctx, todoID)
	if err != nil {
		return todoschema.Comment{}, err
	}
	perm, err := s.todoPermission(ctx, t, author)
	if err != nil {
		return todoschema.Comment{}, err
	}
	if !perm.comment {
		return todoschema.Comment{}, forbidTodo("comment on", author, todoID)
	}
	now := time.Now().UTC()
	res, err := s.db.ExecContext(ctx,
		`INSERT INTO todo_comments(todo_id, author_identity, body, created_at) VALUES(?, ?, ?, ?)`,
		todoID, author, body, now.UnixMilli(),
	)
	if err != nil {
		return todoschema.Comment{}, err
	}
	id, _ := res.LastInsertId()
	return todoschema.Comment{ID: id, TodoID: todoID, AuthorIdentity: author, Body: body, CreatedAt: now}, nil
}

// ListTodoComments returns every comment on todo id, oldest-first,
// requiring view access.
func (s *Store) ListTodoComments(ctx context.Context, todoID, callerIdentity string) ([]todoschema.Comment, error) {
	t, err := s.getTodoRow(ctx, todoID)
	if err != nil {
		return nil, err
	}
	perm, err := s.todoPermission(ctx, t, callerIdentity)
	if err != nil {
		return nil, err
	}
	if !perm.view {
		return nil, forbidTodo("view", callerIdentity, todoID)
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, author_identity, body, created_at FROM todo_comments WHERE todo_id = ? ORDER BY created_at ASC`,
		todoID,
	)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (todoschema.Comment, error) {
		var c todoschema.Comment
		var createdMS int64
		if err := r.Scan(&c.ID, &c.AuthorIdentity, &c.Body, &createdMS); err != nil {
			return todoschema.Comment{}, err
		}
		c.TodoID = todoID
		c.CreatedAt = time.UnixMilli(createdMS).UTC()
		return c, nil
	})
}

// PutTodoAttachment uploads (or replaces) attachment name on todo id,
// requiring edit access. Mirrors Store.PutAttachment's upsert-by-name
// semantics exactly.
func (s *Store) PutTodoAttachment(ctx context.Context, todoID, callerIdentity, name, sha256Hex string, content []byte) error {
	t, err := s.getTodoRow(ctx, todoID)
	if err != nil {
		return err
	}
	perm, err := s.todoPermission(ctx, t, callerIdentity)
	if err != nil {
		return err
	}
	if !perm.edit {
		return forbidTodo("attach to", callerIdentity, todoID)
	}
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO todo_attachments(todo_id, name, sha256, size, content, created_at)
		 VALUES(?, ?, ?, ?, ?, ?)
		 ON CONFLICT(todo_id, name) DO UPDATE SET
		   sha256     = excluded.sha256,
		   size       = excluded.size,
		   content    = excluded.content,
		   created_at = excluded.created_at`,
		todoID, name, sha256Hex, len(content), content, time.Now().UTC().UnixMilli(),
	)
	return err
}

// GetTodoAttachment returns the raw bytes plus sha256/size for a todo
// attachment, requiring view access. ErrNotFound if no such attachment.
func (s *Store) GetTodoAttachment(ctx context.Context, todoID, callerIdentity, name string) ([]byte, string, int, error) {
	t, err := s.getTodoRow(ctx, todoID)
	if err != nil {
		return nil, "", 0, err
	}
	perm, err := s.todoPermission(ctx, t, callerIdentity)
	if err != nil {
		return nil, "", 0, err
	}
	if !perm.view {
		return nil, "", 0, forbidTodo("view", callerIdentity, todoID)
	}
	var content []byte
	var sum string
	var size int
	err = s.db.QueryRowContext(ctx,
		`SELECT content, sha256, size FROM todo_attachments WHERE todo_id = ? AND name = ?`,
		todoID, name,
	).Scan(&content, &sum, &size)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, "", 0, ErrNotFound
	}
	if err != nil {
		return nil, "", 0, err
	}
	return content, sum, size, nil
}

// ListTodoAttachments returns attachment metadata (no content bytes) for
// todo id, requiring view access.
func (s *Store) ListTodoAttachments(ctx context.Context, todoID, callerIdentity string) ([]todoschema.Attachment, error) {
	t, err := s.getTodoRow(ctx, todoID)
	if err != nil {
		return nil, err
	}
	perm, err := s.todoPermission(ctx, t, callerIdentity)
	if err != nil {
		return nil, err
	}
	if !perm.view {
		return nil, forbidTodo("view", callerIdentity, todoID)
	}
	return s.listTodoAttachmentsRaw(ctx, todoID)
}

// listTodoAttachmentsRaw is the no-auth-check core of ListTodoAttachments,
// reused by GetTodo (which has already checked view access on the parent
// todo by the time it needs the attachment list).
func (s *Store) listTodoAttachmentsRaw(ctx context.Context, todoID string) ([]todoschema.Attachment, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT name, sha256, size, created_at FROM todo_attachments WHERE todo_id = ? ORDER BY created_at ASC`,
		todoID,
	)
	if err != nil {
		return nil, err
	}
	return scanRows(rows, func(r *sql.Rows) (todoschema.Attachment, error) {
		var a todoschema.Attachment
		var createdMS int64
		if err := r.Scan(&a.Name, &a.SHA256, &a.Size, &createdMS); err != nil {
			return todoschema.Attachment{}, err
		}
		a.CreatedAt = time.UnixMilli(createdMS).UTC()
		return a, nil
	})
}
