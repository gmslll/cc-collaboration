package relay

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
	"github.com/cc-collaboration/pkg/todoschema"
)

// writeStoreError maps a Store error to the matching HTTP status, mirroring
// the switch Server.reassign already uses for handoffs: ErrForbidden -> 403,
// ErrNotFound -> 404, anything else -> 500. All Todo authorization
// (view/edit/delete/comment, by owner or by project role) is enforced inside
// internal/relay/store/todos.go — handlers below never re-derive it, just
// translate the sentinel error.
func writeStoreError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrForbidden):
		http.Error(w, "forbidden", http.StatusForbidden)
	case errors.Is(err, store.ErrNotFound):
		http.Error(w, "not found", http.StatusNotFound)
	default:
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func (s *Server) createTodo(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	var req struct {
		Title      string     `json:"title"`
		BodyMD     string     `json:"body_md"`
		Priority   string     `json:"priority"`
		ProjectID  string     `json:"project_id"`
		Recurrence string     `json:"recurrence"`
		DueAt      *time.Time `json:"due_at"`
		// SourceRef/SourceURL let an import command (e.g. `cc-handoff todo
		// import-linear`, internal/linear/import.go) stamp which external
		// issue a todo came from — see pkg/todoschema.Todo.SourceRef and
		// Store.FindTodoBySourceRef. Set once at creation; there's no PATCH
		// support for them since they're not meant to change afterward.
		SourceRef       string `json:"source_ref"`
		SourceURL       string `json:"source_url"`
		SourceProvider  string `json:"source_provider"`
		SourceTeamKey   string `json:"source_team_key"`
		SourceProjectID string `json:"source_project_id"`
		// SourceUpdatedAt is the external updatedAt idempotency watermark;
		// SourceAssigneeName/AvatarURL are the external assignee for display.
		SourceUpdatedAt         string `json:"source_updated_at"`
		SourceAssigneeName      string `json:"source_assignee_name"`
		SourceAssigneeAvatarURL string `json:"source_assignee_avatar_url"`
		// WorkspaceName/RepoName are the optional workspace/repo binding (see
		// pkg/todoschema.Todo field docs) — both empty (the default) means
		// "not bound".
		WorkspaceName string `json:"workspace_name"`
		RepoName      string `json:"repo_name"`
		// GroupName is the optional free-form bucket (see
		// pkg/todoschema.Todo.GroupName) — empty means ungrouped.
		GroupName string `json:"group_name"`
	}
	if err := decodeJSONBody(w, r, 64<<10, &req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(req.Title) == "" {
		http.Error(w, "title required", http.StatusBadRequest)
		return
	}
	priority := todoschema.Priority(req.Priority)
	if priority != "" && !todoschema.ValidPriority(priority) {
		http.Error(w, "invalid priority", http.StatusBadRequest)
		return
	}
	recurrence := todoschema.Recurrence(req.Recurrence)
	if !todoschema.ValidRecurrence(recurrence) {
		http.Error(w, "invalid recurrence", http.StatusBadRequest)
		return
	}

	now := time.Now().UTC()
	t := &todoschema.Todo{
		ID:              handoff.NewID(now),
		ProjectID:       req.ProjectID,
		OwnerIdentity:   identity,
		Title:           req.Title,
		BodyMD:          req.BodyMD,
		Priority:        priority,
		Recurrence:      recurrence,
		DueAt:           req.DueAt,
		CreatedAt:       now,
		UpdatedAt:       now,
		SourceRef:       req.SourceRef,
		SourceURL:       req.SourceURL,
		SourceProvider:  req.SourceProvider,
		SourceTeamKey:   req.SourceTeamKey,
		SourceProjectID: req.SourceProjectID,

		SourceUpdatedAt:         req.SourceUpdatedAt,
		SourceAssigneeName:      req.SourceAssigneeName,
		SourceAssigneeAvatarURL: req.SourceAssigneeAvatarURL,
		WorkspaceName:           req.WorkspaceName,
		RepoName:                req.RepoName,
		GroupName:               req.GroupName,
	}
	if err := s.Store.CreateTodo(r.Context(), t); err != nil {
		writeStoreError(w, err)
		return
	}
	s.publishTodoEvent(r.Context(), sse.EventTypeTodoCreated, *t)
	writeJSON(w, http.StatusCreated, t)
}

func (s *Server) listTodos(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	q := r.URL.Query()
	filter := store.TodoListFilter{
		Scope:     q.Get("scope"),
		ProjectID: q.Get("project"),
		Status:    q.Get("status"),
		GroupName: q.Get("group"),
	}
	if v := q.Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			filter.Limit = n
		}
	}
	items, err := s.Store.ListTodos(r.Context(), identity, filter)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) getTodo(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	t, err := s.Store.GetTodo(r.Context(), r.PathValue("id"), identity)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, t)
}

