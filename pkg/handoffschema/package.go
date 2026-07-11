package handoffschema

import (
	"strings"
	"time"
)

const SchemaVersion = 1

type Urgency string

const (
	UrgencyNormal Urgency = "normal"
	UrgencyUrgent Urgency = "urgent"
)

type State string

const (
	StatePending    State = "pending"
	StatePicked     State = "picked"
	StateExpired    State = "expired"
	StateRetracted  State = "retracted"
	StateReassigned State = "reassigned" // per-recipient slot only; the parent handoff stays "picked" once every slot is terminal
)

// Kind distinguishes the direction/intent of a Package. Default (empty/
// "delivery") is the original /handoff flow: sender finished work and is
// shipping a diff/contract for the recipient to integrate. "request" is the
// reverse flow: sender (typically frontend) is asking the recipient
// (typically backend) to add/change something, with no diff to ship — the
// summary describes what's missing and why. "bug" is a tester-originated
// report sent to one or both engineering sides simultaneously, with a
// decision tree at pickup time (fix it / reassign to the other side / pull
// the other side into the discussion). "capsule" is a frozen session context
// snapshot shared to a team (relay Project): the payload carries a session's
// transcript and/or a distilled role so a teammate can launch a specialized
// session from it — the Capsule field describes which forms are present.
type Kind string

const (
	KindDelivery Kind = "delivery"
	KindRequest  Kind = "request"
	KindBug      Kind = "bug"
	KindCapsule  Kind = "capsule"
)

// Reserved attachment names for KindCapsule payloads. The bytes ride through
// the ordinary Package.Attachments channel (upload/download + sha256 integrity);
// these constants let the builder, materializer and receiver agree on the slot
// each payload lands in. Kept here in handoffschema (no deps) so both the
// handoff builder and the inbox materializer can reference them without a cycle.
const (
	// CapsuleTranscriptJSONLName is the raw source-session log (claude .jsonl /
	// codex rollout). Only usable for a native --resume when the receiver
	// launches the SAME tool on a compatible version.
	CapsuleTranscriptJSONLName = "transcript.jsonl"
	// CapsuleTranscriptTextName is the neutral text rendering of the same log,
	// portable across tools/machines as a seed prompt (claude↔codex).
	CapsuleTranscriptTextName = "transcript.txt"
	// CapsulePersonaName is the distilled reusable role (tool-agnostic markdown).
	CapsulePersonaName = "persona.md"
	// CapsuleSeedName is a compacted context summary, the fallback seed when the
	// full neutral transcript is too long.
	CapsuleSeedName = "seed.md"
	// CapsuleSkillPackSuffix marks an attachment that bundles a local skill /
	// script directory (zipped) the capsule's work depends on, so a teammate on
	// a machine without that skill still gets it. Named "<skill>.skillpack.zip";
	// unpacked into the receiver's skills dir on load.
	CapsuleSkillPackSuffix = ".skillpack.zip"
)

// CapsuleVisibility controls who can see a capsule in the plaza. Default
// (empty) is treated as private.
type CapsuleVisibility = string

const (
	// CapsulePrivate (个人) — only the owner sees it in the plaza.
	CapsulePrivate CapsuleVisibility = "private"
	// CapsulePublic (公开) — visible to the whole team via the plaza.
	CapsulePublic CapsuleVisibility = "public"
)

// IsCapsuleSkillPack reports whether name is a bundled skill/script pack.
func IsCapsuleSkillPack(name string) bool {
	return strings.HasSuffix(name, CapsuleSkillPackSuffix)
}

// IsReservedCapsuleAttachment reports whether name is one of the structural
// capsule payload slots (rendered specially, not listed in the generic
// attachments section) — the fixed payloads plus any bundled skill pack.
func IsReservedCapsuleAttachment(name string) bool {
	switch name {
	case CapsuleTranscriptJSONLName, CapsuleTranscriptTextName, CapsulePersonaName, CapsuleSeedName:
		return true
	}
	return IsCapsuleSkillPack(name)
}

// EffectiveKind returns the package's Kind, defaulting an empty value to
// KindDelivery so older payloads (no kind field) keep their original
// integration-style behavior.
func (p *Package) EffectiveKind() Kind {
	if p.Kind == "" {
		return KindDelivery
	}
	return p.Kind
}

