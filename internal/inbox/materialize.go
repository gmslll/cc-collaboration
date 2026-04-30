package inbox

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/cc-collaboration/internal/handoff"
	"github.com/cc-collaboration/pkg/handoffschema"
)

func InboxDir(repoRoot string) string {
	return filepath.Join(repoRoot, ".claude", "handoff-inbox")
}

func PackageDir(repoRoot, id string) string {
	return filepath.Join(InboxDir(repoRoot), id)
}

// Result is what Materialize produces: the directory and the rendered prompt
// (so callers can return the prompt to Claude without re-reading from disk).
type Result struct {
	Dir    string
	Prompt string
}

// AttachmentsDir returns <dir>/attachments — created on demand by DownloadAttachments.
func AttachmentsDir(dir string) string { return filepath.Join(dir, "attachments") }

// Materialize writes a Handoff Package and its derived human/Claude-friendly
// views under <repoRoot>/.claude/handoff-inbox/<id>/.
func Materialize(repoRoot string, p *handoffschema.Package) (Result, error) {
	dir := PackageDir(repoRoot, p.ID)
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
	prompt := renderPromptMD(p)
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
			line := op.Method + " " + op.Path
			if op.Summary != "" {
				line += " — " + op.Summary
			}
			fmt.Fprintf(&sb, "- %s\n", line)
		}
		sb.WriteString("\n")
	}
	section("Added", d.Added)
	section("Changed", d.Changed)
	section("Removed", d.Removed)
	return sb.String()
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
	fmt.Fprintf(&sb, "# Handoff %s\n\n", p.ID)
	fmt.Fprintf(&sb, "- From: `%s`\n- To: `%s`\n- Urgency: `%s`\n- Repo: `%s` @ `%s`\n- Created: %s\n\n",
		p.Sender, p.Recipient, p.Urgency, p.Repo.Name, p.Repo.Branch, p.CreatedAt.Format("2006-01-02 15:04:05 MST"))

	if p.SummaryMD != "" {
		sb.WriteString("## Sender's notes\n\n")
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
	return sb.String()
}

func renderPromptMD(p *handoffschema.Package) string {
	integrationPath := fmt.Sprintf("docs/integrations/%s.md", p.ID)
	// Detect module-brief mode by content shape, not just the ModulePaths
	// field: an older receiver binary may have dropped the field on JSON
	// decode. p.Git == nil is the reliable signal — non-module Build always
	// returns a non-nil Git block, even if it is empty.
	moduleMode := len(p.ModulePaths) > 0 || p.Git == nil

	var sb strings.Builder
	if moduleMode {
		sb.WriteString("# Handoff: 模块对接 — 产出前端集成方案\n\n")
		fmt.Fprintf(&sb, "收到模块 brief handoff `%s` (from `%s`).\n\n", p.ID, p.Sender)
		sb.WriteString("**这是一份后端整理好的、对一个或多个已有模块的完整 API 契约文档**，不是 diff。后端的「意图」就是文档本身。\n\n")
		fmt.Fprintf(&sb, "**你的任务不是直接改代码**，而是产出 `%s`，写完后停下等人工 review。\n\n", integrationPath)
		sb.WriteString("## 模块范围\n\n")
		for _, m := range p.ModulePaths {
			fmt.Fprintf(&sb, "- `%s`\n", m)
		}
		sb.WriteString("\n")
	} else {
		sb.WriteString("# Handoff: 产出前端对接方案\n\n")
		fmt.Fprintf(&sb, "收到 handoff `%s` (from `%s`).\n\n", p.ID, p.Sender)
		fmt.Fprintf(&sb, "**你的任务不是直接改代码**，而是产出 `%s`，写完后停下等人工 review。\n\n", integrationPath)
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
		sb.WriteString("## ⚠️ 后端备注 / 需求 (必读)\n\n")
		sb.WriteString("发送端额外提出的跨端约束或注意事项。INTEGRATION.md 必须逐条响应：\n\n")
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
	fmt.Fprintf(&sb, "4. 在仓库根写 `%s`（必要时 `mkdir -p docs/integrations/`），结构必须包含：\n", integrationPath)
	sb.WriteString("   - **Overview**：1-2 段说清这次对接要达成什么。\n")
	sb.WriteString("   - **File changes**：按 `Modify` / `Create` / `Remove` 分组；每条带 Path（已用真实代码核对）+ Why + 具体代码片段或伪代码 + ")
	sb.WriteString("**风格锚点**（引用本仓库已存在的同类文件路径，如「参考 `lib/api/users.ts` 的 fetcher 写法」「按 `hooks/useCustomers.ts` 的 SWR key 约定」），避免风格漂移。\n")
	sb.WriteString("   - **API client 变更**：每个新增/变更 endpoint 对应的 TS 函数 / 类型 / DTO 改动。\n")
	sb.WriteString("   - **Call-site updates**：消费这些 API 的组件 / hooks / services 列表。\n")
	sb.WriteString("   - **Verification**：如何验证（命令、页面、预期行为）。\n")
	sb.WriteString("5. **停下**。不要直接改代码。等人工 review，确认后告诉我「按 INTEGRATION.md 执行」我才开始改代码。中途有疑问继续走 comment 通道。\n")
	return sb.String()
}
