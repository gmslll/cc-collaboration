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

type BuildOptions struct {
	RepoRoot    string
	RepoName    string
	Sender      string
	Recipient   string
	Urgency     handoffschema.Urgency
	Base        string
	Note        string
	Prd         string
	Rules       *rules.Engine
	SwaggerPath string             // optional, relative to RepoRoot
	ModulePaths []string           // module-brief mode: when set, skip git diff + swagger delta and treat summary as a self-contained API contract
	Kind        handoffschema.Kind // empty defaults to KindDelivery; KindRequest skips git diff / swagger / rules
	RespondsTo  string             // on a delivery, the request id this answers (renders a banner on the receiver side)
	Amends      string             // on a delivery, the prior handoff id this delivery corrects/supersedes (renders a banner on the receiver side)
	// InboxDir is the absolute resolved inbox directory (caller computes via
	// inbox.InboxDir to apply the legacy / primary fallback). The draft
	// summary file lives here.
	InboxDir string
}

// SummaryDraftPath returns where the human-authored summary draft lives. The
// caller passes the resolved inbox dir; cc-handoff doesn't try to recompute
// it here to avoid a circular import (inbox → handoff already exists for
// ShortSHA).
func SummaryDraftPath(inboxDir string) string {
	return filepath.Join(inboxDir, ".draft-summary.md")
}

// Build assembles the handoff Package plus any out-of-band attachments
// (binary blobs uploaded separately via transport.UploadAttachment). The
// returned attachments map is keyed by filename and may be empty / nil when
// no snapshot is shipping (request kind, module-brief, or no swagger file).
func Build(ctx context.Context, opts BuildOptions) (*handoffschema.Package, map[string][]byte, error) {
	requestMode := opts.Kind == handoffschema.KindRequest
	moduleMode := !requestMode && len(opts.ModulePaths) > 0
	attachments := map[string][]byte{}

	var (
		g        *handoffschema.Git
		repoMeta handoffschema.Repo
		apiDelta *handoffschema.APIDelta
		hints    []handoffschema.TargetingHint
		err      error
	)

	switch {
	case requestMode:
		// Request flow: there's no diff to ship and no swagger to compare —
		// the summary IS the body. Still collect repo meta so the receiver
		// can see who's asking from where.
		repoMeta, err = git.CollectRepoMeta(ctx, opts.RepoRoot)
		if err != nil {
			return nil, nil, fmt.Errorf("collect repo meta: %w", err)
		}
		if len(opts.ModulePaths) > 0 {
			return nil, nil, fmt.Errorf("request mode does not accept module_paths; describe the need in summary instead")
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
		return nil, nil, emptySummaryError(opts.InboxDir, requestMode)
	}

	urgency := opts.Urgency
	if urgency == "" {
		urgency = handoffschema.UrgencyNormal
	}

	kind := opts.Kind
	if kind == "" {
		kind = handoffschema.KindDelivery
	}

	pkg := &handoffschema.Package{
		SchemaVersion:  handoffschema.SchemaVersion,
		Kind:           kind,
		Sender:         opts.Sender,
		Recipient:      opts.Recipient,
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

	// Populate Package.Attachments metadata (name + sha256 + size) in a
	// stable order so receivers can verify integrity before download.
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

	return pkg, attachments, nil
}

func emptySummaryError(inboxDir string, requestMode bool) error {
	if requestMode {
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
