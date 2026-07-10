package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/internal/inbox"
	"github.com/cc-collaboration/internal/rules"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

func runSubmit(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("submit", flag.ContinueOnError)
	to := fs.String("to", "", "recipient identity (explicit point-to-point target)")
	projectID := fs.String("project", "", "send to all actionable project recipients (direct owners/members plus team owners/admins; excludes yourself and viewers)")
	orgID := fs.String("org", "", "send to all actionable members of organization id (owners/admins/members; excludes yourself and guests)")
	member := fs.String("member", "", "limit --project/--org delivery to this identity after validating team membership")
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

	res, err := config.ResolveRelay(cwd)
	if err != nil {
		return err
	}

	recipient := cleanTargetArg(*to)
	client := transport.New(res.RelayURL, res.Token)
	resolvedProjectID := cleanTargetArg(*projectID)
	if shouldInferProjectTarget(*to, resolvedProjectID, *orgID) {
		if inferred, ok, err := inferDefaultProjectID(ctx, client, res); err != nil {
			return err
		} else if ok {
			resolvedProjectID = inferred
		}
	}
	resolvedRecipient := recipient
	if *to == "" && (resolvedProjectID != "" || *orgID != "") {
		resolvedRecipient = ""
	}
	recipients, err := resolveSubmitRecipients(ctx, client, res.Me, resolvedRecipient, resolvedProjectID, *orgID, *member)
	if err != nil {
		return err
	}
	if len(recipients) == 0 {
		return fmt.Errorf("no recipient: pass --to/--project/--org, or bind this workspace/repo to a team project")
	}
	recipient = recipients[0]

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

	var fanout []string
	if len(recipients) > 1 {
		fanout = recipients
	}
	repoRoot := config.RepoRoot(cwd)
	deliveryTarget := submitDeliveryTarget(resolvedProjectID, *orgID, *member)
	pkg, attachments, err := handoff.Build(ctx, handoff.BuildOptions{
		RepoRoot:       repoRoot,
		RepoName:       res.RepoName,
		Sender:         res.Me,
		Recipient:      recipient,
		Recipients:     fanout,
		Urgency:        urgency,
		Base:           base,
		Note:           *note,
		Prd:            *prd,
		Rules:          engine,
		SwaggerPath:    res.Swagger,
		Amends:         *amends,
		InboxDir:       inbox.InboxDir(repoRoot, res.InboxOverride),
		DeliveryTarget: deliveryTarget,
	})
	if err != nil {
		return err
	}

	out, err := client.Submit(ctx, pkg, attachments)
	if err != nil {
		return err
	}
	fmt.Printf("✓ submitted handoff %s to %s\n", out.ID, formatRecipientTarget(recipients))
	fmt.Printf("  branch=%s base=%s head=%s\n",
		pkg.Repo.Branch, handoff.ShortSHA(pkg.Repo.BaseSHA), handoff.ShortSHA(pkg.Repo.HeadSHA))
	if pkg.Git != nil {
		fmt.Printf("  changed_paths=%d  commits=%d\n", len(pkg.Git.ChangedPaths), len(pkg.Git.Commits))
	}
	if len(pkg.TargetingHints) > 0 {
		fmt.Printf("  targeting_hints=%d\n", len(pkg.TargetingHints))
	}
	if pkg.DeliveryTarget != nil {
		fmt.Printf("  delivery_target=%s\n", formatDeliveryTarget(pkg.DeliveryTarget))
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

func shouldInferProjectTarget(to, projectID, orgID string) bool {
	if cleanTargetArg(to) != "" || cleanTargetArg(projectID) != "" || cleanTargetArg(orgID) != "" {
		return false
	}
	return true
}

func inferDefaultProjectID(ctx context.Context, client *transport.Client, res *config.Resolved) (string, bool, error) {
	if id := cleanTargetArg(res.WorkspaceProjectID); id != "" {
		return id, true, nil
	}
	return client.ProjectIDForRepo(ctx, res.RepoName)
}

func submitDeliveryTarget(projectID, orgID, member string) *handoffschema.DeliveryTarget {
	projectID = strings.TrimSpace(projectID)
	orgID = strings.TrimSpace(orgID)
	member = strings.TrimSpace(member)
	if projectID == "" && orgID == "" && member == "" {
		return nil
	}
	return &handoffschema.DeliveryTarget{
		ProjectID: projectID,
		OrgID:     orgID,
		Member:    member,
	}
}

func formatDeliveryTarget(target *handoffschema.DeliveryTarget) string {
	if target == nil {
		return ""
	}
	var parts []string
	if target.ProjectID != "" {
		parts = append(parts, "project="+target.ProjectID)
	}
	if target.OrgID != "" {
		parts = append(parts, "org="+target.OrgID)
	}
	if target.Member != "" {
		parts = append(parts, "member="+target.Member)
	}
	return strings.Join(parts, " ")
}

func resolveSubmitRecipients(ctx context.Context, client *transport.Client, sender, recipient, projectID, orgID, member string) ([]string, error) {
	sender = cleanTargetArg(sender)
	recipient = cleanTargetArg(recipient)
	projectID = cleanTargetArg(projectID)
	orgID = cleanTargetArg(orgID)
	member = cleanTargetArg(member)
	if (projectID != "" || orgID != "") && recipient != "" {
		return nil, fmt.Errorf("--to cannot be combined with --project or --org")
	}
	if projectID != "" || orgID != "" {
		recipients, err := client.ResolveTeamRecipients(ctx, projectID, orgID, sender, member)
		if err != nil {
			return nil, err
		}
		if len(recipients) == 0 {
			if projectID != "" {
				return nil, fmt.Errorf("project %s has no actionable recipients (direct owners/members or team owners/admins other than %s)", projectID, sender)
			}
			return nil, fmt.Errorf("organization %s has no actionable recipients (owners/admins/members other than %s)", orgID, sender)
		}
		return recipients, nil
	}
	if member != "" {
		return nil, fmt.Errorf("--member requires --project or --org")
	}
	if recipient == "" {
		return nil, nil
	}
	if recipient == sender {
		return nil, fmt.Errorf("cannot send a handoff to yourself (%s)", sender)
	}
	return []string{recipient}, nil
}

func formatRecipientTarget(recipients []string) string {
	if len(recipients) == 1 {
		return recipients[0]
	}
	return fmt.Sprintf("%d recipients (%s)", len(recipients), strings.Join(recipients, ", "))
}
