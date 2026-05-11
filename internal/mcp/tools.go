package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/internal/inbox"
	"github.com/cc-collaboration/internal/rules"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// Tool names — referenced from slash command markdown and from each other's
// help text, so a typo here only breaks at runtime.
const (
	ToolSubmitHandoff   = "submit_handoff"
	ToolSubmitRequest   = "submit_request"
	ToolListInbox       = "list_inbox"
	ToolPickupHandoff   = "pickup_handoff"
	ToolCommentHandoff  = "comment_handoff"
	ToolStatusHandoff   = "status_handoff"
	ToolListSent        = "list_sent"
	ToolListHistory     = "list_history"
	ToolRetractHandoff  = "retract_handoff"
	ToolListLocalInbox  = "list_local_inbox"
	ToolListOnlineUsers = "list_online_users"
)

// DefaultTools returns the tools cc-handoff exposes via MCP. They wrap the
// same internals the CLI uses so behavior stays identical.
func DefaultTools() []Tool {
	return []Tool{
		submitHandoffTool(),
		submitRequestTool(),
		listInboxTool(),
		pickupHandoffTool(),
		commentHandoffTool(),
		statusHandoffTool(),
		listSentTool(),
		listHistoryTool(),
		retractHandoffTool(),
		listLocalInboxTool(),
		listOnlineUsersTool(),
	}
}

func submitHandoffTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "summary":      {"type": "string", "description": "Markdown summary of the change. Written to <inbox-dir>/.draft-summary.md before the package is built (inbox-dir defaults to .cc-handoff/inbox, falls back to legacy .claude/handoff-inbox in older repos). If omitted, the existing draft (if any) is used."},
    "to":           {"type": "string", "description": "Recipient identity. Defaults to identity.partner from .cc-handoff.toml."},
    "urgent":       {"type": "boolean", "description": "Mark as urgent. Recipients with auto_launch=true will spawn a new terminal."},
    "note":         {"type": "string", "description": "Markdown 写的「需求 / 跨端约束」段，例如错误码对照、字段大小写规则、分页约定、不可合并的请求等。会以「⚠️ 后端备注 / 需求 (必读)」醒目段渲染到接收端 prompt，并被强制要求 INTEGRATION.md 逐条响应。短到一两句也可以；没有就不传。"},
    "prd":          {"type": "string", "description": "产品需求 / 设计意图 markdown（背景参考）。会以「📋 产品需求 / 设计意图 (背景参考)」段渲染到接收端 prompt，作为背景阅读，不要求 INTEGRATION.md 逐条响应。和 note 区分：note 是必须兑现的硬约束（必读），prd 是 why（参考）。没有就不传。"},
    "module_paths": {"type": "array", "items": {"type": "string"}, "description": "Module-brief mode: relative-to-repo-root directory paths (e.g. internal/module/oms/order). When set, the build switches to module-brief mode — git diff and Swagger delta are skipped, and summary is treated as a self-contained API contract document. Drive this from the /handoff-module slash command; do not set it manually unless you know why."},
    "responds_to":  {"type": "string", "description": "若本 handoff 是对某个对端 request (kind=request) 的回应，把 request id 填这里 (例如 h_20260507_ABCD1234)。会渲染到接收端 prompt 顶端的「↩️ 回应 xxx」段，让发起方知道此次交付是回应哪条需求。"},
    "amends":       {"type": "string", "description": "若本次 handoff 是对自己**先前已发出**的某个 handoff 的修正交付(比如 endpoint 改了字段、错误码变了、整合方案需要重做),把上次的 handoff id 填这里。会渲染到接收端 prompt 顶端的「⚠️ 修正交付」横幅,提示前端去翻原版 INTEGRATION.md 对照本次增量。和 responds_to 区分:responds_to 是「我在回应你之前发的需求」,amends 是「我之前发过的 handoff 这次要改」。没有就不传。"},
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
	Summary     string   `json:"summary"`
	To          string   `json:"to"`
	Urgent      bool     `json:"urgent"`
	Note        string   `json:"note"`
	Prd         string   `json:"prd"`
	ModulePaths []string `json:"module_paths"`
	RespondsTo  string   `json:"responds_to"`
	Amends      string   `json:"amends"`
	CWD         string   `json:"cwd"`
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
	res, err := config.Resolve(cwd)
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

	recipient := res.Partner
	if a.To != "" {
		recipient = a.To
	}
	if recipient == "" {
		return ToolResult{}, fmt.Errorf("no recipient: pass `to` or set identity.partner in .cc-handoff.toml")
	}

	urgency := handoffschema.UrgencyNormal
	if a.Urgent {
		urgency = handoffschema.UrgencyUrgent
	}

	engine, err := rules.Compile(res.Rules)
	if err != nil {
		return ToolResult{}, err
	}

	pkg, err := handoff.Build(ctx, handoff.BuildOptions{
		RepoRoot:    repoRoot,
		RepoName:    res.RepoName,
		Sender:      res.Me,
		Recipient:   recipient,
		Urgency:     urgency,
		Base:        res.Base,
		Note:        a.Note,
		Prd:         a.Prd,
		Rules:       engine,
		SwaggerPath: res.Swagger,
		ModulePaths: a.ModulePaths,
		Kind:        handoffschema.KindDelivery,
		RespondsTo:  a.RespondsTo,
		Amends:      a.Amends,
		InboxDir:    inboxDir,
	})
	if err != nil {
		return ToolResult{}, err
	}

	client := transport.New(res.RelayURL, res.Token)
	out, err := client.Submit(ctx, pkg, nil)
	if err != nil {
		return ToolResult{}, err
	}

	var sb strings.Builder
	fmt.Fprintf(&sb, "Submitted handoff `%s` to `%s`.\n\n", out.ID, recipient)
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
	return textResult(sb.String()), nil
}

func submitRequestTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "summary": {"type": "string", "description": "Markdown 描述需求：缺什么字段 / 没暴露什么能力 / 返回结构哪里有问题，写到具体 endpoint + field。包含 Why（前端要拿它做什么）和 Acceptance（怎样算 OK）。会写入 <inbox-dir>/.draft-summary.md；省略则用现有 draft（如有）。"},
    "to":      {"type": "string", "description": "Recipient identity. Defaults to identity.partner from .cc-handoff.toml."},
    "urgent":  {"type": "boolean", "description": "Mark as urgent. Recipients with auto_launch=true will spawn a new terminal."},
    "note":    {"type": "string", "description": "给后端的额外约束/备注，例如「不要破坏现有调用方」「字段命名跟 X 一致」「兼容现存数据」。会以「⚠️ 发起方备注 / 跨端约束 (必读)」段渲染到接收端 prompt，被要求逐条响应。没有就不传。"},
    "prd":     {"type": "string", "description": "前端从产品侧拿到的需求 / 设计意图 markdown（背景参考）。会以「📋 产品需求 / 设计意图 (背景参考)」段渲染到接收端 prompt，帮接收方理解这个 request 背后的业务目的。**作为背景阅读**，不要求逐条响应。和 note 区分：note 是必须兑现的硬约束（必读），prd 是 why（参考）。没有就不传。"},
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
	Summary string `json:"summary"`
	To      string `json:"to"`
	Urgent  bool   `json:"urgent"`
	Note    string `json:"note"`
	Prd     string `json:"prd"`
	CWD     string `json:"cwd"`
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
	res, err := config.Resolve(cwd)
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

	recipient := res.Partner
	if a.To != "" {
		recipient = a.To
	}
	if recipient == "" {
		return ToolResult{}, fmt.Errorf("no recipient: pass `to` or set identity.partner in .cc-handoff.toml")
	}

	urgency := handoffschema.UrgencyNormal
	if a.Urgent {
		urgency = handoffschema.UrgencyUrgent
	}

	pkg, err := handoff.Build(ctx, handoff.BuildOptions{
		RepoRoot:  repoRoot,
		RepoName:  res.RepoName,
		Sender:    res.Me,
		Recipient: recipient,
		Urgency:   urgency,
		Note:      a.Note,
		Prd:       a.Prd,
		Kind:      handoffschema.KindRequest,
		InboxDir:  inboxDir,
	})
	if err != nil {
		return ToolResult{}, err
	}

	client := transport.New(res.RelayURL, res.Token)
	out, err := client.Submit(ctx, pkg, nil)
	if err != nil {
		return ToolResult{}, err
	}

	var sb strings.Builder
	fmt.Fprintf(&sb, "Submitted request `%s` to `%s`.\n\n", out.ID, recipient)
	fmt.Fprintf(&sb, "- kind: request\n- branch: `%s`\n- head: `%s`\n",
		pkg.Repo.Branch, handoff.ShortSHA(pkg.Repo.HeadSHA))
	sb.WriteString("\nThe partner will pick it up via /pickup; their prompt will guide them to design/implement. When they handoff back, the package will carry `responds_to=" + out.ID + "`.")
	return textResult(sb.String()), nil
}

func listInboxTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
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
	CWD string `json:"cwd"`
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
	res, err := config.Resolve(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	client := transport.New(res.RelayURL, res.Token)
	items, err := client.List(ctx, res.Me)
	if err != nil {
		return ToolResult{}, err
	}
	if len(items) == 0 {
		return textResult("Inbox is empty."), nil
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "%d pending item(s):\n\n", len(items))
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
	if k == handoffschema.KindRequest {
		return "REQUEST"
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
	ID     string `json:"id"`
	NoAck  bool   `json:"no_ack"`
	Direct bool   `json:"direct"`
	CWD    string `json:"cwd"`
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
	mat, err := inbox.Materialize(inbox.InboxDir(config.RepoRoot(cwd), res.InboxOverride), pkg, mode)
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
	fmt.Fprintf(&sb, "Picked up handoff `%s`. Files materialized at `%s`.\n\n", pkg.ID, mat.Dir)
	sb.WriteString("Follow the prompt below to integrate the changes:\n\n---\n\n")
	sb.WriteString(mat.Prompt)
	return textResult(sb.String()), nil
}

func commentHandoffTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "id":   {"type": "string", "description": "Handoff id (e.g. h_20260428_ABCD1234)"},
    "body": {"type": "string", "description": "Comment text. Markdown is fine."},
    "list": {"type": "boolean", "description": "If true, return existing comments instead of posting a new one. body is then ignored."},
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
	ID   string `json:"id"`
	Body string `json:"body"`
	List bool   `json:"list"`
	CWD  string `json:"cwd"`
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

	if a.Body == "" {
		return ToolResult{}, fmt.Errorf("body is required when not listing")
	}
	c, err := client.Comment(ctx, a.ID, a.Body)
	if err != nil {
		return ToolResult{}, err
	}
	return textResult(fmt.Sprintf("Posted comment #%d on `%s`. The other side will be notified via SSE.", c.ID, c.HandoffID)), nil
}

func resolveCWD(arg string) (string, error) {
	if arg != "" {
		return arg, nil
	}
	return os.Getwd()
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
	var sb strings.Builder
	fmt.Fprintf(&sb, "handoff `%s`\n", st.ID)
	fmt.Fprintf(&sb, "- state: %s\n", st.State)
	fmt.Fprintf(&sb, "- sender: %s\n- recipient: %s\n", st.Sender, st.Recipient)
	fmt.Fprintf(&sb, "- created: %s\n", st.CreatedAt.Format("2006-01-02 15:04:05 MST"))
	if st.PickedAt != nil {
		fmt.Fprintf(&sb, "- picked: %s\n", st.PickedAt.Format("2006-01-02 15:04:05 MST"))
	} else {
		fmt.Fprintf(&sb, "- picked: (not yet)\n")
	}
	fmt.Fprintf(&sb, "- comments: %d\n", st.CommentCount)
	if st.LastComment != nil {
		fmt.Fprintf(&sb, "- last comment by %s: %s\n", st.LastComment.Sender, st.LastComment.Body)
	}
	return textResult(sb.String()), nil
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
	return textResult(fmt.Sprintf("Retracted `%s`. Recipient watch will be notified.", a.ID)), nil
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
    "cwd": {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  }
}`)
	return Tool{
		Name:        ToolListOnlineUsers,
		Description: "List identities registered on the relay with a per-row online flag (true = currently holds an SSE subscription via `cc-handoff watch`). Use this to check whether your partner is reachable for live coordination before sending an urgent handoff or a comment.",
		InputSchema: schema,
		Handler:     listOnlineUsersHandler,
	}
}

type listOnlineArgs struct {
	CWD string `json:"cwd"`
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
	res, err := config.Resolve(cwd)
	if err != nil {
		return ToolResult{}, err
	}
	client := transport.New(res.RelayURL, res.Token)
	users, err := client.ListOnlineUsers(ctx)
	if err != nil {
		return ToolResult{}, err
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
