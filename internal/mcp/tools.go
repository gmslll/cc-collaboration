package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/drift"
	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/internal/inbox"
	"github.com/cc-collaboration/internal/linear"
	"github.com/cc-collaboration/internal/rules"
	gitsrc "github.com/cc-collaboration/internal/sources/git"
	"github.com/cc-collaboration/internal/statusfmt"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// Tool names — referenced from slash command markdown and from each other's
// help text, so a typo here only breaks at runtime.
const (
	ToolSubmitHandoff   = "submit_handoff"
	ToolSubmitRequest   = "submit_request"
	ToolSubmitBug       = "submit_bug"
	ToolReassignBug     = "reassign_bug"
	ToolListInbox       = "list_inbox"
	ToolPickupHandoff   = "pickup_handoff"
	ToolCommentHandoff  = "comment_handoff"
	ToolStatusHandoff   = "status_handoff"
	ToolListSent        = "list_sent"
	ToolListHistory     = "list_history"
	ToolRetractHandoff  = "retract_handoff"
	ToolListLocalInbox  = "list_local_inbox"
	ToolListOnlineUsers = "list_online_users"
	ToolSessionUsage    = "session_usage"
	ToolCheckDrift      = "check_drift"
	ToolLinkLinear      = "link_linear"
	ToolLinearSync      = "linear_sync"

	ToolCreateTodo         = "create_todo"
	ToolListTodos          = "list_todos"
	ToolGetTodo            = "get_todo"
	ToolUpdateTodoStatus   = "update_todo_status"
	ToolAssignTodo         = "assign_todo"
	ToolCommentTodo        = "comment_todo"
	ToolImportLinearIssues = "import_linear_issues"
)

// CCHandoffMCPPrefix is the wire-name prefix Claude uses when calling tools
// exposed by this MCP server (server name "cc-handoff", see
// cmd/cc-handoff-mcp/main.go). Use it together with the Tool* constants when
// rendering prompts that ask the agent to call back into cc-handoff.
const CCHandoffMCPPrefix = "mcp__cc-handoff__"

// DefaultTools returns the tools cc-handoff exposes via MCP. They wrap the
// same internals the CLI uses so behavior stays identical.
func DefaultTools() []Tool {
	return []Tool{
		submitHandoffTool(),
		submitRequestTool(),
		submitBugTool(),
		reassignBugTool(),
		listInboxTool(),
		pickupHandoffTool(),
		commentHandoffTool(),
		statusHandoffTool(),
		listSentTool(),
		listHistoryTool(),
		retractHandoffTool(),
		listLocalInboxTool(),
		listOnlineUsersTool(),
		sessionUsageTool(),
		checkDriftTool(),
		linkLinearTool(),
		linearSyncTool(),
		createTodoTool(),
		listTodosTool(),
		getTodoTool(),
		updateTodoStatusTool(),
		assignTodoTool(),
		commentTodoTool(),
		importLinearIssuesTool(),
	}
}

func submitHandoffTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "summary":      {"type": "string", "description": "Markdown summary of the change. Written to <inbox-dir>/.draft-summary.md before the package is built (inbox-dir defaults to .cc-handoff/inbox, falls back to legacy .claude/handoff-inbox in older repos). If omitted, the existing draft (if any) is used."},
    "to":           {"type": "string", "description": "Recipient identity. Defaults to identity.partner from .cc-handoff.toml."},
    "project":      {"type": "string", "description": "Project id to share this handoff with all actionable project recipients (direct owners/members plus team owners/admins). Mutually exclusive with to and org; excludes yourself and project viewers."},
    "org":          {"type": "string", "description": "Organization id to share this handoff with all actionable organization members (owners/admins/members). Mutually exclusive with to and project; excludes yourself and guests."},
    "member":       {"type": "string", "description": "With project/org, send only to this identity after validating they are an actionable member of that team."},
    "urgent":       {"type": "boolean", "description": "Mark as urgent. Recipients with auto_launch=true will spawn a new terminal."},
    "note":         {"type": "string", "description": "Markdown 写的「需求 / 跨端约束」段，例如错误码对照、字段大小写规则、分页约定、不可合并的请求等。会以「⚠️ 后端备注 / 需求 (必读)」醒目段渲染到接收端 prompt，并被强制要求 INTEGRATION.md 逐条响应。短到一两句也可以；没有就不传。"},
    "prd":          {"type": "string", "description": "产品需求 / 设计意图 markdown（背景参考）。会以「📋 产品需求 / 设计意图 (背景参考)」段渲染到接收端 prompt，作为背景阅读，不要求 INTEGRATION.md 逐条响应。和 note 区分：note 是必须兑现的硬约束（必读），prd 是 why（参考）。没有就不传。"},
    "module_paths": {"type": "array", "items": {"type": "string"}, "description": "Module-brief mode: relative-to-repo-root directory paths (e.g. internal/module/oms/order). When set, the build switches to module-brief mode — git diff and Swagger delta are skipped, and summary is treated as a self-contained API contract document. Drive this from the /handoff-module slash command; do not set it manually unless you know why."},
    "responds_to":  {"type": "string", "description": "若本 handoff 是对某个对端 request (kind=request) 的回应，把 request id 填这里 (例如 h_20260507_ABCD1234)。会渲染到接收端 prompt 顶端的「↩️ 回应 xxx」段，让发起方知道此次交付是回应哪条需求。"},
    "amends":       {"type": "string", "description": "若本次 handoff 是对自己**先前已发出**的某个 handoff 的修正交付(比如 endpoint 改了字段、错误码变了、整合方案需要重做),把上次的 handoff id 填这里。会渲染到接收端 prompt 顶端的「⚠️ 修正交付」横幅,提示前端去翻原版 INTEGRATION.md 对照本次增量。和 responds_to 区分:responds_to 是「我在回应你之前发的需求」,amends 是「我之前发过的 handoff 这次要改」。没有就不传。"},
    "attachment_paths": {"type": "array", "items": {"type": "string"}, "description": "可选,本地文件路径数组(绝对路径或相对 cwd),随 handoff 一起发给接收端。任意类型:UI 截图 / 设计稿 / 错误响应 / HAR / log / 视频 都行,单文件 ≤ 50MB,同 basename 自动加序号。接收端 pickup 后文件落到 .cc-handoff/inbox/<id>/attachments/,prompt.md 会列出来。"},
    "cwd":          {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  }
}`)
	return Tool{
		Name:        ToolSubmitHandoff,
		Description: "Package the current branch's change set (git diff, swagger delta, summary, partner-mapping hints) and send it to a partner via the cc-handoff relay. Use this when you've finished implementing an API and want the receiving side to integrate.",
		InputSchema: schema,
		Handler:     submitHandoffHandler,
	}
}

type submitArgs struct {
	Summary         string   `json:"summary"`
	To              string   `json:"to"`
	Project         string   `json:"project"`
	Org             string   `json:"org"`
	Member          string   `json:"member"`
	Urgent          bool     `json:"urgent"`
	Note            string   `json:"note"`
	Prd             string   `json:"prd"`
	ModulePaths     []string `json:"module_paths"`
	RespondsTo      string   `json:"responds_to"`
	Amends          string   `json:"amends"`
	AttachmentPaths []string `json:"attachment_paths"`
	CWD             string   `json:"cwd"`
}

func submitHandoffHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a submitArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.ResolveRelay(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	repoRoot := config.RepoRoot(cwd)
	inboxDir := inbox.InboxDir(repoRoot, res.InboxOverride)

	if a.Summary != "" {
		if err := writeDraftSummary(inboxDir, a.Summary); err != nil {
			return ToolResult{}, err
		}
	}

	client := transport.New(res.RelayURL, res.Token)
	recipients, recipient, err := resolveToolRecipients(ctx, client, res.Me, res.Partner, a.To, a.Project, a.Org, a.Member)
	if err != nil {
		return ToolResult{}, err
	}

	urgency := handoffschema.UrgencyNormal
	if a.Urgent {
		urgency = handoffschema.UrgencyUrgent
	}

	engine, err := rules.Compile(res.Rules)
	if err != nil {
		return ToolResult{}, err
	}

	extras, _, err := readAttachments(cwd, a.AttachmentPaths)
	if err != nil {
		return ToolResult{}, err
	}

	var fanout []string
	if len(recipients) > 1 {
		fanout = recipients
	}
	pkg, attachments, err := handoff.Build(ctx, handoff.BuildOptions{
		RepoRoot:         repoRoot,
		RepoName:         res.RepoName,
		Sender:           res.Me,
		Recipient:        recipient,
		Recipients:       fanout,
		Urgency:          urgency,
		Base:             res.Base,
		Note:             a.Note,
		Prd:              a.Prd,
		Rules:            engine,
		SwaggerPath:      res.Swagger,
		ModulePaths:      a.ModulePaths,
		Kind:             handoffschema.KindDelivery,
		RespondsTo:       a.RespondsTo,
		Amends:           a.Amends,
		InboxDir:         inboxDir,
		ExtraAttachments: extras,
		DeliveryTarget:   deliveryTarget(a.Project, a.Org, a.Member),
	})
	if err != nil {
		return ToolResult{}, err
	}

	out, err := client.Submit(ctx, pkg, attachments)
	if err != nil {
		return ToolResult{}, err
	}

	var sb strings.Builder
	fmt.Fprintf(&sb, "Submitted handoff `%s` to %s.\n\n", out.ID, formatRecipientList(recipients))
	if len(pkg.ModulePaths) > 0 {
		fmt.Fprintf(&sb, "- mode: module-brief\n- modules: %s\n- branch: `%s`\n- head: `%s`\n",
			strings.Join(pkg.ModulePaths, ", "), pkg.Repo.Branch, handoff.ShortSHA(pkg.Repo.HeadSHA))
	} else {
		fmt.Fprintf(&sb, "- branch: `%s`\n- base: `%s`\n- head: `%s`\n",
			pkg.Repo.Branch, handoff.ShortSHA(pkg.Repo.BaseSHA), handoff.ShortSHA(pkg.Repo.HeadSHA))
	}
	if pkg.Git != nil {
		fmt.Fprintf(&sb, "- changed_paths: %d\n- commits: %d\n",
			len(pkg.Git.ChangedPaths), len(pkg.Git.Commits))
	}
	if len(pkg.TargetingHints) > 0 {
		fmt.Fprintf(&sb, "- targeting_hints: %d\n", len(pkg.TargetingHints))
	}
	writeDeliveryTargetSummary(&sb, pkg.DeliveryTarget)
	if pkg.APIDelta != nil {
		fmt.Fprintf(&sb, "- api_delta: +%d ~%d -%d\n",
			len(pkg.APIDelta.Added), len(pkg.APIDelta.Changed), len(pkg.APIDelta.Removed))
	}
	if pkg.RespondsTo != "" {
		fmt.Fprintf(&sb, "- responds_to: `%s`\n", pkg.RespondsTo)
	}
	if pkg.AmendsHandoff != "" {
		fmt.Fprintf(&sb, "- amends: `%s`\n", pkg.AmendsHandoff)
	}
	writeAttachmentSummary(&sb, pkg)
	sb.WriteString(linearSyncBlock(res.Linear, LinearEventSubmit, LinearSyncCtx{HandoffID: out.ID}))
	return textResult(sb.String()), nil
}

// writeAttachmentSummary appends an "- attachments:" line to the user-facing
// tool response when the package carries any non-swagger attachment. The
// receiver-side prompt will list them in detail; here we just confirm they
// rode along so the sender knows they made it through readAttachments.
func writeAttachmentSummary(sb *strings.Builder, pkg *handoffschema.Package) {
	var names []string
	for _, a := range pkg.Attachments {
		if a.Name == handoff.SwaggerSnapshotName {
			continue
		}
		names = append(names, a.Name)
	}
	if len(names) == 0 {
		return
	}
	fmt.Fprintf(sb, "- attachments: %s\n", strings.Join(names, ", "))
}

func writeDeliveryTargetSummary(sb *strings.Builder, target *handoffschema.DeliveryTarget) {
	if target == nil {
		return
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
	if len(parts) == 0 {
		return
	}
	fmt.Fprintf(sb, "- delivery_target: %s\n", strings.Join(parts, " "))
}

// writeRepoMetaLines emits the branch/head context lines, but only when they
// exist. Bug/request submissions are best-effort about git (a tester needn't
// be in a repo), so the package may carry empty branch/HEAD — skip those lines
// rather than printing bare `- branch: “.
func writeRepoMetaLines(sb *strings.Builder, pkg *handoffschema.Package) {
	if pkg.Repo.Branch != "" {
		fmt.Fprintf(sb, "- branch: `%s`\n", pkg.Repo.Branch)
	}
	if pkg.Repo.HeadSHA != "" {
		fmt.Fprintf(sb, "- head: `%s`\n", handoff.ShortSHA(pkg.Repo.HeadSHA))
	}
}

func submitRequestTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "summary": {"type": "string", "description": "Markdown 描述需求：缺什么字段 / 没暴露什么能力 / 返回结构哪里有问题，写到具体 endpoint + field。包含 Why（前端要拿它做什么）和 Acceptance（怎样算 OK）。会写入 <inbox-dir>/.draft-summary.md；省略则用现有 draft（如有）。"},
    "to":      {"type": "string", "description": "Recipient identity. Defaults to identity.partner from .cc-handoff.toml."},
    "project": {"type": "string", "description": "Project id to share this request with all actionable project recipients (direct owners/members plus team owners/admins). Mutually exclusive with to and org; excludes yourself and project viewers."},
    "org":     {"type": "string", "description": "Organization id to share this request with all actionable organization members (owners/admins/members). Mutually exclusive with to and project; excludes yourself and guests."},
    "member":  {"type": "string", "description": "With project/org, send only to this identity after validating they are an actionable member of that team."},
    "urgent":  {"type": "boolean", "description": "Mark as urgent. Recipients with auto_launch=true will spawn a new terminal."},
    "note":    {"type": "string", "description": "给后端的额外约束/备注，例如「不要破坏现有调用方」「字段命名跟 X 一致」「兼容现存数据」。会以「⚠️ 发起方备注 / 跨端约束 (必读)」段渲染到接收端 prompt，被要求逐条响应。没有就不传。"},
    "prd":     {"type": "string", "description": "前端从产品侧拿到的需求 / 设计意图 markdown（背景参考）。会以「📋 产品需求 / 设计意图 (背景参考)」段渲染到接收端 prompt，帮接收方理解这个 request 背后的业务目的。**作为背景阅读**，不要求逐条响应。和 note 区分：note 是必须兑现的硬约束（必读），prd 是 why（参考）。没有就不传。"},
    "attachment_paths": {"type": "array", "items": {"type": "string"}, "description": "可选,本地文件路径数组(绝对或相对 cwd),随 request 一起带给后端。任意类型:线上响应截图 / HAR / 日志 / 视频 都行,单文件 ≤ 50MB,同 basename 自动加序号。接收端 pickup 后落到 .cc-handoff/inbox/<id>/attachments/。"},
    "cwd":     {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  }
}`)
	return Tool{
		Name:        ToolSubmitRequest,
		Description: "Send a feature/field/endpoint request from this side (typically frontend) to the partner (typically backend). Use this when the partner's API is incomplete — missing fields, missing endpoints, broken response shapes, etc. The summary IS the request body; no git diff or swagger delta is collected. Recipient picks it up via /pickup, designs/implements, then handoffs back with responds_to=<this id>.",
		InputSchema: schema,
		Handler:     submitRequestHandler,
	}
}

type submitRequestArgs struct {
	Summary         string   `json:"summary"`
	To              string   `json:"to"`
	Project         string   `json:"project"`
	Org             string   `json:"org"`
	Member          string   `json:"member"`
	Urgent          bool     `json:"urgent"`
	Note            string   `json:"note"`
	Prd             string   `json:"prd"`
	AttachmentPaths []string `json:"attachment_paths"`
	CWD             string   `json:"cwd"`
}

func submitRequestHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a submitRequestArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.ResolveRelay(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	repoRoot := config.RepoRoot(cwd)
	inboxDir := inbox.InboxDir(repoRoot, res.InboxOverride)

	if a.Summary != "" {
		if err := writeDraftSummary(inboxDir, a.Summary); err != nil {
			return ToolResult{}, err
		}
	}

	client := transport.New(res.RelayURL, res.Token)
	recipients, recipient, err := resolveToolRecipients(ctx, client, res.Me, res.Partner, a.To, a.Project, a.Org, a.Member)
	if err != nil {
		return ToolResult{}, err
	}

	urgency := handoffschema.UrgencyNormal
	if a.Urgent {
		urgency = handoffschema.UrgencyUrgent
	}

	extras, _, err := readAttachments(cwd, a.AttachmentPaths)
	if err != nil {
		return ToolResult{}, err
	}

	var fanout []string
	if len(recipients) > 1 {
		fanout = recipients
	}
	pkg, attachments, err := handoff.Build(ctx, handoff.BuildOptions{
		RepoRoot:         repoRoot,
		RepoName:         res.RepoName,
		Sender:           res.Me,
		Recipient:        recipient,
		Recipients:       fanout,
		Urgency:          urgency,
		Note:             a.Note,
		Prd:              a.Prd,
		Kind:             handoffschema.KindRequest,
		InboxDir:         inboxDir,
		ExtraAttachments: extras,
		DeliveryTarget:   deliveryTarget(a.Project, a.Org, a.Member),
	})
	if err != nil {
		return ToolResult{}, err
	}

	out, err := client.Submit(ctx, pkg, attachments)
	if err != nil {
		return ToolResult{}, err
	}

	var sb strings.Builder
	fmt.Fprintf(&sb, "Submitted request `%s` to %s.\n\n", out.ID, formatRecipientList(recipients))
	sb.WriteString("- kind: request\n")
	writeRepoMetaLines(&sb, pkg)
	writeDeliveryTargetSummary(&sb, pkg.DeliveryTarget)
	writeAttachmentSummary(&sb, pkg)
	sb.WriteString("\nThe partner will pick it up via /pickup; their prompt will guide them to design/implement. When they handoff back, the package will carry `responds_to=" + out.ID + "`.")
	sb.WriteString(linearSyncBlock(res.Linear, LinearEventSubmit, LinearSyncCtx{
		HandoffID: out.ID,
		IsRequest: true,
	}))
	return textResult(sb.String()), nil
}

func submitBugTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "summary": {"type": "string", "description": "Markdown 描述 bug：症状 / 复现步骤 / 期望 / 实际 / 怀疑归属(可选)。会写入 <inbox-dir>/.draft-summary.md；省略则用现有 draft（如有）。"},
    "to":      {"type": "array", "items": {"type": "string"}, "description": "Recipient identities（一个或多个真实 identity,例如 [\"user@backend\", \"alex@frontend\"]）。Omit to use identity.partners from .cc-handoff.toml; falls back to [identity.partner] if partners 没配。Role aliases \"backend\" / \"frontend\" / \"both\" are accepted only as convenience and will be resolved against configured identities."},
    "project": {"type": "string", "description": "Project id to report this bug to all actionable project recipients (direct owners/members plus team owners/admins). Mutually exclusive with to and org; excludes yourself and viewers."},
    "org":     {"type": "string", "description": "Organization id to report this bug to all actionable organization members (owners/admins/members). Mutually exclusive with to and project; excludes yourself and guests."},
    "member":  {"type": "string", "description": "With project/org, report only to this identity after validating they are an actionable member of that team."},
    "urgent":  {"type": "boolean", "description": "Mark as urgent. Recipients with auto_launch=true will spawn a new terminal each."},
    "note":    {"type": "string", "description": "测试备注 / 验收标准 markdown。会以「⚠️ 测试备注 / 验收标准 (必读)」段渲染到接收端 prompt，被要求逐条响应。没有就不传。"},
    "prd":     {"type": "string", "description": "产品需求 / 设计意图 markdown（背景参考），帮接收端理解 bug 背后的业务目的。没有就不传。"},
    "attachment_paths": {"type": "array", "items": {"type": "string"}, "description": "可选,本地文件路径数组(绝对或相对 cwd)。截图 / HAR / 控制台日志 / 录屏 都行,单文件 ≤ 50MB,同 basename 自动加序号。接收端 pickup 后会在 prompt 顶部的「📎 附件」段看到列表,并被引导用 Read 打开它们辅助判定 bug 归属。"},
    "cwd":     {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  }
}`)
	return Tool{
		Name:        ToolSubmitBug,
		Description: "Report a bug from the test/QA side to one or more engineering identities at once. Prefer omitting `to` so configured identity.partners are used, or pass real identities such as [\"user@backend\", \"alex@frontend\"]. Role aliases \"backend\" / \"frontend\" / \"both\" are resolved against configured identities. The receivers' prompt walks them through a decision tree: judge if the bug is on their side → fix it / call reassign_bug to forward it / call comment_handoff to discuss cross-end. Comments on any handoff in the resulting bug group are auto-broadcast to every participant so the tester stays in the loop without manually relaying.",
		InputSchema: schema,
		Handler:     submitBugHandler,
	}
}

type submitBugArgs struct {
	Summary         string   `json:"summary"`
	To              []string `json:"to"`
	Project         string   `json:"project"`
	Org             string   `json:"org"`
	Member          string   `json:"member"`
	Urgent          bool     `json:"urgent"`
	Note            string   `json:"note"`
	Prd             string   `json:"prd"`
	AttachmentPaths []string `json:"attachment_paths"`
	CWD             string   `json:"cwd"`
}

func submitBugHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a submitBugArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.ResolveRelay(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	repoRoot := config.RepoRoot(cwd)
	inboxDir := inbox.InboxDir(repoRoot, res.InboxOverride)

	if a.Summary != "" {
		if err := writeDraftSummary(inboxDir, a.Summary); err != nil {
			return ToolResult{}, err
		}
	}

	client := transport.New(res.RelayURL, res.Token)
	var recipients []string
	if a.Project != "" || a.Org != "" || a.Member != "" {
		if len(a.To) > 0 {
			return ToolResult{}, fmt.Errorf("to cannot be combined with project/org/member")
		}
		recipients, _, err = resolveToolRecipients(ctx, client, res.Me, "", "", a.Project, a.Org, a.Member)
		if err != nil {
			return ToolResult{}, err
		}
	} else {
		recipients, err = resolveBugRecipients(a.To, res)
		if err != nil {
			return ToolResult{}, err
		}
		if len(recipients) == 0 {
			recipients = append([]string(nil), res.Partners...)
		}
		if len(recipients) == 0 {
			return ToolResult{}, fmt.Errorf("no recipients: pass `to=[\"backend\",\"frontend\",...]`, `project`, `org`, or set identity.partners in .cc-handoff.toml")
		}
		for _, r := range recipients {
			if r == res.Me {
				return ToolResult{}, fmt.Errorf("cannot send a bug to yourself (%s)", r)
			}
		}
	}

	urgency := handoffschema.UrgencyNormal
	if a.Urgent {
		urgency = handoffschema.UrgencyUrgent
	}

	extras, _, err := readAttachments(cwd, a.AttachmentPaths)
	if err != nil {
		return ToolResult{}, err
	}

	pkg, attachments, err := handoff.Build(ctx, handoff.BuildOptions{
		RepoRoot:         repoRoot,
		RepoName:         res.RepoName,
		Sender:           res.Me,
		Recipients:       recipients,
		Urgency:          urgency,
		Note:             a.Note,
		Prd:              a.Prd,
		Kind:             handoffschema.KindBug,
		InboxDir:         inboxDir,
		ExtraAttachments: extras,
		DeliveryTarget:   deliveryTarget(a.Project, a.Org, a.Member),
	})
	if err != nil {
		return ToolResult{}, err
	}

	out, err := client.Submit(ctx, pkg, attachments)
	if err != nil {
		return ToolResult{}, err
	}

	var sb strings.Builder
	fmt.Fprintf(&sb, "Submitted bug `%s` to %s.\n\n", out.ID, formatRecipientList(recipients))
	sb.WriteString("- kind: bug\n")
	writeRepoMetaLines(&sb, pkg)
	writeDeliveryTargetSummary(&sb, pkg.DeliveryTarget)
	writeAttachmentSummary(&sb, pkg)
	sb.WriteString("\n每个收件人 /pickup 后会看到「归属判断决策树」:\n")
	sb.WriteString("- 是我的 → 修复 + ack\n")
	sb.WriteString("- 不是我的 → mcp__cc-handoff__reassign_bug 转给对端\n")
	sb.WriteString("- 不确定 → comment_handoff 拉对端协商\n\n")
	sb.WriteString("整个 bug_group 内的评论会自动同步,你不用人肉中转。用 status_handoff 看每端 pickup 状态。")
	sb.WriteString(linearSyncBlock(res.Linear, LinearEventSubmit, LinearSyncCtx{HandoffID: out.ID}))
	return textResult(sb.String()), nil
}

func resolveBugRecipients(to []string, res *config.Resolved) ([]string, error) {
	out := make([]string, 0, len(to))
	for _, raw := range to {
		v := strings.TrimSpace(raw)
		if v == "" {
			continue
		}
		role := strings.ToLower(v)
		switch role {
		case "both", "all":
			out = append(out, res.Partners...)
		case "frontend", "backend":
			resolved, err := resolveRecipientRole(role, res)
			if err != nil {
				return nil, err
			}
			out = append(out, resolved)
		default:
			out = append(out, v)
		}
	}
	return handoffschema.DedupeIdentities(out), nil
}

func deliveryTarget(projectID, orgID, member string) *handoffschema.DeliveryTarget {
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

func resolveRecipientRole(role string, res *config.Resolved) (string, error) {
	for _, candidate := range res.Partners {
		if strings.EqualFold(candidate, role) {
			return candidate, nil
		}
	}
	for _, candidate := range res.Partners {
		if identityMatchesRole(candidate, role) {
			return candidate, nil
		}
	}
	if strings.EqualFold(res.Me, role) || identityMatchesRole(res.Me, role) {
		return "", fmt.Errorf("role %q resolves to yourself (%s); pass the real recipient identity or update identity.partners", role, res.Me)
	}
	return "", fmt.Errorf("cannot resolve role %q to a recipient identity; pass the real identity (e.g. alex@frontend) or set identity.partners in .cc-handoff.toml", role)
}

func identityMatchesRole(identity, role string) bool {
	identity = strings.ToLower(identity)
	role = strings.ToLower(role)
	if identity == role {
		return true
	}
	for _, sep := range []string{"@", "/", ":", "-", "_", "."} {
		if strings.HasSuffix(identity, sep+role) || strings.Contains(identity, sep+role+sep) {
			return true
		}
	}
	return false
}

func reassignBugTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "id":     {"type": "string", "description": "Bug handoff id you currently own and want to forward (e.g. h_20260519_ABCD1234)."},
    "to":     {"type": "string", "description": "Recipient identity to forward the bug to (the other engineering side)."},
    "reason": {"type": "string", "description": "为什么这个 bug 是对方的 —— 一段话写清楚为什么不是你这边的问题（可以是「字段是前端拼的」「我看了 handler 没问题，怀疑是 CSS」之类）。会作为横幅渲染在对端的 pickup prompt 顶部。"},
    "cwd":    {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  },
  "required": ["id", "to"]
}`)
	return Tool{
		Name:        ToolReassignBug,
		Description: "Forward a bug handoff to the other engineering side after judging the root cause is on their side. Closes your slot on the current bug handoff and creates a fresh one for `to`, sharing the original bug_group_id so the tester + original side + new side all see comments synced. Returns the new handoff id. Refuses with 409 if `to` already has an open slot in the same bug group (avoids reassign loops — use comment_handoff to coordinate instead).",
		InputSchema: schema,
		Handler:     reassignBugHandler,
	}
}

type reassignBugArgs struct {
	ID     string `json:"id"`
	To     string `json:"to"`
	Reason string `json:"reason"`
	CWD    string `json:"cwd"`
}

func reassignBugHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a reassignBugArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	if a.ID == "" {
		return ToolResult{}, fmt.Errorf("id is required")
	}
	if a.To == "" {
		return ToolResult{}, fmt.Errorf("to is required")
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	if a.To == res.Me {
		return ToolResult{}, fmt.Errorf("cannot reassign to yourself")
	}

	client := transport.New(res.RelayURL, res.Token)
	out, err := client.Reassign(ctx, a.ID, a.To, a.Reason)
	if err != nil {
		return ToolResult{}, err
	}

	var sb strings.Builder
	fmt.Fprintf(&sb, "Reassigned bug `%s` → `%s`.\n\n", a.ID, a.To)
	fmt.Fprintf(&sb, "- new handoff id: `%s`\n", out.ID)
	if out.BugGroupID != "" {
		fmt.Fprintf(&sb, "- bug_group_id: `%s`\n", out.BugGroupID)
	}
	if a.Reason != "" {
		sb.WriteString("- reason was rendered on the receiver's prompt banner\n")
	}
	sb.WriteString("\n你这一格已经关闭(state=reassigned)。后续 group 内任何一方的评论你还能在 list_history / comment SSE 里看到。")
	return textResult(sb.String()), nil
}

// formatRecipientList renders ["backend", "frontend"] as "`backend`, `frontend`".
func formatRecipientList(rs []string) string {
	quoted := make([]string, 0, len(rs))
	for _, r := range rs {
		quoted = append(quoted, "`"+r+"`")
	}
	return strings.Join(quoted, ", ")
}

func resolveToolRecipients(ctx context.Context, client *transport.Client, sender, defaultRecipient, to, projectID, orgID, member string) ([]string, string, error) {
	if (projectID != "" || orgID != "") && to != "" {
		return nil, "", fmt.Errorf("to cannot be combined with project or org")
	}
	if projectID != "" || orgID != "" {
		recipients, err := client.ResolveTeamRecipients(ctx, projectID, orgID, sender, member)
		if err != nil {
			return nil, "", err
		}
		if len(recipients) == 0 {
			if projectID != "" {
				return nil, "", fmt.Errorf("project %s has no actionable recipients (direct owners/members or team owners/admins other than %s)", projectID, sender)
			}
			return nil, "", fmt.Errorf("organization %s has no actionable recipients (owners/admins/members other than %s)", orgID, sender)
		}
		return recipients, recipients[0], nil
	}
	if member != "" {
		return nil, "", fmt.Errorf("member requires project or org")
	}
	recipient := defaultRecipient
	if to != "" {
		recipient = to
	}
	if recipient == "" {
		return nil, "", fmt.Errorf("no recipient: pass `to`, `project`, `org`, or set identity.partner in .cc-handoff.toml")
	}
	if recipient == sender {
		return nil, "", fmt.Errorf("cannot send to yourself (%s)", sender)
	}
	return []string{recipient}, recipient, nil
}

func filterOnlineUsers(users []handoffschema.OnlineUser, identities []string) []handoffschema.OnlineUser {
	allowed := map[string]bool{}
	for _, id := range identities {
		allowed[id] = true
	}
	out := make([]handoffschema.OnlineUser, 0, len(users))
	for _, u := range users {
		if allowed[u.Identity] {
			out = append(out, u)
		}
	}
	return out
}

func listInboxTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "project":      {"type": "string", "description": "Optional project id. When set, lists project-shared handoffs for that project instead of only your personal pending inbox."},
    "all_projects": {"type": "boolean", "description": "When true, lists project-shared handoffs across every project you belong to."},
    "limit":        {"type": "integer", "description": "Max items for project-shared listing. Defaults to 100."},
    "cwd": {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  }
}`)
	return Tool{
		Name:        ToolListInbox,
		Description: "List handoffs pending for me on the relay. Use this before " + ToolPickupHandoff + " to see what's available.",
		InputSchema: schema,
		Handler:     listInboxHandler,
	}
}

