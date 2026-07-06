package handoff

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/rules"
	"github.com/cc-collaboration/internal/sources/git"
	"github.com/cc-collaboration/internal/sources/swagger"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// SwaggerSnapshotName is the attachment filename used to ship the current
// OpenAPI spec alongside a handoff. Receivers find it under
// `<inbox>/<id>/attachments/swagger.yaml` after pickup; downstream tooling
// (cc-handoff check-drift, etc.) reads from a stable name.
const SwaggerSnapshotName = "swagger.yaml"

// AttachmentMaxBytes caps a single attachment's size. Enforced both
// client-side (MCP readAttachments fails fast before allocating bytes) and
// server-side (relay putAttachment via http.MaxBytesReader). Defined here so
// the two layers can never disagree.
const AttachmentMaxBytes = 50 << 20

type BuildOptions struct {
	RepoRoot  string
	RepoName  string
	Sender    string
	Recipient string
	// Recipients is the multi-recipient list used by KindBug. When set,
	// Recipient is ignored. For 2-party kinds (delivery / request) leave
	// this empty and use Recipient.
	Recipients  []string
	Urgency     handoffschema.Urgency
	Base        string
	Note        string
	Prd         string
	Rules       *rules.Engine
	SwaggerPath string             // optional, relative to RepoRoot
	ModulePaths []string           // module-brief mode: when set, skip git diff + swagger delta and treat summary as a self-contained API contract
	Kind        handoffschema.Kind // empty defaults to KindDelivery; KindRequest / KindBug skip git diff / swagger / rules (summary IS the body)
	RespondsTo  string             // on a delivery, the request id this answers (renders a banner on the receiver side)
	Amends      string             // on a delivery, the prior handoff id this delivery corrects/supersedes (renders a banner on the receiver side)
	// InboxDir is the absolute resolved inbox directory (caller computes via
	// inbox.InboxDir to apply the legacy / primary fallback). The draft
	// summary file lives here.
	InboxDir string
	// ExtraAttachments are caller-provided binary blobs keyed by the basename
	// they should land as on the receiver side (`<inbox>/<id>/attachments/<name>`).
	// Used by submit_bug for screenshots / HAR / logs, and by handoff/request
	// for design refs. Reserved names (currently `swagger.yaml`) are rejected
	// so user input can never shadow the auto-derived swagger snapshot.
	ExtraAttachments map[string][]byte
}

// SummaryDraftPath returns where the human-authored summary draft lives. The
// caller passes the resolved inbox dir; cc-handoff doesn't try to recompute
// it here to avoid a circular import (inbox → handoff already exists for
// ShortSHA).
func SummaryDraftPath(inboxDir string) string {
	return filepath.Join(inboxDir, ".draft-summary.md")
}

// BuildReassignment clones the metadata of `orig` into a fresh bug Package
// addressed to `to`, with the relay-side handler as the new sender. Used by
// /v1/handoffs/{id}/reassign so the HTTP handler doesn't have to know which
// fields a reassigned bug carries forward (summary / note / prd / repo /
// urgency) vs. which are re-derived (id / sender / created_at / kind /
// recipients / reassigned_from / reassigned_reason). OriginalSender is
// preserved across the reassign chain so the receiver's prompt template can
// still name the tester even after the bug bounces between sides.
func BuildReassignment(orig *handoffschema.Package, to, reason, by string, now time.Time) *handoffschema.Package {
	originalSender := orig.OriginalSender
	if originalSender == "" {
		originalSender = orig.Sender
	}
	return &handoffschema.Package{
		ID:               NewID(now),
		SchemaVersion:    handoffschema.SchemaVersion,
		Kind:             handoffschema.KindBug,
		Sender:           by,
		Recipient:        to,
		Recipients:       []string{to},
		Urgency:          orig.Urgency,
		CreatedAt:        now,
		Repo:             orig.Repo,
		SummaryMD:        orig.SummaryMD,
		NoteMD:           orig.NoteMD,
		PrdMD:            orig.PrdMD,
		OriginalSender:   originalSender,
		ReassignedFrom:   orig.ID,
		ReassignedReason: reason,
	}
}