// CapsuleOrEmpty returns p.Capsule, or a pointer to a zero Capsule when nil, so
// capsule renderers don't each repeat the same nil guard.
func (p *Package) CapsuleOrEmpty() *Capsule {
	if p.Capsule != nil {
		return p.Capsule
	}
	return &Capsule{}
}

// Headline is the first line of SummaryMD — the compact one-liner every
// list/notice/plaza projection shows.
func (p *Package) Headline() string {
	headline, _, _ := strings.Cut(p.SummaryMD, "\n")
	return headline
}

// RequiresRecipient reports whether a package must name a recipient. Every kind
// does except capsules, which go to the visibility-keyed plaza, not an inbox.
func (p *Package) RequiresRecipient() bool {
	return p.EffectiveKind() != KindCapsule
}

// CapsuleVisibleTo reports the package-local visibility rule: public capsules
// pass, private capsules are owner-only. Relay/store code layers team
// reachability on top; use Store.CapsuleVisibleTo for tenant-scoped checks.
func (p *Package) CapsuleVisibleTo(viewer string) bool {
	return p.CapsuleOrEmpty().EffectiveVisibility() == CapsulePublic || p.Sender == viewer
}

// ParseCapsuleVisibility normalizes a visibility string to the enum, defaulting
// anything but "public" to private. One place for the string→enum rule.
func ParseCapsuleVisibility(s string) CapsuleVisibility {
	if s == CapsulePublic {
		return CapsulePublic
	}
	return CapsulePrivate
}

// ApplyCapsuleEdit mutates a capsule package's editable metadata in place —
// visibility and/or summary (nil = unchanged), ensuring Capsule is non-nil so
// callers (the store) needn't know the payload's shape.
func (p *Package) ApplyCapsuleEdit(visibility, summary *string) {
	if p.Capsule == nil {
		p.Capsule = &Capsule{}
	}
	if visibility != nil {
		p.Capsule.Visibility = ParseCapsuleVisibility(*visibility)
	}
	if summary != nil {
		p.SummaryMD = *summary
	}
}

// EffectiveRecipients returns the recipient list. For bug-kind packages this
// is the multi-recipient array; for legacy delivery/request packages with a
// single Recipient it wraps that scalar into a single-element slice so all
// callers can iterate uniformly.
func (p *Package) EffectiveRecipients() []string {
	if len(p.Recipients) > 0 {
		return DedupeIdentities(p.Recipients)
	}
	if p.Recipient != "" {
		return DedupeIdentities([]string{p.Recipient})
	}
	return nil
}

type Package struct {
	ID             string          `json:"id"`
	SchemaVersion  int             `json:"schema_version"`
	Kind           Kind            `json:"kind,omitempty"`
	Sender         string          `json:"sender"`
	Recipient      string          `json:"recipient"`
	Recipients     []string        `json:"recipients,omitempty"`
	Urgency        Urgency         `json:"urgency"`
	CreatedAt      time.Time       `json:"created_at"`
	Repo           Repo            `json:"repo"`
	SummaryMD      string          `json:"summary_md"`
	Git            *Git            `json:"git,omitempty"`
	APIDelta       *APIDelta       `json:"api_delta,omitempty"`
	ModulePaths    []string        `json:"module_paths,omitempty"`
	TargetingHints []TargetingHint `json:"targeting_hints,omitempty"`
	// DeliveryTarget records the user's team delivery intent before it was
	// expanded into concrete Recipients. It lets receivers distinguish a
	// project/org/member-scoped package from an ordinary multi-recipient send.
	DeliveryTarget *DeliveryTarget `json:"delivery_target,omitempty"`
	Attachments    []Attachment    `json:"attachments,omitempty"`
	NoteMD         string          `json:"note_md,omitempty"`
	PrdMD          string          `json:"prd_md,omitempty"`
	AmendsHandoff  string          `json:"amends_handoff,omitempty"`
	RespondsTo     string          `json:"responds_to,omitempty"`
	// BugGroupID links the original bug handoff and any handoffs produced by
	// reassign_bug from it. Empty on non-bug packages. Comment broadcast uses
	// it to sync conversation across the whole reassign chain so tester +
	// every side that ever touched the bug stays in the loop.
	BugGroupID string `json:"bug_group_id,omitempty"`
	// OriginalSender is the identity that filed the bug. For the first bug
	// in a chain it equals Sender; on a reassigned bug the relay sets Sender
	// to whichever side did the reassign but OriginalSender stays as the
	// tester so the receiver knows where the report ultimately came from.
	OriginalSender string `json:"original_sender,omitempty"`
	// ReassignedFrom is the handoff id this bug was forwarded from (the
	// previous recipient called reassign_bug). Empty on the original bug.
	ReassignedFrom string `json:"reassigned_from,omitempty"`
	// ReassignedReason is the explanation the reassigning side gave for
	// passing the bug along ("this is a frontend issue because …"). Renders
	// as a banner in the bug prompt template.
	ReassignedReason string `json:"reassigned_reason,omitempty"`
	// Capsule carries session-capsule metadata (KindCapsule only). The payload
	// bytes ride as Attachments under the reserved capsule names; this records
	// the source tool, origin session id, team scope, and which forms are
	// present so the receiver's loader can pick a reconstruction path.
	Capsule *Capsule `json:"capsule,omitempty"`
}