type listArgs struct {
	Project     string `json:"project"`
	AllProjects bool   `json:"all_projects"`
	Limit       int    `json:"limit"`
	CWD         string `json:"cwd"`
}

func listInboxHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a listArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.ResolveRelay(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	client := transport.New(res.RelayURL, res.Token)
	var items []handoffschema.ListItem
	if a.Project != "" || a.AllProjects {
		if a.Project != "" && a.AllProjects {
			return ToolResult{}, fmt.Errorf("project and all_projects are mutually exclusive")
		}
		items, err = client.ListProjectHandoffs(ctx, a.Project, a.Limit)
	} else {
		items, err = client.List(ctx, res.Me)
	}
	if err != nil {
		return ToolResult{}, err
	}
	if len(items) == 0 {
		if a.Project != "" || a.AllProjects {
			return textResult("No project-shared handoffs found."), nil
		}
		return textResult("Inbox is empty."), nil
	}
	var sb strings.Builder
	if a.Project != "" || a.AllProjects {
		fmt.Fprintf(&sb, "%d project-shared item(s):\n\n", len(items))
	} else {
		fmt.Fprintf(&sb, "%d pending item(s):\n\n", len(items))
	}
	for _, it := range items {
		fmt.Fprintf(&sb, "- [%s] `%s` from `%s` urgency=%s repo=`%s` branch=`%s`\n  %s\n",
			tagFor(it.Kind), it.ID, it.Sender, it.Urgency, it.RepoName, it.Branch, it.Headline)
	}
	sb.WriteString("\nUse " + ToolPickupHandoff + " with one of these ids to materialize and start work. `[REQUEST]` items are reverse-direction asks (the sender wants you to add/change something); the materialized prompt will guide you.")
	return textResult(sb.String()), nil
}

// tagFor renders the inbox/sent list label for a Kind. Empty Kind (legacy
// payloads) is treated as a delivery handoff.
func tagFor(k handoffschema.Kind) string {
	switch k {
	case handoffschema.KindRequest:
		return "REQUEST"
	case handoffschema.KindBug:
		return "BUG"
	case handoffschema.KindCapsule:
		return "CAPSULE"
	}
	return "handoff"
}

func pickupHandoffTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "id":      {"type": "string", "description": "Handoff id (e.g. h_20260428_ABCD1234)"},
    "no_ack":  {"type": "boolean", "description": "Skip marking the handoff as picked on the relay."},
    "direct":  {"type": "boolean", "description": "If true, the returned prompt instructs the receiver to modify code directly and stop after the diff for review. Default false: the prompt requires producing docs/integrations/<id>.md first and stopping for human review of the plan. Pass true only when the user has explicitly asked for direct/fast pickup."},
    "worktree": {"type": "boolean", "description": "If true, create an isolated git worktree under <repo>/.worktrees on a dedicated branch (h_<shortid>_<senderBranch>) and materialize into it, so the integration happens off the main checkout. The tool only creates and materializes; it does not start an agent."},
    "cwd":     {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  },
  "required": ["id"]
}`)
	return Tool{
		Name:        ToolPickupHandoff,
		Description: "Fetch a handoff by id, materialize it under <inbox-dir>/<id>/ (default .cc-handoff/inbox; legacy .claude/handoff-inbox preserved on older repos), ack it on the relay, and return the integration prompt as the tool result. After this returns, you should follow the returned prompt to integrate the changes. Default mode produces an integration doc; pass direct=true to skip the doc and modify code directly.",
		InputSchema: schema,
		Handler:     pickupHandoffHandler,
	}
}

type pickupArgs struct {
	ID       string `json:"id"`
	NoAck    bool   `json:"no_ack"`
	Direct   bool   `json:"direct"`
	Worktree bool   `json:"worktree"`
	CWD      string `json:"cwd"`
}

func pickupHandoffHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a pickupArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	if a.ID == "" {
		return ToolResult{}, fmt.Errorf("id is required")
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	client := transport.New(res.RelayURL, res.Token)
	pkg, err := client.Get(ctx, a.ID)
	if err != nil {
		return ToolResult{}, err
	}
	mode := inbox.ModeDocFirst
	if a.Direct {
		mode = inbox.ModeDirect
	}

	// With worktree=true, carve an isolated worktree on a dedicated branch and
	// materialize into it. The tool never starts an agent (headless: there's no
	// terminal to launch into).
	repoRoot := config.RepoRoot(cwd)
	materializeRoot := repoRoot
	var worktreeDir string
	if a.Worktree {
		branch := config.HandoffWorktreeBranch(pkg.ID, pkg.Repo.Branch)
		worktreeDir = config.WorktreeDir(repoRoot, branch)
		if err := gitsrc.CarveWorktree(ctx, repoRoot, worktreeDir, branch, ""); err != nil {
			return ToolResult{}, err
		}
		materializeRoot = worktreeDir
	}

	mat, err := inbox.Materialize(inbox.InboxDir(materializeRoot, res.InboxOverride), pkg, mode)
	if err != nil {
		return ToolResult{}, err
	}
	if err := inbox.DownloadAttachments(ctx, client, mat.Dir, pkg); err != nil {
		fmt.Fprintf(os.Stderr, "mcp: download attachments %s: %v\n", a.ID, err)
	}
	if !a.NoAck {
		if err := client.Ack(ctx, a.ID); err != nil {
			// Not fatal — files are already on disk.
			fmt.Fprintf(os.Stderr, "mcp: ack %s failed: %v\n", a.ID, err)
		}
	}
	var sb strings.Builder
	if a.Worktree {
		fmt.Fprintf(&sb, "Created worktree `%s` for handoff `%s`. Files materialized at `%s`.\n\n", worktreeDir, pkg.ID, mat.Dir)
	} else {
		fmt.Fprintf(&sb, "Picked up handoff `%s`. Files materialized at `%s`.\n\n", pkg.ID, mat.Dir)
	}
	sb.WriteString("Follow the prompt below to integrate the changes:\n\n---\n\n")
	sb.WriteString(mat.Prompt)
	sb.WriteString(linearSyncBlock(res.Linear, LinearEventPickup, LinearSyncCtx{
		HandoffID: pkg.ID,
		Me:        res.Me,
	}))
	return textResult(sb.String()), nil
}

func commentHandoffTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "id":   {"type": "string", "description": "Handoff id (e.g. h_20260428_ABCD1234)"},
    "body": {"type": "string", "description": "Comment text. Markdown is fine."},
    "list": {"type": "boolean", "description": "If true, return existing comments instead of posting a new one. body is then ignored."},
    "attachment_paths": {"type": "array", "items": {"type": "string"}, "description": "可选,本地文件路径数组(绝对或相对 cwd),作为附件挂到这条 handoff 上;同时 comment 正文末尾会自动追加 一行 「📎 attached: name1, name2...」,接收端 watch 写 comments.md 时也能看到这条引用。任意类型 ≤ 50MB,同 basename 自动加序号。"},
    "cwd":  {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  },
  "required": ["id"]
}`)
	return Tool{
		Name:        ToolCommentHandoff,
		Description: "Post a back-channel comment on a handoff (sender↔receiver chat), or list existing comments. The other side gets a comment.created SSE event so cc-handoff watch can surface it.",
		InputSchema: schema,
		Handler:     commentHandoffHandler,
	}
}

