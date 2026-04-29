package handoff

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

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
	SwaggerPath string // optional, relative to RepoRoot
}

func SummaryDraftPath(repoRoot string) string {
	return filepath.Join(repoRoot, ".claude", "handoff-inbox", ".draft-summary.md")
}

func Build(ctx context.Context, opts BuildOptions) (*handoffschema.Package, error) {
	g, repoMeta, err := git.Collect(ctx, opts.RepoRoot, opts.Base)
	if err != nil {
		return nil, fmt.Errorf("collect git: %w", err)
	}
	repoMeta.Name = opts.RepoName

	summary, err := readSummary(opts.RepoRoot)
	if err != nil {
		return nil, err
	}
	if summary == "" {
		return nil, fmt.Errorf("summary is empty: write %s before submitting — handoff intent must be human-authored, the receiver's Claude relies on it to generate INTEGRATION.md",
			SummaryDraftPath(opts.RepoRoot))
	}

	urgency := opts.Urgency
	if urgency == "" {
		urgency = handoffschema.UrgencyNormal
	}

	var hints []handoffschema.TargetingHint
	if g != nil {
		hints = opts.Rules.Apply(g.ChangedPaths)
	}

	var apiDelta *handoffschema.APIDelta
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

	pkg := &handoffschema.Package{
		SchemaVersion:  handoffschema.SchemaVersion,
		Sender:         opts.Sender,
		Recipient:      opts.Recipient,
		Urgency:        urgency,
		Repo:           repoMeta,
		SummaryMD:      summary,
		Git:            g,
		APIDelta:       apiDelta,
		TargetingHints: hints,
		NoteMD:         opts.Note,
	}

	return pkg, nil
}

func readSummary(repoRoot string) (string, error) {
	p := SummaryDraftPath(repoRoot)
	b, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("read summary draft %s: %w", p, err)
	}
	return string(b), nil
}