// findTodoBySourceRef exposes Store.FindTodoBySourceRef over HTTP for import
// commands (e.g. `cc-handoff todo import-linear`) to decide "already
// imported — update it" vs. "not seen before — create it". The optional
// ?project= query parameter scopes the lookup to that relay project; omitting
// it scopes the lookup to the caller's personal todos. Unlike getTodo, "no
// such source_ref" is an expected, common outcome rather than an error, so
// it's always a 200 with found=false rather than a 404.
func (s *Server) findTodoBySourceRef(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	ref := r.URL.Query().Get("ref")
	if ref == "" {
		http.Error(w, "ref query param required", http.StatusBadRequest)
		return
	}
	t, found, err := s.Store.FindTodoBySourceRef(r.Context(), identity, ref, r.URL.Query().Get("project"))
	if err != nil {
		writeStoreError(w, err)
		return
	}
	if !found {
		writeJSON(w, http.StatusOK, map[string]any{"found": false})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"found": true, "todo": t})
}

// listTodoGroups exposes Store.ListTodoGroups over HTTP: the distinct,
// non-empty group names in use, personal-scoped by default or scoped to one
// team project via ?project=.
func (s *Server) listTodoGroups(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	groups, err := s.Store.ListTodoGroups(r.Context(), identity, r.URL.Query().Get("project"))
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"groups": groups})
}