type commentArgs struct {
	ID              string   `json:"id"`
	Body            string   `json:"body"`
	List            bool     `json:"list"`
	AttachmentPaths []string `json:"attachment_paths"`
	CWD             string   `json:"cwd"`
}

func commentHandoffHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a commentArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	if a.ID == "" {
		return ToolResult{}, fmt.Errorf("id is required")
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	client := transport.New(res.RelayURL, res.Token)

	if a.List {
		comments, err := client.ListComments(ctx, a.ID)
		if err != nil {
			return ToolResult{}, err
		}
		if len(comments) == 0 {
			return textResult("No comments on " + a.ID + " yet."), nil
		}
		var sb strings.Builder
		fmt.Fprintf(&sb, "%d comment(s) on `%s`:\n\n", len(comments), a.ID)
		for _, c := range comments {
			fmt.Fprintf(&sb, "- **%s** at %s:\n  %s\n",
				c.Sender, c.CreatedAt.Format("2006-01-02 15:04:05"), c.Body)
		}
		return textResult(sb.String()), nil
	}

	// Read attachments up-front so we can fail before posting the comment
	// (avoids a half-state where the comment lands but uploads error out).
	// Order is preserved so the body footer lists attachments in the order
	// the user wrote them.
	extras, names, err := readAttachments(cwd, a.AttachmentPaths)
	if err != nil {
		return ToolResult{}, err
	}

	body := a.Body
	if len(names) > 0 {
		// Append a marker line so receivers see what files came along even
		// when reading comments.md in isolation (without the handoff's
		// attachments listing).
		if body != "" && !strings.HasSuffix(body, "\n") {
			body += "\n"
		}
		body += "\n📎 attached: " + strings.Join(names, ", ")
	}
	if body == "" {
		return ToolResult{}, fmt.Errorf("body is required when not listing (or pass attachment_paths)")
	}

	c, err := client.Comment(ctx, a.ID, body)
	if err != nil {
		return ToolResult{}, err
	}

	var uploaded, failed []string
	for _, name := range names {
		if err := client.UploadAttachment(ctx, a.ID, name, extras[name]); err != nil {
			failed = append(failed, fmt.Sprintf("%s (%v)", name, err))
			continue
		}
		uploaded = append(uploaded, name)
	}

	var sb strings.Builder
	fmt.Fprintf(&sb, "Posted comment #%d on `%s`. The other side will be notified via SSE.", c.ID, c.HandoffID)
	if len(uploaded) > 0 {
		fmt.Fprintf(&sb, "\n- attached: %s", strings.Join(uploaded, ", "))
	}
	if len(failed) > 0 {
		fmt.Fprintf(&sb, "\n- ⚠️ failed uploads: %s — comment is posted but these files didn't go up; retry by re-running comment_handoff with the same paths.", strings.Join(failed, "; "))
	}
	sb.WriteString(linearSyncBlock(res.Linear, LinearEventComment, LinearSyncCtx{
		HandoffID: c.HandoffID,
		CommentBy: c.Sender,
	}))
	return textResult(sb.String()), nil
}

func resolveCWD(arg string) (string, error) {
	if arg != "" {
		return arg, nil
	}
	return os.Getwd()
}

// readAttachments reads user-provided file paths into a name→bytes map ready
// to hand to handoff.BuildOptions.ExtraAttachments / Client.UploadAttachment.
// Paths may be absolute or relative to cwd. basename collisions get a -2 /
// -3 / … suffix before the file extension so two `screenshot.png` from
// different directories both survive. Reserved names (swagger.yaml) are
// rejected outright — the user should rename their file.
func readAttachments(cwd string, paths []string) (map[string][]byte, []string, error) {
	if len(paths) == 0 {
		return nil, nil, nil
	}
	out := make(map[string][]byte, len(paths))
	order := make([]string, 0, len(paths))
	for _, raw := range paths {
		p := raw
		if !filepath.IsAbs(p) {
			p = filepath.Join(cwd, p)
		}
		fi, err := os.Stat(p)
		if err != nil {
			return nil, nil, fmt.Errorf("attachment %q: %w", raw, err)
		}
		if fi.IsDir() {
			return nil, nil, fmt.Errorf("attachment %q is a directory; pass individual files", raw)
		}
		if fi.Size() > handoff.AttachmentMaxBytes {
			return nil, nil, fmt.Errorf("attachment %q is %d bytes; max is %d", raw, fi.Size(), handoff.AttachmentMaxBytes)
		}
		base := filepath.Base(p)
		if base == handoff.SwaggerSnapshotName {
			return nil, nil, fmt.Errorf("attachment name %q is reserved (rename the file)", base)
		}
		name := uniqueAttachmentName(base, out)
		body, err := os.ReadFile(p)
		if err != nil {
			return nil, nil, fmt.Errorf("read attachment %q: %w", raw, err)
		}
		out[name] = body
		order = append(order, name)
	}
	return out, order, nil
}

// uniqueAttachmentName returns base when it isn't already in taken, otherwise
// appends -2 / -3 / … before the extension until it is. Keeps the suffix
// before any dot so `screenshot.png` becomes `screenshot-2.png` instead of
// `screenshot.png-2`.
func uniqueAttachmentName(base string, taken map[string][]byte) string {
	if _, exists := taken[base]; !exists {
		return base
	}
	ext := filepath.Ext(base)
	stem := strings.TrimSuffix(base, ext)
	for i := 2; ; i++ {
		candidate := fmt.Sprintf("%s-%d%s", stem, i, ext)
		if _, exists := taken[candidate]; !exists {
			return candidate
		}
	}
}

func writeDraftSummary(inboxDir, content string) error {
	p := handoff.SummaryDraftPath(inboxDir)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	return os.WriteFile(p, []byte(content), 0o644)
}

func textResult(s string) ToolResult {
	return ToolResult{Content: []ContentBlock{{Type: ContentTypeText, Text: s}}}
}

// --- session_usage ----------------------------------------------------------

func sessionUsageTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "session_id": {"type": "string", "description": "目标本地会话 ID(如 ts2)或名称(见 msg list)。读取它对应的 claude/codex 的 token 用量。"}
  },
  "required": ["session_id"]
}`)
	return Tool{
		Name:        ToolSessionUsage,
		Description: "Read a same-machine peer session's token usage for the claude/codex running in it: cumulative tokens (input/output/cache), current context-window %, estimated USD cost, model, and busy/idle. Local-bus only — the target must be a session on THIS machine and the desktop app must be running (it computes the usage from the agent's on-disk transcript). Returns the raw JSON snapshot.",
		InputSchema: schema,
		Handler:     sessionUsageHandler,
	}
}

func sessionUsageHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a struct {
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, err
	}
	if strings.TrimSpace(a.SessionID) == "" {
		return textResult("session_id 不能为空"), nil
	}
	// Reuse the CLI's local-bus handshake by invoking ourselves: the MCP server IS
	// the cc-handoff binary, spawned by the agent's session, so it inherits the
	// app-injected CC_BUS_DIR / CC_SESSION_ID that `msg usage` needs. Shelling to
	// self keeps one source of truth for the outbox protocol (see msg.go).
	self, err := os.Executable()
	if err != nil {
		return textResult("无法定位 cc-handoff 可执行文件: " + err.Error()), nil
	}
	out, err := exec.CommandContext(ctx, self, "msg", "usage", a.SessionID).CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return textResult("读取用量失败: " + msg), nil
	}
	return textResult(strings.TrimSpace(string(out))), nil
}

// --- status_handoff ---------------------------------------------------------

func statusHandoffTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "id":  {"type": "string", "description": "Handoff id (e.g. h_20260428_ABCD1234)"},
    "cwd": {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  },
  "required": ["id"]
}`)
	return Tool{
		Name:        ToolStatusHandoff,
		Description: "Show the current state of a handoff: pending / picked / retracted, when picked, comment count, and the latest comment summary. Use to check whether the recipient has read a handoff you sent before nudging them via comment.",
		InputSchema: schema,
		Handler:     statusHandoffHandler,
	}
}

