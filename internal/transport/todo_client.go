package transport

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/cc-collaboration/pkg/todoschema"
)

// CreateTodo posts a new todo. Caller sets Title (required) plus whichever
// of ProjectID/BodyMD/Priority/Recurrence/DueAt/AssigneeIdentity/
// AssigneeSessionID/AssigneeSessionLabel apply; the relay stamps
// OwnerIdentity from the bearer token and assigns ID/CreatedAt/UpdatedAt/
// Status itself (mirrors Submit's "server overrides sender+id+created_at"
// handling for handoffs — see server.go's submit handler), so those fields
// on the input are ignored. Returns the relay-assigned Todo.
func (c *Client) CreateTodo(ctx context.Context, t *todoschema.Todo) (*todoschema.Todo, error) {
	body, err := json.Marshal(t)
	if err != nil {
		return nil, err
	}
	var out todoschema.Todo
	if err := c.do(ctx, http.MethodPost, "/v1/todos", bytes.NewReader(body), &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// TodoListFilter is the query-string encoding of GET /v1/todos, mirroring
// store.TodoListFilter (internal/relay/store/todos.go) field-for-field.
type TodoListFilter struct {
	Scope     string // "personal" (default) | "project" | "assigned" | "all"
	ProjectID string // scope=project only; empty = union of every project the caller belongs to
	Status    string // optional exact-match filter
	Limit     int
}

// ListTodos returns todos visible to the caller under filter.
func (c *Client) ListTodos(ctx context.Context, f TodoListFilter) ([]todoschema.Todo, error) {
	var parts []string
	if f.Scope != "" {
		parts = append(parts, "scope="+f.Scope)
	}
	if f.ProjectID != "" {
		parts = append(parts, "project="+f.ProjectID)
	}
	if f.Status != "" {
		parts = append(parts, "status="+f.Status)
	}
	if f.Limit > 0 {
		parts = append(parts, "limit="+strconv.Itoa(f.Limit))
	}
	path := "/v1/todos"
	if len(parts) > 0 {
		path += "?" + strings.Join(parts, "&")
	}
	var out struct {
		Items []todoschema.Todo `json:"items"`
	}
	if err := c.do(ctx, http.MethodGet, path, nil, &out); err != nil {
		return nil, err
	}
	return out.Items, nil
}

// GetTodo returns a single todo by id, including its attachment metadata
// (the one place the wire Todo.Attachments is populated — see
// pkg/todoschema.Todo).
func (c *Client) GetTodo(ctx context.Context, id string) (*todoschema.Todo, error) {
	var out todoschema.Todo
	if err := c.do(ctx, http.MethodGet, "/v1/todos/"+id, nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// OptionalTime distinguishes "leave due_at alone" (Set=false) from
// "explicitly clear due_at" (Set=true, Value=nil) from "set due_at"
// (Set=true, Value=&t). Mirrors store.OptionalTime — see the PATCH
// null-vs-absent note in the feature plan: a JSON key that's simply absent
// means no change, but due_at needs a way to mean "send explicit null".
type OptionalTime struct {
	Set   bool
	Value *time.Time
}

// TodoPatch is the set of fields PatchTodo may update. A nil pointer for
// Title/BodyMD/Priority/Recurrence means "leave alone" — those fields are
// never sent as explicit null, only omitted or set. DueAt is the one field
// with true three-state semantics; see OptionalTime.
type TodoPatch struct {
	Title      *string
	BodyMD     *string
	Priority   *todoschema.Priority
	Recurrence *todoschema.Recurrence
	DueAt      OptionalTime
}

// PatchTodo applies a partial update to todo id. Only fields set on patch
// are sent to the relay at all; DueAt is the exception documented on
// OptionalTime. Returns the updated Todo.
func (c *Client) PatchTodo(ctx context.Context, id string, patch TodoPatch) (*todoschema.Todo, error) {
	fields := map[string]any{}
	if patch.Title != nil {
		fields["title"] = *patch.Title
	}
	if patch.BodyMD != nil {
		fields["body_md"] = *patch.BodyMD
	}
	if patch.Priority != nil {
		fields["priority"] = *patch.Priority
	}
	if patch.Recurrence != nil {
		fields["recurrence"] = *patch.Recurrence
	}
	if patch.DueAt.Set {
		fields["due_at"] = patch.DueAt.Value // nil marshals to JSON null; non-nil to a timestamp
	}
	body, err := json.Marshal(fields)
	if err != nil {
		return nil, err
	}
	var out todoschema.Todo
	if err := c.do(ctx, http.MethodPatch, "/v1/todos/"+id, bytes.NewReader(body), &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// SetTodoStatus transitions todo id to status. "Complete" is status=done —
// there's no separate complete endpoint. Returns the updated Todo.
func (c *Client) SetTodoStatus(ctx context.Context, id string, status todoschema.Status) (*todoschema.Todo, error) {
	payload, _ := json.Marshal(map[string]string{"status": string(status)})
	var out todoschema.Todo
	if err := c.do(ctx, http.MethodPost, "/v1/todos/"+id+"/status", bytes.NewReader(payload), &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// AssignTodo sets the assignee fields on todo id. Passing all six args
// empty clears the assignment. assigneeAgentSessionID/assigneeWorkdir/
// assigneeAgentKind are the permanent-resume trio (see
// pkg/todoschema.Todo) — pass them alongside assigneeSessionID when the
// target is a live agent session so "open the bound session" can respawn it
// with --resume long after the bus session id itself has gone stale.
// Returns the updated Todo.
func (c *Client) AssignTodo(ctx context.Context, id, assigneeIdentity, assigneeSessionID, assigneeSessionLabel, assigneeAgentSessionID, assigneeWorkdir, assigneeAgentKind string) (*todoschema.Todo, error) {
	payload, _ := json.Marshal(map[string]string{
		"assignee_identity":         assigneeIdentity,
		"assignee_session_id":       assigneeSessionID,
		"assignee_session_label":    assigneeSessionLabel,
		"assignee_agent_session_id": assigneeAgentSessionID,
		"assignee_workdir":          assigneeWorkdir,
		"assignee_agent_kind":       assigneeAgentKind,
	})
	var out todoschema.Todo
	if err := c.do(ctx, http.MethodPost, "/v1/todos/"+id+"/assign", bytes.NewReader(payload), &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// RecurAdvanceTodo manually forces the recurrence sweep's effect on todo id
// right now (test/UX fallback for the once-a-minute ticker in
// internal/relay/todo_recurrence.go). No-op if the todo isn't a done,
// recurring todo with an elapsed next_occurrence_at. Returns the updated Todo.
func (c *Client) RecurAdvanceTodo(ctx context.Context, id string) (*todoschema.Todo, error) {
	var out todoschema.Todo
	if err := c.do(ctx, http.MethodPost, "/v1/todos/"+id+"/recur-advance", nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// DeleteTodo removes todo id.
func (c *Client) DeleteTodo(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodDelete, "/v1/todos/"+id, nil, nil)
}

// CommentTodo posts a comment on todo id.
func (c *Client) CommentTodo(ctx context.Context, id, body string) (*todoschema.Comment, error) {
	payload, _ := json.Marshal(map[string]string{"body": body})
	var out todoschema.Comment
	if err := c.do(ctx, http.MethodPost, "/v1/todos/"+id+"/comment", bytes.NewReader(payload), &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// ListTodoComments returns every comment on todo id, oldest-first.
func (c *Client) ListTodoComments(ctx context.Context, id string) ([]todoschema.Comment, error) {
	var out struct {
		Comments []todoschema.Comment `json:"comments"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/todos/"+id+"/comments", nil, &out); err != nil {
		return nil, err
	}
	return out.Comments, nil
}

// UploadTodoAttachment posts raw bytes for an attachment on todo id. Mirrors
// UploadAttachment's raw-body + X-Content-Sha256 protocol exactly — todo
// attachments reuse the handoff attachment byte protocol byte-for-byte (see
// the feature plan).
func (c *Client) UploadTodoAttachment(ctx context.Context, todoID, name string, content []byte) error {
	url := c.BaseURL + "/v1/todos/" + todoID + "/attachments/" + name
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(content))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	req.Header.Set("Content-Type", "application/octet-stream")
	sum := sha256.Sum256(content)
	req.Header.Set("X-Content-Sha256", hex.EncodeToString(sum[:]))
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		return fmt.Errorf("relay POST todo attachment %s: %s: %s", name, resp.Status, strings.TrimSpace(string(b)))
	}
	return nil
}

// FetchTodoAttachment returns the raw bytes for a todo attachment, verifying
// the relay-supplied SHA256 if present. Returns ErrAttachmentNotFound on
// 404 — the same sentinel FetchAttachment uses for handoffs, since it means
// the same thing either way: the parent resource exists but doesn't carry
// an attachment with that name.
func (c *Client) FetchTodoAttachment(ctx context.Context, todoID, name string) ([]byte, error) {
	url := c.BaseURL + "/v1/todos/" + todoID + "/attachments/" + name
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, ErrAttachmentNotFound
	}
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		return nil, fmt.Errorf("relay GET todo attachment %s: %s: %s", name, resp.Status, strings.TrimSpace(string(b)))
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if want := resp.Header.Get("X-Content-Sha256"); want != "" {
		got := sha256.Sum256(body)
		if hex.EncodeToString(got[:]) != want {
			return nil, fmt.Errorf("todo attachment %s sha256 mismatch", name)
		}
	}
	return body, nil
}