type DeliveryTarget struct {
	ProjectID string `json:"project_id,omitempty"`
	OrgID     string `json:"org_id,omitempty"`
	Member    string `json:"member,omitempty"`
}

// Capsule is the metadata for a KindCapsule package — a frozen session context
// shared to a team so a teammate can spin up a specialized session from it. The
// actual payloads (transcript.jsonl / transcript.txt / persona.md / seed.md)
// ride as Package.Attachments under the reserved Capsule*Name constants; this
// struct only records how to reconstruct them on the far end.
type Capsule struct {
	// SourceAgent is the agent tool the capsule was captured from ("claude" or
	// "codex"). The loader compares it to the receiver's chosen target tool: a
	// match permits a native --resume (same tool + same machine + compatible
	// version); a mismatch forces the neutral-transcript seed path.
	SourceAgent string `json:"source_agent"`
	// OriginSessionID is the capture-side agent session id (claude uuid / codex
	// rollout id). Only meaningful for same-tool same-machine native resume.
	OriginSessionID string `json:"origin_session_id,omitempty"`
	// Visibility controls plaza reach: "private" (个人, owner-only) or "public"
	// (公开, visible to the team). Empty is treated as private.
	Visibility CapsuleVisibility `json:"visibility,omitempty"`
	// ProjectID scopes a public capsule to one relay project. Older capsules
	// have no value and retain visibility only in legacy flat-roster deployments.
	ProjectID string `json:"project_id,omitempty"`
	// HasTranscript is true when a transcript payload (raw and/or neutral text)
	// is present, so the pickup UI can offer the "① full snapshot" form.
	HasTranscript bool `json:"has_transcript,omitempty"`
	// HasPersona is true when a distilled persona payload is present, so the
	// pickup UI can offer the "② distilled role" form.
	HasPersona bool `json:"has_persona,omitempty"`
	// UpdatedAt tracks the last metadata edit (summary / visibility). Capsules
	// created before this field was added fall back to Package.CreatedAt in the
	// plaza projection.
	UpdatedAt time.Time `json:"updated_at,omitempty"`
}

// EffectiveVisibility returns the capsule's visibility, defaulting empty to
// private so a capsule is never accidentally public.
func (c *Capsule) EffectiveVisibility() CapsuleVisibility {
	if c.Visibility == CapsulePublic {
		return CapsulePublic
	}
	return CapsulePrivate
}