// Build assembles the handoff Package plus any out-of-band attachments
// (binary blobs uploaded separately via transport.UploadAttachment). The
// returned attachments map is keyed by filename and may be empty / nil when
// no snapshot is shipping (request kind, module-brief, or no swagger file).
func Build(ctx context.Context, opts BuildOptions) (*handoffschema.Package, map[string][]byte, error) {
	requestMode := opts.Kind == handoffschema.KindRequest
	bugMode := opts.Kind == handoffschema.KindBug
	// Bug + request flows share the "summary is the body" semantics: skip
	// git diff / swagger / rules, the receiver works off SummaryMD alone.
	skipDiff := requestMode || bugMode
	moduleMode := !skipDiff && len(opts.ModulePaths) > 0
	attachments := map[string][]byte{}

	var (
		g        *handoffschema.Git
		repoMeta handoffschema.Repo
		apiDelta *handoffschema.APIDelta
		hints    []handoffschema.TargetingHint
		err      error
	)

	switch {
	case skipDiff:
		// Request / bug flow: there's no diff to ship and no swagger to
		// compare — the summary IS the body. Repo meta (branch + HEAD) is
		// best-effort context so the receiver can see who's asking from
		// where; a tester filing a bug needn't be in a git repo at all, so a
		// failure here is non-fatal — CollectRepoMeta returns an empty Repo,
		// and we ship without branch/HEAD rather than erroring out.
		repoMeta, _ = git.CollectRepoMeta(ctx, opts.RepoRoot)
		if len(opts.ModulePaths) > 0 {
			modeName := "request"
			if bugMode {
				modeName = "bug"
			}
			return nil, nil, fmt.Errorf("%s mode does not accept module_paths; describe the issue in summary instead", modeName)
		}
	case moduleMode:
		repoMeta, err = git.CollectRepoMeta(ctx, opts.RepoRoot)
		if err != nil {
			return nil, nil, fmt.Errorf("collect repo meta: %w", err)
		}
		for _, m := range opts.ModulePaths {
			if err := validateModulePath(opts.RepoRoot, m); err != nil {
				return nil, nil, err
			}
		}
		seedPaths, err := collectModuleFiles(opts.RepoRoot, opts.ModulePaths)
		if err != nil {
			return nil, nil, fmt.Errorf("walk module paths: %w", err)
		}
		if len(seedPaths) == 0 {
			return nil, nil, fmt.Errorf("module paths %v contain no Go files; nothing to derive hints from", opts.ModulePaths)
		}
		hints = opts.Rules.Apply(seedPaths)
	default:
		g, repoMeta, err = git.Collect(ctx, opts.RepoRoot, opts.Base)
		if err != nil {
			return nil, nil, fmt.Errorf("collect git: %w", err)
		}
		if g != nil {
			hints = opts.Rules.Apply(g.ChangedPaths)
		}
		if spec := config.ResolveSwaggerPath(opts.RepoRoot, opts.SwaggerPath); spec != "" {
			d, snapshot, err := swagger.Collect(opts.RepoRoot, spec)
			if err != nil {
				return nil, nil, fmt.Errorf("swagger delta: %w", err)
			}
			apiDelta = d
			if len(snapshot) > 0 {
				attachments[SwaggerSnapshotName] = snapshot
			}
		}
	}
	repoMeta.Name = opts.RepoName

	summary, err := readSummary(opts.InboxDir)
	if err != nil {
		return nil, nil, err
	}
	if summary == "" {
		return nil, nil, emptySummaryError(opts.InboxDir, opts.Kind)
	}

	// Caller-supplied attachments (screenshots / HAR / logs) ride alongside
	// any auto-derived ones (currently just the swagger snapshot). Reject the
	// reserved name so user input can't shadow the snapshot — Build owns that
	// slot, and renderAttachmentsSection on the receiver side filters it out
	// to avoid double-counting.
	for name, body := range opts.ExtraAttachments {
		if name == SwaggerSnapshotName {
			return nil, nil, fmt.Errorf("attachment name %q is reserved", name)
		}
		if _, exists := attachments[name]; exists {
			return nil, nil, fmt.Errorf("duplicate attachment name %q", name)
		}
		attachments[name] = body
	}

	urgency := opts.Urgency
	if urgency == "" {
		urgency = handoffschema.UrgencyNormal
	}

	kind := opts.Kind
	if kind == "" {
		kind = handoffschema.KindDelivery
	}

	// Keep the legacy scalar `Recipient` populated even for multi-recipient
	// bugs so display-only code (summary header, local inbox link file)
	// can render *something* without having to learn EffectiveRecipients().
	// Multi-recipient consumers iterate over Recipients directly.
	scalarRecipient := opts.Recipient
	if scalarRecipient == "" && len(opts.Recipients) > 0 {
		scalarRecipient = opts.Recipients[0]
	}
	pkg := &handoffschema.Package{
		SchemaVersion:  handoffschema.SchemaVersion,
		Kind:           kind,
		Sender:         opts.Sender,
		Recipient:      scalarRecipient,
		Recipients:     opts.Recipients,
		Urgency:        urgency,
		Repo:           repoMeta,
		SummaryMD:      summary,
		Git:            g,
		APIDelta:       apiDelta,
		ModulePaths:    opts.ModulePaths,
		TargetingHints: hints,
		NoteMD:         opts.Note,
		PrdMD:          opts.Prd,
		RespondsTo:     opts.RespondsTo,
		AmendsHandoff:  opts.Amends,
	}
	// For bug kind: OriginalSender = Sender on the first hop; reassign_bug
	// preserves the original tester identity via the relay-side handler.
	if kind == handoffschema.KindBug {
		pkg.OriginalSender = opts.Sender
	}

	attachMetadata(pkg, attachments)

	return pkg, attachments, nil
}

