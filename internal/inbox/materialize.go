package inbox

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// InboxDir returns the inbox root for repoRoot, honoring the optional
// override (from .cc-handoff.toml's [inbox] dir field). When override is
// empty, the path is .cc-handoff/inbox unless the repo already has the
// pre-multi-agent .claude/handoff-inbox directory, in which case that's kept
// for backwards compatibility.
//
// Production callers should resolve once at startup (config.Resolve does
// this) and pass the resolved string directly to PackageDir / Materialize /
// LoadCursor / SaveCursor — those take an inboxDir not a repoRoot, so the
// double os.Stat in the legacy fallback only runs once per CLI invocation.
func InboxDir(repoRoot, override string) string {
	return resolveDir(repoRoot, override)
}

func PackageDir(inboxDir, id string) string {
	return filepath.Join(inboxDir, id)
}

// Result is what Materialize produces: the directory and the rendered prompt
// (so callers can return the prompt to the agent without re-reading from disk).
type Result struct {
	Dir    string
	Prompt string
}

// Mode controls the prompt template renderPromptMD emits.
type Mode int

const (
	ModeDocFirst Mode = iota // write docs/integrations/<id>.md, stop, wait review
	ModeDirect               // skip the doc, modify code directly, stop for diff review
)

// AttachmentsDir returns <dir>/attachments — created on demand by DownloadAttachments.
func AttachmentsDir(dir string) string { return filepath.Join(dir, "attachments") }

// Materialize writes a Handoff Package and its derived human/agent-friendly
// views under <inboxDir>/<id>/.
func Materialize(inboxDir string, p *handoffschema.Package, mode Mode) (Result, error) {
	dir := PackageDir(inboxDir, p.ID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return Result{}, err
	}

	pretty, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return Result{}, err
	}
	if err := writeFile(filepath.Join(dir, "package.json"), pretty); err != nil {
		return Result{}, err
	}

	if err := writeFile(filepath.Join(dir, "summary.md"), []byte(renderSummaryMD(p))); err != nil {
		return Result{}, err
	}
	prompt := renderPromptMD(p, mode)
	if err := writeFile(filepath.Join(dir, "prompt.md"), []byte(prompt)); err != nil {
		return Result{}, err
	}
	if p.APIDelta != nil {
		if err := writeFile(filepath.Join(dir, "api-delta.md"), []byte(renderAPIDeltaMD(p.APIDelta))); err != nil {
			return Result{}, err
		}
	}
	return Result{Dir: dir, Prompt: prompt}, nil
}

func renderAPIDeltaMD(d *handoffschema.APIDelta) string {
	var sb strings.Builder
	sb.WriteString("# API delta\n\n")
	section := func(title string, ops []handoffschema.Operation) {
		if len(ops) == 0 {
			return
		}
		fmt.Fprintf(&sb, "## %s\n\n", title)
		for _, op := range ops {
			renderOperation(&sb, op)
		}
	}
	section("Added", d.Added)
	section("Changed", d.Changed)
	section("Removed", d.Removed)
	renderGlobalChanges(&sb, d)
	return sb.String()
}

func renderOperation(sb *strings.Builder, op handoffschema.Operation) {
	head := op.Method + " " + op.Path
	if op.Summary != "" {
		head += " — " + op.Summary
	}
	fmt.Fprintf(sb, "### %s\n\n", head)

	if op.Detail == nil {
		// Older payload, or summary-only change: just the heading is enough.
		return
	}

	if d := op.Detail.RequestBody; d != nil {
		sb.WriteString("**请求体变更**\n\n")
		renderSchemaDiff(sb, d)
	}

	if len(op.Detail.Responses) > 0 {
		codes := sortedKeys(op.Detail.Responses)
		for _, code := range codes {
			r := op.Detail.Responses[code]
			if r == nil {
				continue
			}
			if r.Body != nil {
				fmt.Fprintf(sb, "**%s 响应变更**\n\n", code)
				renderSchemaDiff(sb, r.Body)
			}
			if r.Headers != nil {
				fmt.Fprintf(sb, "**%s 响应 header 变更**\n\n", code)
				renderSchemaDiff(sb, r.Headers)
			}
		}
	}

	if d := op.Detail.Parameters; d != nil {
		sb.WriteString("**参数变更**\n\n")
		renderSchemaDiff(sb, d)
	}

	if d := op.Detail.ErrorCodes; d != nil {
		sb.WriteString("**错误码列表**\n\n")
		renderStringListLines(sb, d.Added, d.Removed)
	}

	if d := op.Detail.Security; d != nil {
		sb.WriteString("**安全要求**\n\n")
		renderStringListLines(sb, d.Added, d.Removed)
	}
}