// CapsuleListItem is the compact plaza row (GET /v1/capsules): enough to render
// a browsable capsule gallery without fetching each full Package.
type CapsuleListItem struct {
	ID          string            `json:"id"`
	Owner       string            `json:"owner"`
	Visibility  CapsuleVisibility `json:"visibility"`
	SourceAgent string            `json:"source_agent"`
	ProjectID   string            `json:"project_id,omitempty"`
	// OriginSessionID is the capture-side session id — the filename id a
	// same-tool native --resume writes the imported transcript under.
	OriginSessionID string    `json:"origin_session_id,omitempty"`
	HasTranscript   bool      `json:"has_transcript"`
	HasPersona      bool      `json:"has_persona"`
	SkillPackCount  int       `json:"skill_pack_count"`
	Headline        string    `json:"headline,omitempty"`
	Summary         string    `json:"summary,omitempty"`
	RepoName        string    `json:"repo_name,omitempty"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

// NewCapsuleListItem projects a stored capsule Package into its plaza row.
func NewCapsuleListItem(p *Package) CapsuleListItem {
	c := p.CapsuleOrEmpty()
	updatedAt := c.UpdatedAt
	if updatedAt.IsZero() {
		updatedAt = p.CreatedAt
	}
	skillPackCount := 0
	for _, attachment := range p.Attachments {
		if IsCapsuleSkillPack(attachment.Name) {
			skillPackCount++
		}
	}
	return CapsuleListItem{
		ID:              p.ID,
		Owner:           p.Sender,
		Visibility:      c.EffectiveVisibility(),
		SourceAgent:     c.SourceAgent,
		ProjectID:       c.ProjectID,
		OriginSessionID: c.OriginSessionID,
		HasTranscript:   c.HasTranscript,
		HasPersona:      c.HasPersona,
		SkillPackCount:  skillPackCount,
		Headline:        p.Headline(),
		Summary:         p.SummaryMD,
		RepoName:        p.Repo.Name,
		CreatedAt:       p.CreatedAt,
		UpdatedAt:       updatedAt,
	}
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
	Format   string          `json:"format"`
	Added    []Operation     `json:"added,omitempty"`
	Changed  []Operation     `json:"changed,omitempty"`
	Removed  []Operation     `json:"removed,omitempty"`
	Servers  *StringListDiff `json:"servers,omitempty"`
	Security *StringListDiff `json:"security,omitempty"`
}

type Operation struct {
	Method      string           `json:"method"`
	Path        string           `json:"path"`
	OperationID string           `json:"operation_id,omitempty"`
	Summary     string           `json:"summary,omitempty"`
	Detail      *OperationDetail `json:"detail,omitempty"`
}

// OperationDetail carries field-level diff information for a single operation.
// Populated only when an older "Changed/Added/Removed" entry needs more than
// method+path to be actionable; older payloads leave Detail nil and the
// receiver falls back to the operation-level rendering.
type OperationDetail struct {
	Parameters  *SchemaDiff                `json:"parameters,omitempty"`
	RequestBody *SchemaDiff                `json:"request_body,omitempty"`
	Responses   map[string]*ResponseDetail `json:"responses,omitempty"`
	ErrorCodes  *StatusCodeListDiff        `json:"error_codes,omitempty"`
	Security    *StringListDiff            `json:"security,omitempty"`
}

type ResponseDetail struct {
	Body    *SchemaDiff `json:"body,omitempty"`
	Headers *SchemaDiff `json:"headers,omitempty"`
}

type SchemaDiff struct {
	Added   []FieldRef    `json:"added,omitempty"`
	Removed []FieldRef    `json:"removed,omitempty"`
	Changed []FieldChange `json:"changed,omitempty"`
}

// FieldRef is one entry in a SchemaDiff. Path uses dotted property names with
// "[]" appended for array element traversal — e.g. "address.city",
// "items[].name", "headers.X-Trace-Id".
type FieldRef struct {
	Path     string   `json:"path"`
	Type     string   `json:"type,omitempty"`
	Format   string   `json:"format,omitempty"`
	Required bool     `json:"required,omitempty"`
	Enum     []string `json:"enum,omitempty"`
	Nullable bool     `json:"nullable,omitempty"`
}

type FieldChange struct {
	Path   string   `json:"path"`
	Before FieldRef `json:"before"`
	After  FieldRef `json:"after"`
	Reason string   `json:"reason,omitempty"`
}

type StatusCodeListDiff struct {
	Added   []string `json:"added,omitempty"`
	Removed []string `json:"removed,omitempty"`
}

type StringListDiff struct {
	Added   []string `json:"added,omitempty"`
	Removed []string `json:"removed,omitempty"`
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
// the recipient. Recipients (multi) and BugGroupID surface multi-recipient
// bug context for tester's `?as=sender` view without a second roundtrip.
type ListItem struct {
	ID         string    `json:"id"`
	Kind       Kind      `json:"kind,omitempty"`
	Sender     string    `json:"sender"`
	Recipient  string    `json:"recipient,omitempty"`
	Recipients []string  `json:"recipients,omitempty"`
	Urgency    Urgency   `json:"urgency"`
	State      State     `json:"state"`
	CreatedAt  time.Time `json:"created_at"`
	RepoName   string    `json:"repo_name"`
	Branch     string    `json:"branch,omitempty"`
	Headline   string    `json:"headline,omitempty"`
	BugGroupID string    `json:"bug_group_id,omitempty"`
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
// For bug handoffs PickupBy is populated per recipient (state pending /
// picked / reassigned) so the tester can see "backend picked it up but
// frontend hasn't even read it yet" without listing comments.
type Status struct {
	ID           string                     `json:"id"`
	State        State                      `json:"state"`
	Sender       string                     `json:"sender"`
	Recipient    string                     `json:"recipient"`
	Recipients   []string                   `json:"recipients,omitempty"`
	CreatedAt    time.Time                  `json:"created_at"`
	PickedAt     *time.Time                 `json:"picked_at,omitempty"`
	PickupBy     map[string]RecipientStatus `json:"pickup_by,omitempty"`
	CommentCount int                        `json:"comment_count"`
	LastComment  *Comment                   `json:"last_comment,omitempty"`
	BugGroupID   string                     `json:"bug_group_id,omitempty"`
}

// RecipientStatus is one entry in Status.PickupBy: per-recipient slot state
// (pending / picked / reassigned) and the timestamp the slot last changed.
type RecipientStatus struct {
	State    State      `json:"state"`
	PickedAt *time.Time `json:"picked_at,omitempty"`
}

// DedupeIdentities preserves first-seen order, drops empty entries and
// duplicates. Shared helper for normalizing recipient lists from user input
// (TOML `identity.partners`, MCP `submit_bug.to`).
func DedupeIdentities(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		if _, ok := seen[s]; ok {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	return out
}

// NoticeListItem builds the compact ListItem the relay publishes via SSE on
// handoff.created. Mirrors the columns the relay's denormalized list query
// returns so a watch client sees the same shape whether it came from
// /v1/handoffs or events.
func NoticeListItem(p *Package, state State) ListItem {
	return ListItem{
		ID:         p.ID,
		Kind:       p.Kind,
		Sender:     p.Sender,
		Recipients: p.Recipients,
		Urgency:    p.Urgency,
		State:      state,
		CreatedAt:  p.CreatedAt,
		RepoName:   p.Repo.Name,
		Branch:     p.Repo.Branch,
		Headline:   p.Headline(),
		BugGroupID: p.BugGroupID,
	}
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

// LogAlert is the payload of a log.alert event and the body of POST /v1/alerts.
// A server-side error hook forwards it (via `cc-handoff alert` or a raw curl)
// to a teammate's watch, which writes it as a triage prompt and — when
// auto_launch_on_alert is set — launches the agent in the named project.
type LogAlert struct {
	// Recipient is the target identity whose watch should surface this. The
	// relay fans the event out to that identity's subscribers.
	Recipient string `json:"recipient"`
	// Project is the workspace project name the receiver resolves to a local
	// directory (so watch knows where to launch the agent). Empty is allowed —
	// the receiver then only notifies, without a project to launch in.
	Project string `json:"project,omitempty"`
	// Level is a free-form severity tag for the notification subtitle
	// (e.g. "error", "fatal"). Optional.
	Level string `json:"level,omitempty"`
	// Message is the log body / excerpt to triage.
	Message string `json:"message"`
	// Sender is set server-side from the authenticated identity; clients don't
	// supply it.
	Sender string `json:"sender,omitempty"`
}

// SessionInfo is one open terminal session an app publishes to the relay so a
// peer can target a specific remote session (POST /v1/sessions). Transient
// presence-level data — the relay holds it in memory with a TTL, not the DB.
type SessionInfo struct {
	ID        string `json:"id"`                   // the app's local session id (e.g. ts0)
	Label     string `json:"label"`                // human label (name or derived title)
	Project   string `json:"project,omitempty"`    // owning project name, for grouping
	ProjectID string `json:"project_id,omitempty"` // relay project id, for exact team scoping
	Workdir   string `json:"workdir,omitempty"`    // session working dir
}

// Message is a short text sent to a specific session on another user's machine
// (POST /v1/messages). Delivered transiently as a message.deliver SSE event;
// the recipient's app confirms before injecting it. From is stamped server-side
// from the token.
type Message struct {
	Recipient string `json:"recipient,omitempty"`  // target identity (request only)
	SessionID string `json:"session_id,omitempty"` // target session id on the recipient
	Body      string `json:"body"`                 // the text to deliver
	From      string `json:"from,omitempty"`       // sender identity (server-set)
	Project   string `json:"project,omitempty"`    // target session's project name context
	ProjectID string `json:"project_id,omitempty"` // target session's relay project id
}
