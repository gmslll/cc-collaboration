package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/internal/sources/git"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// runCapsule dispatches `cc-handoff capsule <subcommand>`. Currently only
// `submit`: package a captured session (transcript + distilled persona/seed)
// into a KindCapsule handoff and publish it to the plaza — 个人 (private) or
// --public (公开). The app shells out to this after capturing/distilling the
// drafts, so the transport + relay-id-stamping path is shared with handoffs.
func runCapsule(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: cc-handoff capsule submit [flags]")
	}
	switch args[0] {
	case "submit":
		return runCapsuleSubmit(ctx, args[1:])
	default:
		return fmt.Errorf("unknown capsule subcommand %q (want: submit)", args[0])
	}
}

func runCapsuleSubmit(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("capsule submit", flag.ContinueOnError)
	sourceAgent := fs.String("source-agent", "", "source tool the capsule was captured from: claude | codex (required)")
	originSession := fs.String("origin-session", "", "capture-side agent session id (claude uuid / codex rollout id)")
	public := fs.Bool("public", false, "publish to the plaza as 公开 (visible to the team); default is 个人 (private, owner-only)")
	transcriptPath := fs.String("transcript", "", "path to transcript.jsonl (raw log, for same-tool native --resume)")
	transcriptTextPath := fs.String("transcript-text", "", "path to transcript.txt (neutral render, cross-tool seed)")
	personaPath := fs.String("persona", "", "path to persona.md (distilled role, ②)")
	seedPath := fs.String("seed", "", "path to seed.md (compact context summary)")
	summary := fs.String("summary", "", "short human description of what this capsule is for")
	summaryFile := fs.String("summary-file", "", "read --summary from a file instead")
	note := fs.String("note", "", "extra note rendered to the receiver")
	urgent := fs.Bool("urgent", false, "mark urgent")
	if err := fs.Parse(args); err != nil {
		return err
	}

	if *sourceAgent == "" {
		return fmt.Errorf("--source-agent is required (claude | codex)")
	}

	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	// A capsule goes to the plaza (public = the relay's team, private = self),
	// not to a partner — so it only needs the relay connection, not a repo
	// partner config.
	res, err := config.ResolveRelay(cwd)
	if err != nil {
		return err
	}

	visibility := handoffschema.CapsulePrivate
	if *public {
		visibility = handoffschema.CapsulePublic
	}

	transcript, err := readCapsuleFile(*transcriptPath)
	if err != nil {
		return err
	}
	transcriptText, err := readCapsuleFile(*transcriptTextPath)
	if err != nil {
		return err
	}
	persona, err := readCapsuleFile(*personaPath)
	if err != nil {
		return err
	}
	seed, err := readCapsuleFile(*seedPath)
	if err != nil {
		return err
	}

	summaryMD := *summary
	if *summaryFile != "" {
		b, err := os.ReadFile(*summaryFile)
		if err != nil {
			return fmt.Errorf("read --summary-file: %w", err)
		}
		summaryMD = string(b)
	}

	// Best-effort repo context (branch/head) so the receiver sees where it came
	// from; a capsule needn't be in a git repo, so failure is non-fatal.
	repoMeta, _ := git.CollectRepoMeta(ctx, config.RepoRoot(cwd))

	urgency := handoffschema.UrgencyNormal
	if *urgent {
		urgency = handoffschema.UrgencyUrgent
	}

	pkg, attachments, err := handoff.BuildCapsule(handoff.CapsuleOptions{
		RepoName:        res.RepoName,
		Sender:          res.Me,
		Visibility:      visibility,
		Urgency:         urgency,
		SourceAgent:     *sourceAgent,
		OriginSessionID: *originSession,
		SummaryMD:       summaryMD,
		NoteMD:          *note,
		Repo:            repoMeta,
		TranscriptJSONL: transcript,
		TranscriptText:  transcriptText,
		Persona:         persona,
		Seed:            seed,
	})
	if err != nil {
		return err
	}

	client := transport.New(res.RelayURL, res.Token)
	out, err := client.Submit(ctx, pkg, attachments)
	if err != nil {
		return err
	}

	fmt.Printf("✓ submitted capsule %s (%s) to the plaza\n", out.ID, visibility)
	fmt.Printf("  source=%s  ①transcript=%v  ②persona=%v\n",
		*sourceAgent, pkg.Capsule.HasTranscript, pkg.Capsule.HasPersona)
	return nil
}

// readCapsuleFile reads an optional payload file; an empty path means the
// payload is absent (nil bytes), which BuildCapsule treats as "not present".
func readCapsuleFile(path string) ([]byte, error) {
	if path == "" {
		return nil, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	return b, nil
}