func renderSchemaDiff(sb *strings.Builder, d *handoffschema.SchemaDiff) {
	for _, f := range d.Added {
		fmt.Fprintf(sb, "- + %s\n", formatField(f))
	}
	for _, f := range d.Removed {
		fmt.Fprintf(sb, "- - %s\n", formatField(f))
	}
	for _, c := range d.Changed {
		reason := c.Reason
		if reason == "" {
			reason = "变更"
		}
		fmt.Fprintf(sb, "- ~ `%s`: %s → %s (%s)\n", c.Path, fieldSummary(c.Before), fieldSummary(c.After), reason)
	}
	sb.WriteString("\n")
}

// fieldAttrs collects the type/format/required/nullable/enum descriptors
// of a FieldRef in a stable order. Both the "with-path" bullet form and the
// "before → after" change form share this body.
func fieldAttrs(f handoffschema.FieldRef) []string {
	var parts []string
	if f.Type != "" {
		parts = append(parts, f.Type)
	}
	if f.Format != "" {
		parts = append(parts, "format="+f.Format)
	}
	if f.Required {
		parts = append(parts, "required")
	}
	if f.Nullable {
		parts = append(parts, "nullable")
	}
	if len(f.Enum) > 0 {
		parts = append(parts, "enum=["+strings.Join(f.Enum, "|")+"]")
	}
	return parts
}

// formatField renders a FieldRef as a single bullet body, e.g.
// "`address.city` string required format=date-time enum=[a|b]".
func formatField(f handoffschema.FieldRef) string {
	attrs := fieldAttrs(f)
	if len(attrs) == 0 {
		return fmt.Sprintf("`%s`", f.Path)
	}
	return fmt.Sprintf("`%s` %s", f.Path, strings.Join(attrs, " "))
}

// fieldSummary renders the type+format part of a FieldRef inline, used inside
// a "before → after" change line where the path is shown separately.
func fieldSummary(f handoffschema.FieldRef) string {
	attrs := fieldAttrs(f)
	if len(attrs) == 0 {
		return "(无)"
	}
	return strings.Join(attrs, " ")
}

func renderStringListLines(sb *strings.Builder, added, removed []string) {
	for _, s := range added {
		fmt.Fprintf(sb, "- + %s\n", s)
	}
	for _, s := range removed {
		fmt.Fprintf(sb, "- - %s\n", s)
	}
	sb.WriteString("\n")
}

