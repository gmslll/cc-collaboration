package handoffschema

import "time"

const SchemaVersion = 1

type Urgency string

const (
	UrgencyNormal Urgency = "normal"
	UrgencyUrgent Urgency = "urgent"
)

type State string

const (
	StatePending State = "pending"
	StatePicked  State = "picked"
	StateExpired State = "expired"
)

type Package struct {
	ID             string          `json:"id"`
	SchemaVersion  int             `json:"schema_version"`
	Sender         string          `json:"sender"`
	Recipient      string          `json:"recipient"`
	Urgency        Urgency         `json:"urgency"`
	CreatedAt      time.Time       `json:"created_at"`
	Repo           Repo            `json:"repo"`
	SummaryMD      string          `json:"summary_md"`
	Git            *Git            `json:"git,omitempty"`
	APIDelta       *APIDelta       `json:"api_delta,omitempty"`
	TargetingHints []TargetingHint `json:"targeting_hints,omitempty"`
	Attachments    []Attachment    `json:"attachments,omitempty"`
	NoteMD         string          `json:"note_md,omitempty"`
	ReplacesID     string          `json:"replaces_id,omitempty"`
}

// Attachment is metadata for a binary blob stored on the relay alongside the
// package (e.g. a full git diff that exceeded the inline-diff threshold).
// The actual bytes are uploaded/fetched via /v1/handoffs/{id}/attachments/{name}.
type Attachment struct {
	Name   string `json:"name"`   // file name as it should land in attachments/<name>
	SHA256 string `json:"sha256"` // hex digest, used for integrity check on fetch
	Size   int    `json:"size"`   // bytes
}

type Repo struct {
	Name    string `json:"name"`
	Branch  string `json:"branch,omitempty"`
	HeadSHA string `json:"head_sha,omitempty"`
	BaseSHA string `json:"base_sha,omitempty"`
}

type Git struct {
	Commits      []Commit `json:"commits,omitempty"`
	ChangedPaths []string `json:"changed_paths,omitempty"`
}

type Commit struct {
	SHA     string `json:"sha"`
	Subject string `json:"subject"`
	Body    string `json:"body,omitempty"`
}

type APIDelta struct {
	Format  string      `json:"format"`
	Added   []Operation `json:"added,omitempty"`
	Changed []Operation `json:"changed,omitempty"`
	Removed []Operation `json:"removed,omitempty"`
}

type Operation struct {
	Method      string `json:"method"`
	Path        string `json:"path"`
	OperationID string `json:"operation_id,omitempty"`
	Summary     string `json:"summary,omitempty"`
}

type TargetingHint struct {
	Reason        string            `json:"reason"`
	MatchedPath   string            `json:"matched_path,omitempty"`
	Captures      map[string]string `json:"captures,omitempty"`
	SuggestEdit   []string          `json:"suggest_edit,omitempty"`
	SuggestCreate []string          `json:"suggest_create,omitempty"`
}

// ListItem is the compact form returned by GET /v1/handoffs?recipient=X.
type ListItem struct {
	ID        string    `json:"id"`
	Sender    string    `json:"sender"`
	Urgency   Urgency   `json:"urgency"`
	State     State     `json:"state"`
	CreatedAt time.Time `json:"created_at"`
	RepoName  string    `json:"repo_name"`
	Branch    string    `json:"branch,omitempty"`
	Headline  string    `json:"headline,omitempty"`
}

// Comment is a back-channel message attached to a handoff. Either sender or
// recipient can post; the relay pushes a comment.created SSE event to the
// other party.
type Comment struct {
	ID        int64     `json:"id"`
	HandoffID string    `json:"handoff_id"`
	Sender    string    `json:"sender"`
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"created_at"`
}