// attachMetadata populates pkg.Attachments (name + sha256 + size) from the raw
// blob map in a stable (sorted) order so receivers can verify integrity before
// download. Shared by Build and BuildCapsule.
func attachMetadata(pkg *handoffschema.Package, attachments map[string][]byte) {
	names := make([]string, 0, len(attachments))
	for n := range attachments {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		body := attachments[n]
		sum := sha256.Sum256(body)
		pkg.Attachments = append(pkg.Attachments, handoffschema.Attachment{
			Name:   n,
			SHA256: hex.EncodeToString(sum[:]),
			Size:   len(body),
		})
	}
}

// CapsuleOptions configures BuildCapsule. Unlike Build there's no git diff /
// swagger / rules work — the transcript is captured by the app and the
// persona/seed are distilled by the source session, then handed in directly.
// Like Build, ID and CreatedAt are left unset for the relay to stamp at submit.
type CapsuleOptions struct {
	RepoName        string
	Sender          string
	Visibility      handoffschema.CapsuleVisibility // "private" (个人, default) | "public" (公开)
	Urgency         handoffschema.Urgency
	SourceAgent     string // "claude" | "codex"
	OriginSessionID string
	SummaryMD       string // short human description of what this capsule is for
	NoteMD          string
	Repo            handoffschema.Repo
	// Payloads — any subset may be nil. Empty byte slices are treated as absent.
	TranscriptJSONL []byte
	TranscriptText  []byte
	Persona         []byte
	Seed            []byte
}

// BuildCapsule assembles a KindCapsule Package plus its attachment blobs (keyed
// by the reserved capsule names) for upload via the normal transport path. The
// HasTranscript / HasPersona flags are derived from which payloads are present
// so the receiver's pickup UI only offers the forms this capsule can instantiate.
func BuildCapsule(opts CapsuleOptions) (*handoffschema.Package, map[string][]byte, error) {
	if opts.SourceAgent != "claude" && opts.SourceAgent != "codex" {
		return nil, nil, fmt.Errorf("capsule source_agent must be \"claude\" or \"codex\", got %q", opts.SourceAgent)
	}

	attachments := map[string][]byte{}
	add := func(name string, body []byte) {
		if len(body) > 0 {
			attachments[name] = body
		}
	}
	add(handoffschema.CapsuleTranscriptJSONLName, opts.TranscriptJSONL)
	add(handoffschema.CapsuleTranscriptTextName, opts.TranscriptText)
	add(handoffschema.CapsulePersonaName, opts.Persona)
	add(handoffschema.CapsuleSeedName, opts.Seed)

	hasTranscript := len(opts.TranscriptJSONL) > 0 || len(opts.TranscriptText) > 0
	hasPersona := len(opts.Persona) > 0
	if !hasTranscript && !hasPersona {
		return nil, nil, fmt.Errorf("capsule is empty: provide at least a transcript or a persona")
	}

	urgency := opts.Urgency
	if urgency == "" {
		urgency = handoffschema.UrgencyNormal
	}
	repo := opts.Repo
	repo.Name = opts.RepoName

	pkg := &handoffschema.Package{
		SchemaVersion: handoffschema.SchemaVersion,
		Kind:          handoffschema.KindCapsule,
		Sender:        opts.Sender,
		Urgency:       urgency,
		Repo:          repo,
		SummaryMD:     opts.SummaryMD,
		NoteMD:        opts.NoteMD,
		Capsule: &handoffschema.Capsule{
			SourceAgent:     opts.SourceAgent,
			OriginSessionID: opts.OriginSessionID,
			Visibility:      opts.Visibility,
			HasTranscript:   hasTranscript,
			HasPersona:      hasPersona,
		},
	}
	attachMetadata(pkg, attachments)
	return pkg, attachments, nil
}