func renderGlobalChanges(sb *strings.Builder, d *handoffschema.APIDelta) {
	if d.Servers == nil && d.Security == nil {
		return
	}
	sb.WriteString("## 全局变更\n\n")
	if d.Servers != nil {
		sb.WriteString("**Servers**\n\n")
		renderStringListLines(sb, d.Servers.Added, d.Servers.Removed)
	}
	if d.Security != nil {
		sb.WriteString("**Security**\n\n")
		renderStringListLines(sb, d.Security.Added, d.Security.Removed)
	}
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func writeFile(path string, b []byte) error {
	return os.WriteFile(path, b, 0o644)
}

// AttachmentFetcher decouples the inbox package from transport.
type AttachmentFetcher interface {
	FetchAttachment(ctx context.Context, handoffID, name string) ([]byte, error)
}

// DownloadAttachments fetches every attachment listed in the package and
// writes it under <dir>/attachments/<name>. Errors per-attachment are logged
// to stderr but don't abort the rest — partial inbox is better than none.
func DownloadAttachments(ctx context.Context, fetcher AttachmentFetcher, dir string, p *handoffschema.Package) error {
	if len(p.Attachments) == 0 {
		return nil
	}
	attachDir := AttachmentsDir(dir)
	if err := os.MkdirAll(attachDir, 0o755); err != nil {
		return err
	}
	for _, a := range p.Attachments {
		body, err := fetcher.FetchAttachment(ctx, p.ID, a.Name)
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: fetch attachment %s: %v\n", a.Name, err)
			continue
		}
		if err := writeFile(filepath.Join(attachDir, a.Name), body); err != nil {
			fmt.Fprintf(os.Stderr, "warning: write attachment %s: %v\n", a.Name, err)
		}
	}
	return nil
}

func renderSummaryMD(p *handoffschema.Package) string {
	var sb strings.Builder
	isRequest := p.EffectiveKind() == handoffschema.KindRequest
	if isRequest {
		fmt.Fprintf(&sb, "# Request %s\n\n", p.ID)
	} else {
		fmt.Fprintf(&sb, "# Handoff %s\n\n", p.ID)
	}
	fmt.Fprintf(&sb, "- From: `%s`\n- To: `%s`\n- Urgency: `%s`\n- Repo: `%s` @ `%s`\n- Created: %s\n",
		p.Sender, p.Recipient, p.Urgency, p.Repo.Name, p.Repo.Branch, p.CreatedAt.Format("2006-01-02 15:04:05 MST"))
	if p.RespondsTo != "" {
		fmt.Fprintf(&sb, "- Responds to: `%s`\n", p.RespondsTo)
	}
	sb.WriteString("\n")

	if p.SummaryMD != "" {
		if isRequest {
			sb.WriteString("## 前端的需求描述\n\n")
		} else {
			sb.WriteString("## Sender's notes\n\n")
		}
		sb.WriteString(p.SummaryMD)
		if !strings.HasSuffix(p.SummaryMD, "\n") {
			sb.WriteString("\n")
		}
		sb.WriteString("\n")
	}

	if len(p.ModulePaths) > 0 {
		sb.WriteString("## 模块范围 (module brief)\n\n")
		for _, m := range p.ModulePaths {
			fmt.Fprintf(&sb, "- `%s`\n", m)
		}
		sb.WriteString("\n")
	}

	if p.Git != nil && len(p.Git.Commits) > 0 {
		sb.WriteString("## Commits\n\n")
		for _, c := range p.Git.Commits {
			fmt.Fprintf(&sb, "- `%s` %s\n", handoff.ShortSHA(c.SHA), c.Subject)
		}
		sb.WriteString("\n")
	}

	if len(p.TargetingHints) > 0 {
		sb.WriteString("## Targeting hints\n\n")
		for _, h := range p.TargetingHints {
			fmt.Fprintf(&sb, "- %s", h.Reason)
			if h.MatchedPath != "" {
				fmt.Fprintf(&sb, " (matched `%s`)", h.MatchedPath)
			}
			sb.WriteString("\n")
			for _, e := range h.SuggestEdit {
				fmt.Fprintf(&sb, "  - edit: `%s`\n", e)
			}
			for _, c := range h.SuggestCreate {
				fmt.Fprintf(&sb, "  - create: `%s`\n", c)
			}
		}
		sb.WriteString("\n")
	}

	if p.NoteMD != "" {
		sb.WriteString("## Sender note\n\n")
		sb.WriteString(p.NoteMD)
		sb.WriteString("\n")
	}

	if prd := strings.TrimSpace(p.PrdMD); prd != "" {
		sb.WriteString("## Product brief / PRD\n\n")
		sb.WriteString(prd)
		sb.WriteString("\n")
	}
	return sb.String()
}

