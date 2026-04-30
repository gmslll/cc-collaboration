package handoff

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/cc-collaboration/internal/rules"
	"github.com/cc-collaboration/internal/sources/git"
	"github.com/cc-collaboration/internal/sources/swagger"
	"github.com/cc-collaboration/pkg/handoffschema"
)

type BuildOptions struct {
	RepoRoot    string
	RepoName    string
	Sender      string
	Recipient   string
	Urgency     handoffschema.Urgency
	Base        string
	Note        string
	Rules       *rules.Engine
	SwaggerPath string   // optional, relative to RepoRoot
	ModulePaths []string // module-brief mode: when set, skip git diff + swagger delta and treat summary as a self-contained API contract
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

func Build(ctx context.Context, opts BuildOptions) (*handoffschema.Package, error) {
	moduleMode := len(opts.ModulePaths) > 0

	var (
		g        *handoffschema.Git
		repoMeta handoffschema.Repo
		apiDelta *handoffschema.APIDelta
		hints    []handoffschema.TargetingHint
		err      error
	)

	if moduleMode {
		repoMeta, err = git.CollectRepoMeta(ctx, opts.RepoRoot)
		if err != nil {
			return nil, fmt.Errorf("collect repo meta: %w", err)
		}
		for _, m := range opts.ModulePaths {
			if err := validateModulePath(opts.RepoRoot, m); err != nil {
				return nil, err
			}
		}
		seedPaths, err := collectModuleFiles(opts.RepoRoot, opts.ModulePaths)
		if err != nil {
			return nil, fmt.Errorf("walk module paths: %w", err)
		}
		if len(seedPaths) == 0 {
			return nil, fmt.Errorf("module paths %v contain no Go files; nothing to derive hints from", opts.ModulePaths)
		}
		hints = opts.Rules.Apply(seedPaths)
	} else {
		g, repoMeta, err = git.Collect(ctx, opts.RepoRoot, opts.Base)
		if err != nil {
			return nil, fmt.Errorf("collect git: %w", err)
		}
		if g != nil {
			hints = opts.Rules.Apply(g.ChangedPaths)
		}
		if opts.SwaggerPath != "" {
			spec := opts.SwaggerPath
			if !filepath.IsAbs(spec) {
				spec = filepath.Join(opts.RepoRoot, spec)
			}
			d, err := swagger.Collect(opts.RepoRoot, spec)
			if err != nil {
				return nil, fmt.Errorf("swagger delta: %w", err)
			}
			apiDelta = d
		}
	}
	repoMeta.Name = opts.RepoName

	summary, err := readSummary(opts.InboxDir)
	if err != nil {
		return nil, err
	}
	if summary == "" {
		return nil, fmt.Errorf("summary is empty: write %s before submitting — handoff intent must be human-authored, the receiver's Claude relies on it to generate INTEGRATION.md",
			SummaryDraftPath(opts.InboxDir))
	}

	urgency := opts.Urgency
	if urgency == "" {
		urgency = handoffschema.UrgencyNormal
	}

	pkg := &handoffschema.Package{
		SchemaVersion:  handoffschema.SchemaVersion,
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
	}

	return pkg, nil
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