// renameTodoGroup exposes Store.RenameTodoGroup over HTTP: bulk-renames
// every todo currently in old_name (within the project_id scope, or personal
// when empty) to new_name.
func (s *Server) renameTodoGroup(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	var req struct {
		ProjectID string `json:"project_id"`
		OldName   string `json:"old_name"`
		NewName   string `json:"new_name"`
	}
	if err := decodeJSONBody(w, r, 4<<10, &req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(req.OldName) == "" || strings.TrimSpace(req.NewName) == "" {
		http.Error(w, "old_name and new_name required", http.StatusBadRequest)
		return
	}
	if err := s.Store.RenameTodoGroup(r.Context(), identity, req.ProjectID, req.OldName, req.NewName); err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// clearTodoGroup exposes Store.ClearTodoGroup over HTTP: bulk-clears
// group_name back to ungrouped on every todo currently in name (within the
// project_id scope, or personal when empty), without deleting them.
func (s *Server) clearTodoGroup(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	var req struct {
		ProjectID string `json:"project_id"`
		Name      string `json:"name"`
	}
	if err := decodeJSONBody(w, r, 4<<10, &req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(req.Name) == "" {
		http.Error(w, "name required", http.StatusBadRequest)
		return
	}
	if err := s.Store.ClearTodoGroup(r.Context(), identity, req.ProjectID, req.Name); err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// patchTodo decodes the body as map[string]json.RawMessage rather than a
// plain struct so it can tell "due_at key absent" (leave alone) apart from
// "due_at key present with JSON null" (clear) — a plain *time.Time field
// collapses both to nil. See store.TodoPatch.DueAt / store.OptionalTime.
func (s *Server) patchTodo(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	id := r.PathValue("id")

	raw := map[string]json.RawMessage{}
	if err := decodeJSONBody(w, r, 64<<10, &raw); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}

	var patch store.TodoPatch
	if v, ok := raw["title"]; ok {
		var val string
		if err := json.Unmarshal(v, &val); err != nil {
			http.Error(w, "invalid title", http.StatusBadRequest)
			return
		}
		patch.Title = &val
	}
	if v, ok := raw["body_md"]; ok {
		var val string
		if err := json.Unmarshal(v, &val); err != nil {
			http.Error(w, "invalid body_md", http.StatusBadRequest)
			return
		}
		patch.BodyMD = &val
	}
	if v, ok := raw["priority"]; ok {
		var val string
		if err := json.Unmarshal(v, &val); err != nil {
			http.Error(w, "invalid priority", http.StatusBadRequest)
			return
		}
		p := todoschema.Priority(val)
		if !todoschema.ValidPriority(p) {
			http.Error(w, "invalid priority", http.StatusBadRequest)
			return
		}
		patch.Priority = &p
	}
	if v, ok := raw["recurrence"]; ok {
		var val string
		if err := json.Unmarshal(v, &val); err != nil {
			http.Error(w, "invalid recurrence", http.StatusBadRequest)
			return
		}
		rec := todoschema.Recurrence(val)
		if !todoschema.ValidRecurrence(rec) {
			http.Error(w, "invalid recurrence", http.StatusBadRequest)
			return
		}
		patch.Recurrence = &rec
	}
	if v, ok := raw["due_at"]; ok {
		patch.DueAt.Set = true
		if string(v) != "null" {
			var val time.Time
			if err := json.Unmarshal(v, &val); err != nil {
				http.Error(w, "invalid due_at", http.StatusBadRequest)
				return
			}
			patch.DueAt.Value = &val
		}
	}
	if v, ok := raw["workspace_name"]; ok {
		var val string
		if err := json.Unmarshal(v, &val); err != nil {
			http.Error(w, "invalid workspace_name", http.StatusBadRequest)
			return
		}
		patch.WorkspaceName = &val
	}
	if v, ok := raw["repo_name"]; ok {
		var val string
		if err := json.Unmarshal(v, &val); err != nil {
			http.Error(w, "invalid repo_name", http.StatusBadRequest)
			return
		}
		patch.RepoName = &val
	}
	if v, ok := raw["group_name"]; ok {
		var val string
		if err := json.Unmarshal(v, &val); err != nil {
			http.Error(w, "invalid group_name", http.StatusBadRequest)
			return
		}
		patch.GroupName = &val
	}
	if v, ok := raw["source_provider"]; ok {
		var val string
		if err := json.Unmarshal(v, &val); err != nil {
			http.Error(w, "invalid source_provider", http.StatusBadRequest)
			return
		}
		patch.SourceProvider = &val
	}
	if v, ok := raw["source_team_key"]; ok {
		var val string
		if err := json.Unmarshal(v, &val); err != nil {
			http.Error(w, "invalid source_team_key", http.StatusBadRequest)
			return
		}
		patch.SourceTeamKey = &val
	}
	if v, ok := raw["source_project_id"]; ok {
		var val string
		if err := json.Unmarshal(v, &val); err != nil {
			http.Error(w, "invalid source_project_id", http.StatusBadRequest)
			return
		}
		patch.SourceProjectID = &val
	}
	if v, ok := raw["source_updated_at"]; ok {
		var val string
		if err := json.Unmarshal(v, &val); err != nil {
			http.Error(w, "invalid source_updated_at", http.StatusBadRequest)
			return
		}
		patch.SourceUpdatedAt = &val
	}
	if v, ok := raw["source_assignee_name"]; ok {
		var val string
		if err := json.Unmarshal(v, &val); err != nil {
			http.Error(w, "invalid source_assignee_name", http.StatusBadRequest)
			return
		}
		patch.SourceAssigneeName = &val
	}
	if v, ok := raw["source_assignee_avatar_url"]; ok {
		var val string
		if err := json.Unmarshal(v, &val); err != nil {
			http.Error(w, "invalid source_assignee_avatar_url", http.StatusBadRequest)
			return
		}
		patch.SourceAssigneeAvatarURL = &val
	}

	updated, err := s.Store.UpdateTodoFields(r.Context(), id, identity, patch)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	s.publishTodoEvent(r.Context(), sse.EventTypeTodoUpdated, updated)
	writeJSON(w, http.StatusOK, updated)
}

func (s *Server) setTodoStatus(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	id := r.PathValue("id")

	var req struct {
		Status string `json:"status"`
	}
	if err := decodeJSONBody(w, r, 4<<10, &req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	status := todoschema.Status(req.Status)
	if !todoschema.ValidStatus(status) {
		http.Error(w, "invalid status", http.StatusBadRequest)
		return
	}

	updated, err := s.Store.SetTodoStatus(r.Context(), id, identity, status)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	s.publishTodoEvent(r.Context(), sse.EventTypeTodoStatusChanged, updated)
	writeJSON(w, http.StatusOK, updated)
}

func (s *Server) assignTodo(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	id := r.PathValue("id")

	var req struct {
		AssigneeIdentity       string `json:"assignee_identity"`
		AssigneeSessionID      string `json:"assignee_session_id"`
		AssigneeSessionLabel   string `json:"assignee_session_label"`
		AssigneeAgentSessionID string `json:"assignee_agent_session_id"`
		AssigneeWorkdir        string `json:"assignee_workdir"`
		AssigneeAgentKind      string `json:"assignee_agent_kind"`
	}
	if r.ContentLength > 0 {
		if err := decodeJSONBody(w, r, 4<<10, &req); err != nil && !errors.Is(err, io.EOF) {
			http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
			return
		}
	}

	updated, err := s.Store.AssignTodo(r.Context(), id, identity, req.AssigneeIdentity, req.AssigneeSessionID, req.AssigneeSessionLabel,
		req.AssigneeAgentSessionID, req.AssigneeWorkdir, req.AssigneeAgentKind)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	s.publishTodoEvent(r.Context(), sse.EventTypeTodoAssigned, updated)
	writeJSON(w, http.StatusOK, updated)
}

// recurAdvanceTodo manually forces a due, recurring, done todo back to
// pending right now — a test/UX fallback for the once-a-minute sweep ticker
// (internal/relay/todo_recurrence.go). Store.ResetRecurringTodo is
// system-level and does no permission check by design (it's the sweep
// ticker's primitive), so this handler gates access itself by first calling
// UpdateTodoFields with an empty patch: that reuses the store's real
// edit-permission check (a read-only project viewer gets ErrForbidden here,
// same as any other edit) and returns the current row in one round trip,
// which also gives us Status/Recurrence to validate against before advancing.
func (s *Server) recurAdvanceTodo(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	id := r.PathValue("id")

	t, err := s.Store.UpdateTodoFields(r.Context(), id, identity, store.TodoPatch{})
	if err != nil {
		writeStoreError(w, err)
		return
	}
	if t.Status != todoschema.StatusDone || t.Recurrence == "" {
		http.Error(w, "todo is not a done, recurring todo", http.StatusConflict)
		return
	}

	updated, err := s.Store.ResetRecurringTodo(r.Context(), id, time.Now().UTC())
	if err != nil {
		writeStoreError(w, err)
		return
	}
	s.publishTodoEvent(r.Context(), sse.EventTypeTodoStatusChanged, updated)
	writeJSON(w, http.StatusOK, updated)
}

func (s *Server) deleteTodo(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	id := r.PathValue("id")

	// Fetch first so the SSE fan-out (and its target list, derived from
	// project_id/owner_identity) still has something to publish once the row
	// is gone.
	t, err := s.Store.GetTodo(r.Context(), id, identity)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	if err := s.Store.DeleteTodo(r.Context(), id, identity); err != nil {
		writeStoreError(w, err)
		return
	}
	s.publishTodoEvent(r.Context(), sse.EventTypeTodoDeleted, t)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) postTodoComment(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	id := r.PathValue("id")

	var req struct {
		Body string `json:"body"`
	}
	if err := decodeJSONBody(w, r, 64<<10, &req); err != nil {
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(req.Body) == "" {
		http.Error(w, "body required", http.StatusBadRequest)
		return
	}

	c, err := s.Store.InsertTodoComment(r.Context(), id, identity, req.Body)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	// The SSE contract is "payload is the full parent Todo" for every todo
	// event, comment_created included (so a list row's comment_count badge
	// updates in place) — InsertTodoComment only returns the Comment, so
	// re-fetch. Best-effort: a refetch failure shouldn't fail the request,
	// the comment is already persisted.
	if t, err := s.Store.GetTodo(r.Context(), id, identity); err == nil {
		s.publishTodoEvent(r.Context(), sse.EventTypeTodoCommentCreated, t)
	}
	writeJSON(w, http.StatusCreated, c)
}

func (s *Server) listTodoComments(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	comments, err := s.Store.ListTodoComments(r.Context(), r.PathValue("id"), identity)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"comments": comments})
}

// putTodoAttachment mirrors Server.putAttachment's raw-body +
// X-Content-Sha256 protocol exactly (same name validation, same
// handoff.AttachmentMaxBytes cap), scoped to a todo instead of a handoff.
func (s *Server) putTodoAttachment(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	id := r.PathValue("id")
	name := r.PathValue("name")
	if name == "" || name == "." || name == ".." ||
		name != filepath.Base(name) ||
		strings.ContainsAny(name, `/\`) {
		http.Error(w, "invalid attachment name", http.StatusBadRequest)
		return
	}

	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, handoff.AttachmentMaxBytes))
	if err != nil {
		http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
		return
	}
	sum := sha256.Sum256(body)
	hexSum := hex.EncodeToString(sum[:])

	if want := r.Header.Get("X-Content-Sha256"); want != "" && want != hexSum {
		http.Error(w, "sha256 mismatch", http.StatusBadRequest)
		return
	}

	if err := s.Store.PutTodoAttachment(r.Context(), id, identity, name, hexSum, body); err != nil {
		writeStoreError(w, err)
		return
	}
	if t, err := s.Store.GetTodo(r.Context(), id, identity); err == nil {
		s.publishTodoEvent(r.Context(), sse.EventTypeTodoUpdated, t)
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"name":   name,
		"sha256": hexSum,
		"size":   len(body),
	})
}

func (s *Server) getTodoAttachment(w http.ResponseWriter, r *http.Request) {
	identity := auth.Identity(r.Context())
	content, sum, _, err := s.Store.GetTodoAttachment(r.Context(), r.PathValue("id"), identity, r.PathValue("name"))
	if err != nil {
		writeStoreError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Content-Sha256", sum)
	_, _ = w.Write(content)
}

// todoTargets returns who a Todo event should fan out to: just the owner for
// a personal todo, or every effective realtime target for a team todo (direct
// project members plus team owners/admins). Targets are sourced live because
// membership can change independently of any one todo — unlike handoff fan-out,
// which targets a fixed recipient list captured at send time.
func (s *Server) todoTargets(ctx context.Context, t todoschema.Todo) []string {
	if t.IsPersonal() {
		if t.OwnerIdentity == "" {
			return nil
		}
		return []string{t.OwnerIdentity}
	}
	targets, err := s.Store.ListProjectTodoTargets(ctx, t.ProjectID)
	if err != nil {
		return nil
	}
	return targets
}

// publishTodoEvent fans a todo SSE event out to every target from
// todoTargets. The payload is always the complete Todo JSON (not just its
// id) — per the feature's SSE contract — so a subscriber can upsert its
// local copy in place instead of re-fetching the whole list.
func (s *Server) publishTodoEvent(ctx context.Context, eventType string, t todoschema.Todo) {
	if s.Hub == nil {
		return
	}
	targets := s.todoTargets(ctx, t)
	if len(targets) == 0 {
		return
	}
	data, err := json.Marshal(t)
	if err != nil {
		return
	}
	for _, rec := range targets {
		s.publishToActive(ctx, sse.Event{Type: eventType, Recipient: rec, Data: data})
	}
}