type statusArgs struct {
	ID  string `json:"id"`
	CWD string `json:"cwd"`
}

func statusHandoffHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a statusArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	if a.ID == "" {
		return ToolResult{}, fmt.Errorf("id is required")
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	client := transport.New(res.RelayURL, res.Token)
	st, err := client.Status(ctx, a.ID)
	if err != nil {
		return ToolResult{}, err
	}
	return textResult(statusfmt.Markdown(st)), nil
}

// --- list_sent --------------------------------------------------------------

func listSentTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "limit": {"type": "integer", "description": "Max items, defaults to 20."},
    "cwd":   {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  }
}`)
	return Tool{
		Name:        ToolListSent,
		Description: "List handoffs you (the caller's identity) have sent recently, newest-first, with state. Useful for checking which of your past handoffs are still pending vs picked up.",
		InputSchema: schema,
		Handler:     listSentHandler,
	}
}

type listSentArgs struct {
	Limit int    `json:"limit"`
	CWD   string `json:"cwd"`
}

func listSentHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a listSentArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	if a.Limit <= 0 {
		a.Limit = 20
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	client := transport.New(res.RelayURL, res.Token)
	items, err := client.ListSent(ctx, a.Limit)
	if err != nil {
		return ToolResult{}, err
	}
	if len(items) == 0 {
		return textResult("You haven't sent any handoffs yet."), nil
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "%d sent item(s):\n\n", len(items))
	for _, it := range items {
		fmt.Fprintf(&sb, "- [%s] `%s` to `%s` state=%s urgency=%s repo=`%s` created=%s\n  %s\n",
			tagFor(it.Kind), it.ID, it.Recipient, it.State, it.Urgency, it.RepoName,
			it.CreatedAt.Format("2006-01-02 15:04:05"), it.Headline)
	}
	return textResult(sb.String()), nil
}

// --- list_history -----------------------------------------------------------

func listHistoryTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "limit": {"type": "integer", "description": "Max items, defaults to 20."},
    "cwd":   {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  }
}`)
	return Tool{
		Name:        ToolListHistory,
		Description: "List handoffs you (the caller's identity) have already picked up from the relay (state=picked), newest-first. Use this to look back at handoffs you received and acted on previously — " + ToolListInbox + " only shows pending items, this surfaces the rest. Different from " + ToolListLocalInbox + " (which reads this repo's local inbox dir): this query hits the relay and covers receipts across all your repos.",
		InputSchema: schema,
		Handler:     listHistoryHandler,
	}
}

type listHistoryArgs struct {
	Limit int    `json:"limit"`
	CWD   string `json:"cwd"`
}

func listHistoryHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a listHistoryArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	if a.Limit <= 0 {
		a.Limit = 20
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	client := transport.New(res.RelayURL, res.Token)
	items, err := client.ListHistory(ctx, a.Limit)
	if err != nil {
		return ToolResult{}, err
	}
	if len(items) == 0 {
		return textResult("No picked-up handoffs in your history yet."), nil
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "%d picked-up item(s):\n\n", len(items))
	for _, it := range items {
		fmt.Fprintf(&sb, "- [%s] `%s` from `%s` urgency=%s repo=`%s` branch=`%s` created=%s\n  %s\n",
			tagFor(it.Kind), it.ID, it.Sender, it.Urgency, it.RepoName, it.Branch,
			it.CreatedAt.Format("2006-01-02 15:04:05"), it.Headline)
	}
	sb.WriteString("\nUse " + ToolStatusHandoff + " <id> for picked_at + comment summary, or " + ToolCommentHandoff + " <id> to follow up.")
	return textResult(sb.String()), nil
}

// --- retract_handoff --------------------------------------------------------

func retractHandoffTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "id":     {"type": "string", "description": "Handoff id to retract."},
    "reason": {"type": "string", "description": "Optional reason; surfaced to the recipient via SSE."},
    "cwd":    {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  },
  "required": ["id"]
}`)
	return Tool{
		Name:        ToolRetractHandoff,
		Description: "Cancel a still-pending handoff you sent (sender-only). Use when you realized the diff was wrong / wrong recipient / wrong branch — only works before the recipient picks it up. After pickup, coordinate via " + ToolCommentHandoff + " instead.",
		InputSchema: schema,
		Handler:     retractHandoffHandler,
	}
}

type retractArgs struct {
	ID     string `json:"id"`
	Reason string `json:"reason"`
	CWD    string `json:"cwd"`
}

func retractHandoffHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a retractArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	if a.ID == "" {
		return ToolResult{}, fmt.Errorf("id is required")
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	client := transport.New(res.RelayURL, res.Token)
	if err := client.Retract(ctx, a.ID, a.Reason); err != nil {
		return ToolResult{}, err
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "Retracted `%s`. Recipient watch will be notified.", a.ID)
	sb.WriteString(linearSyncBlock(res.Linear, LinearEventRetract, LinearSyncCtx{
		HandoffID: a.ID,
		Reason:    a.Reason,
	}))
	return textResult(sb.String()), nil
}

// --- list_local_inbox -------------------------------------------------------

func listLocalInboxTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "cwd": {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  }
}`)
	return Tool{
		Name:        ToolListLocalInbox,
		Description: "List handoffs already materialized into this repo's local inbox dir (.cc-handoff/inbox/<id>/). Unlike " + ToolListInbox + " (which queries the relay for pending), this reads disk and includes already-picked, already-retracted, and commented handoffs. Useful when the user asks 'what's been on my desk lately?'.",
		InputSchema: schema,
		Handler:     listLocalInboxHandler,
	}
}

type listLocalArgs struct {
	CWD string `json:"cwd"`
}

// --- list_online_users ------------------------------------------------------

func listOnlineUsersTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "project": {"type": "string", "description": "Optional project id. When set, only list identities with effective access to this project (direct members plus team owners/admins)."},
    "org":     {"type": "string", "description": "Optional organization id. When set, only list identities that belong to this organization."},
    "member":  {"type": "string", "description": "With project/org, only list this identity after validating they belong to that team."},
    "cwd": {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  }
}`)
	return Tool{
		Name:        ToolListOnlineUsers,
		Description: "List identities registered on the relay with a per-row online flag (true = currently holds an SSE subscription via `cc-handoff watch`). Can be filtered to a project/org, or a specific member inside that team. Use this to check whether a teammate is reachable for live coordination before sending an urgent handoff or a comment.",
		InputSchema: schema,
		Handler:     listOnlineUsersHandler,
	}
}

type listOnlineArgs struct {
	Project string `json:"project"`
	Org     string `json:"org"`
	Member  string `json:"member"`
	CWD     string `json:"cwd"`
}

func listOnlineUsersHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a listOnlineArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.ResolveRelay(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	client := transport.New(res.RelayURL, res.Token)
	users, err := client.ListOnlineUsers(ctx)
	if err != nil {
		return ToolResult{}, err
	}
	if a.Project != "" || a.Org != "" || a.Member != "" {
		ids, err := client.ListTeamIdentities(ctx, a.Project, a.Org, a.Member)
		if err != nil {
			return ToolResult{}, err
		}
		users = filterOnlineUsers(users, ids)
	}
	if len(users) == 0 {
		return textResult("No identities registered on this relay."), nil
	}
	online := 0
	for _, u := range users {
		if u.Online {
			online++
		}
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "%d online of %d known identities:\n\n", online, len(users))
	for _, u := range users {
		marker := ""
		switch u.Identity {
		case res.Me:
			marker = " (you)"
		case res.Partner:
			marker = " (partner)"
		}
		status := "offline"
		if u.Online {
			status = "ONLINE"
		}
		fmt.Fprintf(&sb, "- %-7s `%s`%s\n", status, u.Identity, marker)
	}
	return textResult(sb.String()), nil
}

func listLocalInboxHandler(_ context.Context, raw json.RawMessage) (ToolResult, error) {
	var a listLocalArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	dir := inbox.InboxDir(config.RepoRoot(cwd), res.InboxOverride)
	items, err := inbox.ListLocal(dir)
	if err != nil {
		return ToolResult{}, fmt.Errorf("read %s: %w", dir, err)
	}
	if len(items) == 0 {
		return textResult(fmt.Sprintf("No materialized handoffs at `%s`.", dir)), nil
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "%d handoff(s) in local inbox `%s`:\n\n", len(items), dir)
	for _, it := range items {
		fmt.Fprintf(&sb, "- `%s` from `%s` repo=`%s` created=%s",
			it.ID, it.Sender, it.Repo, it.CreatedAt.Format("2006-01-02 15:04:05"))
		if it.AmendsHandoff != "" {
			fmt.Fprintf(&sb, " (amends `%s`)", it.AmendsHandoff)
		}
		if it.Retracted {
			sb.WriteString(" **RETRACTED**")
		}
		if it.HasComments {
			sb.WriteString(" (has comments)")
		}
		sb.WriteString("\n")
	}
	return textResult(sb.String()), nil
}

// --- check_drift ------------------------------------------------------------

func checkDriftTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "to":    {"type": "string", "description": "Limit baseline search to handoffs sent to this recipient. Defaults to identity.partner from .cc-handoff.toml."},
    "limit": {"type": "integer", "description": "How many sent items to scan looking for a baseline handoff with a swagger snapshot. Defaults to 20."},
    "cwd":   {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  }
}`)
	return Tool{
		Name:        ToolCheckDrift,
		Description: "Detect whether your local OpenAPI spec has drifted since the last handoff you shipped to the partner. Walks recent sent items, picks the newest one that carried a swagger snapshot (B3 attachment), and diffs it against the current spec on disk. If drift is found, suggests running " + ToolSubmitHandoff + " with `amends=<baseline-id>` so the partner sees this as a corrective patch rather than a new delivery. Use this before forgetting to ship a follow-up handoff after a contract change. No-op if `paths.swagger` is not configured.",
		InputSchema: schema,
		Handler:     checkDriftHandler,
	}
}

type checkDriftArgs struct {
	To    string `json:"to"`
	Limit int    `json:"limit"`
	CWD   string `json:"cwd"`
}

func checkDriftHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a checkDriftArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	if a.Limit <= 0 {
		a.Limit = 20
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	recipient := res.Partner
	if a.To != "" {
		recipient = a.To
	}
	client := transport.New(res.RelayURL, res.Token)
	result, err := drift.Detect(ctx, client, recipient, config.ResolveSwaggerPath(config.RepoRoot(cwd), res.Swagger), a.Limit)
	if err != nil {
		// ErrNoSpec isn't a tool failure — it's "you haven't configured one
		// yet". Surface as text so the agent doesn't bubble it as an error.
		if errors.Is(err, drift.ErrNoSpec) {
			return textResult("No swagger spec configured (set `paths.swagger` in `.cc-handoff.toml`)."), nil
		}
		return ToolResult{}, err
	}
	return textResult(result.Summary(recipient)), nil
}

// --- link_linear ------------------------------------------------------------

func linkLinearTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "handoff": {"type": "string", "description": "Handoff id this binding belongs to (e.g. h_20260512_ABCD1234)."},
    "issue":   {"type": "string", "description": "Linear issue identifier (e.g. ENG-456)."},
    "url":     {"type": "string", "description": "Linear issue URL (optional)."},
    "cwd":     {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  },
  "required": ["handoff", "issue"]
}`)
	return Tool{
		Name:        ToolLinkLinear,
		Description: "Record the binding between a cc-handoff handoff and a Linear issue. Call this after creating the Linear issue (via Linear MCP) so future " + ToolStatusHandoff + " / sync prompts can recover the issue id without round-tripping Linear. Writes `<inbox-dir>/sent/<handoff>/linear.json` atomically.",
		InputSchema: schema,
		Handler:     linkLinearHandler,
	}
}

type linkLinearArgs struct {
	Handoff string `json:"handoff"`
	Issue   string `json:"issue"`
	URL     string `json:"url"`
	CWD     string `json:"cwd"`
}

func linkLinearHandler(_ context.Context, raw json.RawMessage) (ToolResult, error) {
	var a linkLinearArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	if a.Handoff == "" || a.Issue == "" {
		return ToolResult{}, fmt.Errorf("handoff and issue are required")
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	inboxDir := inbox.InboxDir(config.RepoRoot(cwd), res.InboxOverride)
	out, err := inbox.WriteLinearLink(inboxDir, a.Handoff, a.Issue, a.URL)
	if err != nil {
		return ToolResult{}, err
	}
	return textResult(fmt.Sprintf("✓ linked `%s` → `%s` (%s)", a.Handoff, a.Issue, out)), nil
}

// --- linear_sync ------------------------------------------------------------

func linearSyncTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "cwd": {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  }
}`)
	return Tool{
		Name:        ToolLinearSync,
		Description: "Pull new Linear notifications (default: @-mentions only) for the authenticated user since the last sync, and return them as a markdown list. Use this when the user asks 'any new Linear @-mentions' or to manually sync without running the watch poller. Requires `linear_personal_token` in the user-level cc-handoff config.",
		InputSchema: schema,
		Handler:     linearSyncHandler,
	}
}

type linearSyncArgs struct {
	CWD string `json:"cwd"`
}

func linearSyncHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a linearSyncArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	if res.LinearPersonalToken == "" {
		return ToolResult{}, fmt.Errorf("linear_personal_token not set in user config; generate one at Linear → Account → Security & Access → Personal API Keys")
	}
	cursorPath, err := linear.CursorPath()
	if err != nil {
		return ToolResult{}, err
	}
	since, err := linear.LoadCursor(cursorPath)
	if err != nil {
		return ToolResult{}, err
	}
	client := linear.NewClient(res.LinearPersonalToken)
	items, newCursor, err := linear.PollOnce(ctx, client, since, res.Linear.Notifications.Types)
	if err != nil {
		return ToolResult{}, err
	}
	if err := linear.SaveCursor(cursorPath, newCursor); err != nil {
		return ToolResult{}, fmt.Errorf("save cursor: %w", err)
	}
	if len(items) == 0 {
		return textResult("No new Linear notifications."), nil
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "%d new Linear notification(s):\n\n", len(items))
	for _, it := range items {
		fmt.Fprintf(&sb, "- **[%s]** %s in `%s` — %s\n", it.Type, it.ActorName, it.IssueIdent, it.IssueTitle)
		if it.Snippet != "" {
			fmt.Fprintf(&sb, "  > %s\n", it.Snippet)
		}
		if it.IssueURL != "" {
			fmt.Fprintf(&sb, "  %s\n", it.IssueURL)
		}
	}
	return textResult(sb.String()), nil
}
