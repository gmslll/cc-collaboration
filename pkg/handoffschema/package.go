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
	StatePending   State = "pending"
	StatePicked    State = "picked"
	StateExpired   State = "expired"
	StateRetracted State = "retracted"
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
	ModulePaths    []string        `json:"module_paths,omitempty"`
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

// ListItem is the compact form returned by GET /v1/handoffs?as=recipient
// (default) and GET /v1/handoffs?as=sender. Recipient is populated for sent
// listings; receivers can leave it empty since they already know they're
// the recipient.
type ListItem struct {
	ID        string    `json:"id"`
	Sender    string    `json:"sender"`
	Recipient string    `json:"recipient,omitempty"`
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

// Status is the response of GET /v1/handoffs/{id}/status — what callers
// (sender checking "did they read it?", agent checking before retract) need
// without re-fetching the full Package payload. CommentCount and LastComment
// are precomputed by the relay so clients don't N+1 a comments listing.
type Status struct {
	ID           string     `json:"id"`
	State        State      `json:"state"`
	Sender       string     `json:"sender"`
	Recipient    string     `json:"recipient"`
	CreatedAt    time.Time  `json:"created_at"`
	PickedAt     *time.Time `json:"picked_at,omitempty"`
	CommentCount int        `json:"comment_count"`
	LastComment  *Comment   `json:"last_comment,omitempty"`
}

// OnlineUser is one row in the GET /v1/users/online response: a known
// identity (drawn from the relay's token registry) plus a flag indicating
// whether it currently holds at least one active SSE subscription.
type OnlineUser struct {
	Identity string `json:"identity"`
	Online   bool   `json:"online"`
}

// RetractEvent is the payload of an EventTypeHandoffRetracted SSE event,
// pushed to the recipient when sender retracts. Reason is optional.
type RetractEvent struct {
	ID     string `json:"id"`
	Sender string `json:"sender"`
	Reason string `json:"reason,omitempty"`
}
