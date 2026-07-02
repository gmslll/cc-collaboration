// Package todoschema defines the wire types for the Todo feature: a
// relay-native sibling entity to handoffschema.Package (see internal/relay
// and internal/relay/store/todos.go). Personal todos have an empty
// ProjectID; team todos are scoped to a Project and follow its member
// roles (see internal/relay/store/projects.go RoleOwner/RoleMember/RoleViewer).
package todoschema

import "time"

const SchemaVersion = 1

// Status is a todo's current lifecycle stage. Unlike handoffschema.State
// (an append-only per-recipient state machine), Status is freely mutable in
// place by anyone with edit rights.
type Status string

const (
	StatusPending    Status = "pending"
	StatusAssigned   Status = "assigned"
	StatusInProgress Status = "in_progress"
	StatusBlocked    Status = "blocked"
	StatusDone       Status = "done"
	StatusCancelled  Status = "cancelled"
)

// ValidStatus reports whether s is one of the known Status values.
func ValidStatus(s Status) bool {
	switch s {
	case StatusPending, StatusAssigned, StatusInProgress, StatusBlocked, StatusDone, StatusCancelled:
		return true
	}
	return false
}

type Priority string

const (
	PriorityLow    Priority = "low"
	PriorityNormal Priority = "normal"
	PriorityHigh   Priority = "high"
)

// ValidPriority reports whether p is one of the known Priority values.
func ValidPriority(p Priority) bool {
	switch p {
	case PriorityLow, PriorityNormal, PriorityHigh:
		return true
	}
	return false
}

// Recurrence is the real time-based repeat interval ("" means one-shot).
// This is distinct from Status, which covers the lifecycle-stage sense of
// "recurring" work discussed in the feature plan.
type Recurrence string

const (
	RecurrenceNone    Recurrence = ""
	RecurrenceDaily   Recurrence = "daily"
	RecurrenceWeekly  Recurrence = "weekly"
	RecurrenceMonthly Recurrence = "monthly"
)

// ValidRecurrence reports whether r is one of the known Recurrence values.
func ValidRecurrence(r Recurrence) bool {
	switch r {
	case RecurrenceNone, RecurrenceDaily, RecurrenceWeekly, RecurrenceMonthly:
		return true
	}
	return false
}

// AddInterval advances t by one period of r. Called once, at the moment a
// todo's status flips to done, to compute NextOccurrenceAt — see the
// recurrence semantics note in the feature plan (relative-to-completion,
// not wall-clock-anchored, so an in-progress/blocked todo is never
// force-reset out from under whoever is working it).
func (r Recurrence) AddInterval(t time.Time) time.Time {
	switch r {
	case RecurrenceDaily:
		return t.AddDate(0, 0, 1)
	case RecurrenceWeekly:
		return t.AddDate(0, 0, 7)
	case RecurrenceMonthly:
		return t.AddDate(0, 1, 0)
	default:
		return t
	}
}

// Todo is the wire representation of one todo item. Field names are the
// frozen contract other tracks (HTTP handler, MCP tools, CLI, Flutter
// client) build against — see the "统一 API 契约" section of the feature
// plan; do not rename.
type Todo struct {
	ID                   string     `json:"id"`
	ProjectID            string     `json:"project_id,omitempty"` // empty = personal todo
	OwnerIdentity        string     `json:"owner_identity"`
	Title                string     `json:"title"`
	BodyMD               string     `json:"body_md,omitempty"`
	Status               Status     `json:"status"`
	Priority             Priority   `json:"priority"`
	AssigneeIdentity     string     `json:"assignee_identity,omitempty"`
	AssigneeSessionID    string     `json:"assignee_session_id,omitempty"`
	AssigneeSessionLabel string     `json:"assignee_session_label,omitempty"`
	Recurrence           Recurrence `json:"recurrence,omitempty"`
	DueAt                *time.Time `json:"due_at,omitempty"`
	NextOccurrenceAt     *time.Time `json:"next_occurrence_at,omitempty"`
	CreatedAt            time.Time  `json:"created_at"`
	UpdatedAt            time.Time  `json:"updated_at"`
	CompletedAt          *time.Time `json:"completed_at,omitempty"`
	CommentCount         int        `json:"comment_count"`
	AttachmentCount      int        `json:"attachment_count"`
	// Attachments is populated only by GET-by-id (Store.GetTodo); list
	// endpoints/queries (Store.ListTodos) leave it nil and rely on
	// AttachmentCount so a list row can show a thumbnail/badge without an
	// N+1 join.
	Attachments []Attachment `json:"attachments,omitempty"`
}

// IsPersonal reports whether t is a personal (not project-scoped) todo.
func (t Todo) IsPersonal() bool { return t.ProjectID == "" }

// Attachment is metadata for a binary blob stored alongside a todo. The
// bytes are uploaded/fetched via
// /v1/todos/{id}/attachments/{name} (mirrors handoffschema.Attachment /
// the handoff attachment byte protocol exactly).
type Attachment struct {
	Name      string    `json:"name"`
	SHA256    string    `json:"sha256"`
	Size      int       `json:"size"`
	CreatedAt time.Time `json:"created_at"`
}

// Comment is a back-channel message attached to a todo. Any identity with
// comment rights on the todo (see internal/relay/store/todos.go
// todoPermission) can post.
type Comment struct {
	ID             int64     `json:"id"`
	TodoID         string    `json:"todo_id"`
	AuthorIdentity string    `json:"author_identity"`
	Body           string    `json:"body"`
	CreatedAt      time.Time `json:"created_at"`
}