func renderPromptMD(p *handoffschema.Package, mode Mode) string {
	if p.EffectiveKind() == handoffschema.KindRequest {
		return renderRequestPromptMD(p, mode)
	}
	integrationPath := fmt.Sprintf("docs/integrations/%s.md", p.ID)
	// Detect module-brief mode by content shape, not just the ModulePaths
	// field: an older receiver binary may have dropped the field on JSON
	// decode. p.Git == nil is the reliable signal — non-module Build always
	// returns a non-nil Git block, even if it is empty.
	// Request packages also have Git == nil but they take the early-return
	// above, so this only fires for legitimate module-brief / legacy cases.
	moduleMode := len(p.ModulePaths) > 0 || p.Git == nil

	var sb strings.Builder
	switch {
	case moduleMode && mode == ModeDirect:
		sb.WriteString("# Handoff: 模块对接 — 直接修改前端代码\n\n")
		fmt.Fprintf(&sb, "收到模块 brief handoff `%s` (from `%s`).\n\n", p.ID, p.Sender)
		sb.WriteString("**这是一份后端整理好的、对一个或多个已有模块的完整 API 契约文档**，不是 diff。后端的「意图」就是文档本身。\n\n")
		sb.WriteString("**你的任务是直接修改本仓库前端代码完成对接**，不需要先产出 INTEGRATION.md。改完后停下等人工 review 你的 diff。\n\n")
		sb.WriteString("## 模块范围\n\n")
		for _, m := range p.ModulePaths {
			fmt.Fprintf(&sb, "- `%s`\n", m)
		}
		sb.WriteString("\n")
	case moduleMode:
		sb.WriteString("# Handoff: 模块对接 — 产出前端集成方案\n\n")
		fmt.Fprintf(&sb, "收到模块 brief handoff `%s` (from `%s`).\n\n", p.ID, p.Sender)
		sb.WriteString("**这是一份后端整理好的、对一个或多个已有模块的完整 API 契约文档**，不是 diff。后端的「意图」就是文档本身。\n\n")
		fmt.Fprintf(&sb, "**你的任务不是直接改代码**，而是产出 `%s`，写完后停下等人工 review。\n\n", integrationPath)
		sb.WriteString("## 模块范围\n\n")
		for _, m := range p.ModulePaths {
			fmt.Fprintf(&sb, "- `%s`\n", m)
		}
		sb.WriteString("\n")
	case mode == ModeDirect:
		sb.WriteString("# Handoff: 直接修改前端代码完成对接\n\n")
		fmt.Fprintf(&sb, "收到 handoff `%s` (from `%s`).\n\n", p.ID, p.Sender)
		sb.WriteString("**你的任务是直接修改本仓库前端代码完成对接**，不需要先产出 INTEGRATION.md。改完后停下等人工 review 你的 diff。\n\n")
	default:
		sb.WriteString("# Handoff: 产出前端对接方案\n\n")
		fmt.Fprintf(&sb, "收到 handoff `%s` (from `%s`).\n\n", p.ID, p.Sender)
		fmt.Fprintf(&sb, "**你的任务不是直接改代码**，而是产出 `%s`，写完后停下等人工 review。\n\n", integrationPath)
	}

	if p.RespondsTo != "" {
		fmt.Fprintf(&sb, "> ↩️ 这次 handoff 是在回应你之前发起的需求 `%s`。先去 `.cc-handoff/inbox/%s/`（如果当时领过）或 `comment_handoff` 拉一下原需求内容对照，再开始整合。\n\n", p.RespondsTo, p.RespondsTo)
	}

	if prd := strings.TrimSpace(p.PrdMD); prd != "" {
		sb.WriteString("## 📋 产品需求 / 设计意图 (背景参考)\n\n")
		sb.WriteString("> 🟢 **这一段是「为什么」的背景参考，不是逐条硬约束**。读懂它能让你的方案契合产品意图，但**不要求你在 INTEGRATION.md / 代码改动里逐条回应**。它和下面的「后端备注」是两个用途：备注是必须逐条兑现，PRD 是用来理解意图。\n\n")
		sb.WriteString("以下是后端从产品侧拿到的需求描述，用来帮你理解这次 API 变更的业务目的。遇到契约描述与产品意图明显冲突时，优先用 `comment_handoff` 问发送端。\n\n")
		sb.WriteString(prd)
		if !strings.HasSuffix(prd, "\n") {
			sb.WriteString("\n")
		}
		sb.WriteString("\n")
	}

	if p.SummaryMD != "" {
		if moduleMode {
			sb.WriteString("## 后端整理的 API 契约 (模块 brief)\n\n")
		} else {
			sb.WriteString("## 后端的意图 (sender's notes)\n\n")
		}
		sb.WriteString(p.SummaryMD)
		if !strings.HasSuffix(p.SummaryMD, "\n") {
			sb.WriteString("\n")
		}
		sb.WriteString("\n")
	}

	if note := strings.TrimSpace(p.NoteMD); note != "" {
		bindLoc, requireVerb := "INTEGRATION.md 里逐条响应", "INTEGRATION.md 必须逐条响应"
		if mode == ModeDirect {
			bindLoc, requireVerb = "代码改动里兑现", "代码改动必须逐条满足"
		}
		sb.WriteString("## ⚠️ 后端备注 / 需求 (必读)\n\n")
		fmt.Fprintf(&sb, "> 🔴 **这一段每一条都是硬约束**。和上面的 PRD 不同：PRD 是背景参考，这里每条都必须在 %s，漏掉就是 bug。\n\n", bindLoc)
		fmt.Fprintf(&sb, "发送端额外提出的跨端约束或注意事项。%s：\n\n", requireVerb)
		sb.WriteString(note)
		sb.WriteString("\n\n")
	}

	if p.APIDelta != nil && (len(p.APIDelta.Added)+len(p.APIDelta.Changed)+len(p.APIDelta.Removed)) > 0 {
		sb.WriteString("## API 契约变更\n\n")
		sb.WriteString("详见同目录 `api-delta.md`。摘要：\n")
		fmt.Fprintf(&sb, "- 新增 %d / 变更 %d / 删除 %d\n\n",
			len(p.APIDelta.Added), len(p.APIDelta.Changed), len(p.APIDelta.Removed))
	}

	if p.Git != nil && len(p.Git.Commits) > 0 {
		sb.WriteString("## 后端提交 (上下文参考)\n\n")
		for _, c := range p.Git.Commits {
			fmt.Fprintf(&sb, "- %s\n", c.Subject)
			if body := strings.TrimSpace(c.Body); body != "" {
				for line := range strings.SplitSeq(body, "\n") {
					fmt.Fprintf(&sb, "  %s\n", line)
				}
			}
		}
		sb.WriteString("\n")
	}

	if p.Git != nil && len(p.Git.ChangedPaths) > 0 {
		sb.WriteString("## 后端改动的目录 (定位参考)\n\n")
		for _, cp := range p.Git.ChangedPaths {
			fmt.Fprintf(&sb, "- `%s`\n", cp)
		}
		sb.WriteString("\n")
	}

	if len(p.TargetingHints) > 0 {
		sb.WriteString("## 发送端给的候选路径 (启发式，必须用真实代码核对)\n\n")
		for _, h := range p.TargetingHints {
			for _, e := range h.SuggestEdit {
				fmt.Fprintf(&sb, "- edit `%s` (%s)\n", e, h.Reason)
			}
			for _, c := range h.SuggestCreate {
				fmt.Fprintf(&sb, "- create `%s` (%s)\n", c, h.Reason)
			}
		}
		sb.WriteString("\n")
	}

	sb.WriteString("## 自检 — 动手前先答 4 个问题\n\n")
	if mode == ModeDirect {
		sb.WriteString("在改代码前，把下面四个问题在脑里 / 笔记里答完。**任何一个答不上来，先用 `comment_handoff` MCP 工具或 `cc-handoff comment <id>` CLI 问发送端，等回复了再继续**。这是为了避免你写完后回头返工：\n\n")
	} else {
		sb.WriteString("在动手写 INTEGRATION.md 前，把下面四个问题在脑里 / 笔记里答完。**任何一个答不上来，先用 `comment_handoff` MCP 工具或 `cc-handoff comment <id>` CLI 问发送端，等回复了再继续**。这是为了避免你写完方案后再回头返工：\n\n")
	}
	sb.WriteString("1. **字段级**：每个新增 / 改动字段，我都能说出它的**类型 + 是否必填 + 旧客户端兜底**吗？（类型从 swagger / DTO / summary 来，不要靠猜）\n")
	sb.WriteString("2. **错误码**：每个错误码（HTTP + 业务码）我都知道 UI 该怎么显示（toast / 表单内联 / 跳登录 / 全局 banner / 静默重试）吗？\n")
	sb.WriteString("3. **替代关系**：这次新增 / 改动的 endpoint 是不是替代了某个旧 endpoint？如果是，**旧 endpoint 在本仓库哪些地方被调用**，怎么过渡？\n")
	sb.WriteString("4. **命名 / 类型冲突**：新增字段名 / 类型名跟本仓库已有 TS 类型、interface、常量有没有同名但语义不同的？（金额单位、时间格式、ID 形态都要核对）\n\n")
	sb.WriteString("## 你必须按顺序做的事\n\n")
	if moduleMode {
		sb.WriteString("0. 如果 brief 中字段语义、请求体形态、错误码不明等有歧义，")
	} else {
		sb.WriteString("0. 如果 API delta / summary 有关键歧义（字段语义、请求体形态、错误码不明等），")
	}
	sb.WriteString("**先用 `comment_handoff` MCP 工具或 `cc-handoff comment <id>` CLI 问发送端，等回复后再继续**。不要脑补。\n")
	sb.WriteString("1. 完整读完上面所有信息。\n")
	sb.WriteString("2. 扫本仓库前端代码，定位以下层：API client / 类型定义 / DTO / hooks / 调用方组件。\n")
	if moduleMode {
		sb.WriteString("3. 把 brief 中**每个 endpoint** 落到本仓库 API client 真实文件路径 —— 不要照抄 hints。对每个 endpoint，明确：本仓库是否已经有 client / 类型 / 调用点；缺什么、要新增什么、要改什么。\n")
	} else {
		sb.WriteString("3. 把 API delta 每一条**对应到本仓库的真实文件路径** —— 不要照抄发送端 hints，hints 可能过期。\n")
	}
	if mode == ModeDirect {
		sb.WriteString("4. 直接修改代码完成对接：\n")
		sb.WriteString("   - **API client / 类型 / DTO**：新增或变更每个 endpoint 对应的 TS 函数、类型、DTO。\n")
		sb.WriteString("   - **Call-site updates**：消费这些 API 的组件 / hooks / services 一并更新。\n")
		sb.WriteString("   - **风格锚点**：引用本仓库已存在的同类文件（如 `lib/api/users.ts` 的 fetcher 写法、`hooks/useCustomers.ts` 的 SWR key 约定），避免风格漂移。\n")
		sb.WriteString("5. **停下**。不要继续跑 lint / format / build / test，除非用户明确要求。告诉我「改完了，这些是改动的文件」，等我 review 你的 diff。中途有疑问继续走 comment 通道。\n")
	} else {
		fmt.Fprintf(&sb, "4. 在仓库根写 `%s`（必要时 `mkdir -p docs/integrations/`），结构必须包含：\n", integrationPath)
		sb.WriteString("   - **Overview**：1-2 段说清这次对接要达成什么。\n")
		sb.WriteString("   - **File changes**：按 `Modify` / `Create` / `Remove` 分组；每条带 Path（已用真实代码核对）+ Why + 具体代码片段或伪代码 + ")
		sb.WriteString("**风格锚点**（引用本仓库已存在的同类文件路径，如「参考 `lib/api/users.ts` 的 fetcher 写法」「按 `hooks/useCustomers.ts` 的 SWR key 约定」），避免风格漂移。\n")
		sb.WriteString("   - **API client 变更**：每个新增/变更 endpoint 对应的 TS 函数 / 类型 / DTO 改动。\n")
		sb.WriteString("   - **Call-site updates**：消费这些 API 的组件 / hooks / services 列表。\n")
		sb.WriteString("   - **Verification**：如何验证（命令、页面、预期行为）。\n")
		sb.WriteString("5. **停下**。不要直接改代码。等人工 review，确认后告诉我「按 INTEGRATION.md 执行」我才开始改代码。中途有疑问继续走 comment 通道。\n")
	}
	return sb.String()
}

