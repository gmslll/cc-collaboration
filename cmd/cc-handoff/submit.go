package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/internal/inbox"
	"github.com/cc-collaboration/internal/rules"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

func runSubmit(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("submit", flag.ContinueOnError)
	to := fs.String("to", "", "recipient identity (default: partner from .cc-handoff.toml)")
	urgent := fs.Bool("urgent", false, "mark handoff as urgent (recipient may auto-launch)")
	note := fs.String("note", "", "需求 / 跨端约束 (Markdown)；会以「⚠️ 必读」段渲染到接收端 prompt 并要求 INTEGRATION.md 逐条响应")
	prd := fs.String("prd", "", "产品需求 / 设计意图 (Markdown)；以「📋 背景参考」段渲染到接收端 prompt，不强制逐条响应（区别于 --note）")
	amends := fs.String("amends", "", "若本次是对之前已发过的某个 handoff 的修正交付,填上次的 handoff id;接收端 prompt 顶端会显示「⚠️ 修正交付」横幅,提示前端去对照原版 INTEGRATION.md")
	baseOverride := fs.String("base", "", "override git base ref")
	if err := fs.Parse(args); err != nil {
		return err
	}

	cwd, err := os.Getwd()
	if err != nil {
		return err
	}

	res, err := config.Resolve(cwd)
	if err != nil {
		return err
	}

	recipient := res.Partner
	if *to != "" {
		recipient = *to
	}
	if recipient == "" {
		return fmt.Errorf("no recipient: pass --to or set identity.partner in .cc-handoff.toml")
	}

	base := res.Base
	if *baseOverride != "" {
		base = *baseOverride
	}

	urgency := handoffschema.UrgencyNormal
	if *urgent {
		urgency = handoffschema.UrgencyUrgent
	}

	engine, err := rules.Compile(res.Rules)
	if err != nil {
		return err
	}

	repoRoot := config.RepoRoot(cwd)
	pkg, attachments, err := handoff.Build(ctx, handoff.BuildOptions{
		RepoRoot:    repoRoot,
		RepoName:    res.RepoName,
		Sender:      res.Me,
		Recipient:   recipient,
		Urgency:     urgency,
		Base:        base,
		Note:        *note,
		Prd:         *prd,
		Rules:       engine,
		SwaggerPath: res.Swagger,
		Amends:      *amends,
		InboxDir:    inbox.InboxDir(repoRoot, res.InboxOverride),
	})
	if err != nil {
		return err
	}

	client := transport.New(res.RelayURL, res.Token)
	out, err := client.Submit(ctx, pkg, attachments)
	if err != nil {
		return err
	}
	fmt.Printf("✓ submitted handoff %s to %s\n", out.ID, recipient)
	fmt.Printf("  branch=%s base=%s head=%s\n",
		pkg.Repo.Branch, handoff.ShortSHA(pkg.Repo.BaseSHA), handoff.ShortSHA(pkg.Repo.HeadSHA))
	if pkg.Git != nil {
		fmt.Printf("  changed_paths=%d  commits=%d\n", len(pkg.Git.ChangedPaths), len(pkg.Git.Commits))
	}
	if len(pkg.TargetingHints) > 0 {
		fmt.Printf("  targeting_hints=%d\n", len(pkg.TargetingHints))
	}
	if pkg.APIDelta != nil {
		fmt.Printf("  api_delta: +%d ~%d -%d\n",
			len(pkg.APIDelta.Added), len(pkg.APIDelta.Changed), len(pkg.APIDelta.Removed))
	}
	if pkg.AmendsHandoff != "" {
		fmt.Printf("  amends=%s\n", pkg.AmendsHandoff)
	}
	return nil
}