func emptySummaryError(inboxDir string, kind handoffschema.Kind) error {
	if kind == handoffschema.KindBug {
		return fmt.Errorf(`summary is empty: write %s before submitting — bug reports must be human-authored. The receiver's agent uses it to (a) judge whether the bug is on their side, (b) reproduce it, (c) decide between fix / reassign / discuss.

Example:

  ## Symptom
  /orders 列表页订单时间字段 created_at 显示成 "Invalid Date"。

  ## Reproduction
  1. 登录 https://staging.kunlun.local
  2. 进入"订单管理"页面
  3. 查看任意订单的"创建时间"列

  ## Expected
  显示 "2026-05-19 14:23"

  ## Actual
  显示 "Invalid Date"

  ## 怀疑归属
  不太确定。后端 API 返回的字段名是 createdAt（驼峰），前端 mapping 是不是漏了？或者是后端字段类型变了？

Or call submit_bug (MCP) with summary=... to skip the file step`, SummaryDraftPath(inboxDir))
	}
	if kind == handoffschema.KindRequest {
		return fmt.Errorf(`summary is empty: write %s before submitting — request intent must be human-authored, the receiver's agent relies on it to design a response.

Example:

  ## What's needed
  - GET /api/v1/orders — response is missing customer_phone (string, optional)
  - GET /api/v1/orders — pagination response is missing total (int)

  ## Why
  Order list page on frontend needs phone for the contact column and total for the pager.

  ## Acceptance
  - customer_phone present on every order; null when absent
  - total reflects pre-pagination count

Or call submit_request (MCP) with summary=... to skip the file step`, SummaryDraftPath(inboxDir))
	}
	return fmt.Errorf(`summary is empty: write %s before submitting — handoff intent must be human-authored, the receiver's agent relies on it to generate INTEGRATION.md.

Example:

  ## What changed
  - POST /api/v1/users — creates a user; returns 201 with {id, ...}
  - PUT  /api/v1/users/{id}/email — updates email, returns 204

  ## Why
  Frontend onboarding flow needs an email-change endpoint.

  ## Cross-end constraints
  - Email must be lowercased before send.
  - 409 = email already in use.

Or call submit_handoff (MCP) with summary=... to skip the file step`,
		SummaryDraftPath(inboxDir))
}

func readSummary(inboxDir string) (string, error) {
	p := SummaryDraftPath(inboxDir)
	b, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("read summary draft %s: %w", p, err)
	}
	return string(b), nil
}

// validateModulePath ensures m is a relative directory inside repoRoot. Module
// mode hands these paths to a filesystem walker, so we reject anything that
// could escape the repo or point at a non-existent / non-directory target.
func validateModulePath(repoRoot, m string) error {
	if m == "" {
		return fmt.Errorf("module path is empty")
	}
	if filepath.IsAbs(m) {
		return fmt.Errorf("module path %q must be relative to repo root", m)
	}
	rootAbs, err := filepath.Abs(repoRoot)
	if err != nil {
		return err
	}
	abs, err := filepath.Abs(filepath.Join(rootAbs, m))
	if err != nil {
		return err
	}
	rel, err := filepath.Rel(rootAbs, abs)
	if err != nil {
		return err
	}
	rel = filepath.ToSlash(rel)
	if rel == ".." || strings.HasPrefix(rel, "../") {
		return fmt.Errorf("module path %q escapes repo root", m)
	}
	if rel == "." {
		return fmt.Errorf("module path %q resolves to repo root; specify a real module subdirectory", m)
	}
	fi, err := os.Stat(abs)
	if err != nil {
		return fmt.Errorf("module path %q: %w", m, err)
	}
	if !fi.IsDir() {
		return fmt.Errorf("module path %q is not a directory", m)
	}
	return nil
}

// collectModuleFiles walks each module dir under repoRoot and returns the
// sorted, deduped list of *.go file paths (relative to repoRoot, forward
// slashes). These are fed to the rules engine so existing partner_mapping
// rules — which anchor on subdir suffixes like handler/ or dto/ — match.
func collectModuleFiles(repoRoot string, modulePaths []string) ([]string, error) {
	seen := make(map[string]struct{})
	var out []string
	for _, m := range modulePaths {
		abs := filepath.Join(repoRoot, m)
		err := filepath.WalkDir(abs, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				name := d.Name()
				if name == "vendor" || name == "node_modules" {
					return fs.SkipDir
				}
				if strings.HasPrefix(name, ".") && path != abs {
					return fs.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			rel, err := filepath.Rel(repoRoot, path)
			if err != nil {
				return err
			}
			rel = filepath.ToSlash(rel)
			if _, ok := seen[rel]; !ok {
				seen[rel] = struct{}{}
				out = append(out, rel)
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	sort.Strings(out)
	return out, nil
}