// renderRequestPromptMD generates the receiver-side prompt for a KindRequest
// package. The receiver here is whichever side is being asked to add/change
// something (typically the backend, but the mechanism is symmetric). Unlike
// a delivery, there's no diff or API delta to read — the summary IS the body.
func renderRequestPromptMD(p *handoffschema.Package, mode Mode) string {
	responsePath := fmt.Sprintf("docs/requests/%s.md", p.ID)

	var sb strings.Builder
	if mode == ModeDirect {
		sb.WriteString("# Request: 直接实现对端发起的需求\n\n")
		fmt.Fprintf(&sb, "收到 request `%s` (from `%s`).\n\n", p.ID, p.Sender)
		sb.WriteString("**这不是在让你对接已存在的 API**，而是发起方（通常是前端）发现你这边设计不全 / 缺字段 / 缺能力，让你补齐。\n\n")
		sb.WriteString("**你的任务是直接修改本仓库代码实现这个需求**，不需要先产出方案文档。改完后停下等人工 review 你的 diff。\n\n")
	} else {
		sb.WriteString("# Request: 设计对端发起的需求的响应方案\n\n")
		fmt.Fprintf(&sb, "收到 request `%s` (from `%s`).\n\n", p.ID, p.Sender)
		sb.WriteString("**这不是在让你对接已存在的 API**，而是发起方（通常是前端）发现你这边设计不全 / 缺字段 / 缺能力，让你补齐。\n\n")
		fmt.Fprintf(&sb, "**你的任务不是直接改代码**，而是产出 `%s` 的响应方案，写完后停下等人工 review。\n\n", responsePath)
	}

	if prd := strings.TrimSpace(p.PrdMD); prd != "" {
		sb.WriteString("## 📋 产品需求 / 设计意图 (背景参考)\n\n")
		sb.WriteString("> 🟢 **这一段是「为什么」的背景参考，不是逐条硬约束**。读懂它能让你的响应方案契合产品意图，但**不要求你在响应方案 / 代码里逐条回应**。它和下面的「发起方备注」是两个用途：备注必须逐条兑现，PRD 用来理解意图。\n\n")
		sb.WriteString("以下是发起方（前端）从产品侧拿到的需求描述，用来帮你理解这个 request 背后的业务目的。\n\n")
		sb.WriteString(prd)
		if !strings.HasSuffix(prd, "\n") {
			sb.WriteString("\n")
		}
		sb.WriteString("\n")
	}

	if p.SummaryMD != "" {
		sb.WriteString("## 发起方的需求描述 (request body)\n\n")
		sb.WriteString(p.SummaryMD)
		if !strings.HasSuffix(p.SummaryMD, "\n") {
			sb.WriteString("\n")
		}
		sb.WriteString("\n")
	}

	if note := strings.TrimSpace(p.NoteMD); note != "" {
		bindLoc, requireVerb := "响应方案里逐条响应", "响应方案必须逐条响应"
		if mode == ModeDirect {
			bindLoc, requireVerb = "代码改动里兑现", "代码改动必须逐条满足"
		}
		sb.WriteString("## ⚠️ 发起方备注 / 跨端约束 (必读)\n\n")
		fmt.Fprintf(&sb, "> 🔴 **这一段每一条都是硬约束**。和上面的 PRD 不同：PRD 是背景参考，这里每条都必须在 %s，漏掉就是 bug。\n\n", bindLoc)
		fmt.Fprintf(&sb, "发起方提出的额外约束。%s：\n\n", requireVerb)
		sb.WriteString(note)
		sb.WriteString("\n\n")
	}

	sb.WriteString("## 你必须按顺序做的事\n\n")
	sb.WriteString("0. 如果需求描述里**关键信息有歧义**（具体要哪些字段、字段类型、错误处理预期、是否破坏现有调用方等），**先用 `comment_handoff` MCP 工具或 `cc-handoff comment <id>` CLI 问发起方，等回复后再继续**。不要脑补需求。\n")
	sb.WriteString("1. 完整读完上面的需求描述与备注。\n")
	sb.WriteString("2. 扫本仓库代码，定位与需求相关的层：router / handler / service / dto / 数据模型 / swagger。明确改动落在哪些真实文件。\n")
	if mode == ModeDirect {
		sb.WriteString("3. 直接修改代码实现需求：\n")
		sb.WriteString("   - **Handler / DTO / Service / 数据层**：按需新增或修改。\n")
		sb.WriteString("   - **Swagger / OpenAPI 注释**：如果仓库用 swagger 注解生成 API 文档，同步更新。\n")
		sb.WriteString("   - **风格锚点**：引用本仓库已存在的同类 handler / DTO 的写法，避免风格漂移。\n")
		sb.WriteString("   - **不破坏现有调用方**：除非发起方明确允许破坏，新增字段优先 optional / nullable。\n")
		sb.WriteString("4. **停下**。不要继续跑 lint / format / build / test，除非用户明确要求。告诉用户「改完了，这些是改动的文件」，等 review。中途有疑问继续走 comment 通道。\n")
		fmt.Fprintf(&sb, "5. review 通过、改动合并后，跑 `/handoff` 把交付送回给 `%s`，并在调用 `submit_handoff` 时**带上 `responds_to=%s`** —— 这样发起方那边能看到「这次交付是回应你之前的 %s 需求」。\n", p.Sender, p.ID, p.ID)
	} else {
		fmt.Fprintf(&sb, "3. 在仓库根写 `%s`（必要时 `mkdir -p docs/requests/`），结构必须包含：\n", responsePath)
		sb.WriteString("   - **需求理解**：用你自己的话复述发起方要的是什么；列出你认定的关键约束。\n")
		sb.WriteString("   - **影响范围**：受影响的真实文件 —— router / handler / service / dto / 数据模型 / swagger。每条带 Path + Why。\n")
		sb.WriteString("   - **实现方案**：分 `Modify` / `Create` / `Remove` 分组；每条带具体代码片段或伪代码 + **风格锚点**（引用本仓库已存在的同类文件路径，如「参考 `internal/handler/order.go` 的错误返回写法」），避免风格漂移。\n")
		sb.WriteString("   - **不在范围**：发起方没要、但你看到顺手能做的，写在这里**不做**，避免 scope creep。\n")
		sb.WriteString("   - **兼容性**：是否破坏现有调用方？字段是否 optional / nullable？\n")
		sb.WriteString("   - **Verification**：怎么验证（curl / 测试 / swagger UI / 预期响应）。\n")
		sb.WriteString("4. **停下**。不要直接改代码。等人工 review，确认后告诉用户「按响应方案执行」才开始改。中途有疑问继续走 comment 通道。\n")
		fmt.Fprintf(&sb, "5. 改动完成、合并后，跑 `/handoff` 把交付送回给 `%s`，并在调用 `submit_handoff` 时**带上 `responds_to=%s`** —— 这样发起方那边能看到「这次交付是回应你之前的 %s 需求」。\n", p.Sender, p.ID, p.ID)
	}
	return sb.String()
}
