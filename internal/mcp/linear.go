package mcp

import (
	"fmt"
	"strings"

	"github.com/cc-collaboration/internal/config"
)

// LinearEvent identifies which cc-handoff event the sync block is being
// rendered for. Each event maps to a different set of Linear MCP calls the
// agent should make next.
type LinearEvent string

const (
	LinearEventSubmit  LinearEvent = "submit"
	LinearEventPickup  LinearEvent = "pickup"
	LinearEventComment LinearEvent = "comment"
	LinearEventRetract LinearEvent = "retract"
)

// LinearSyncCtx carries the per-event values that get interpolated into the
// rendered prompt. Fields the current event doesn't need can be left zero.
type LinearSyncCtx struct {
	HandoffID string
	Me        string
	Reason    string
	CommentBy string
	IsRequest bool
}

const (
	defaultLinearMCPPrefix = "linear"
	exampleTeamKey         = "ENG"
)

func linearMCPName(prefix, op string) string {
	p := prefix
	if p == "" {
		p = defaultLinearMCPPrefix
	}
	return "mcp__" + p + "__" + op
}

// linearSyncBlock returns the markdown section to append at the end of an MCP
// tool result, or "" when the integration is disabled / the specific event
// is not opted in. Empty return means "don't append anything", and callers
// can blindly concatenate the result.
func linearSyncBlock(linear config.LinearIntegration, event LinearEvent, ctx LinearSyncCtx) string {
	if !linear.Enabled {
		return ""
	}
	switch event {
	case LinearEventSubmit:
		if !linear.SyncOnSubmit {
			return ""
		}
		return renderSubmitBlock(linear, ctx)
	case LinearEventPickup:
		if !linear.SyncOnPickup {
			return ""
		}
		return renderPickupBlock(linear, ctx)
	case LinearEventComment:
		if !linear.SyncOnComment {
			return ""
		}
		return renderCommentBlock(linear, ctx)
	case LinearEventRetract:
		if !linear.SyncOnRetract {
			return ""
		}
		return renderRetractBlock(linear, ctx)
	}
	return ""
}

func renderSubmitBlock(l config.LinearIntegration, ctx LinearSyncCtx) string {
	createIssue := linearMCPName(l.MCPPrefix, "create_issue")
	teamExample := l.TeamKey
	if teamExample == "" {
		teamExample = exampleTeamKey
	}
	var sb strings.Builder
	sb.WriteString("\n\n---\n\n## 同步到 Linear\n\n")
	kind := "delivery handoff"
	if ctx.IsRequest {
		kind = "request"
	}
	fmt.Fprintf(&sb, "本次 %s 已发出 (id=`%s`)。请按下面的步骤把它同步到 Linear:\n\n", kind, ctx.HandoffID)
	fmt.Fprintf(&sb, "1. 调用 `%s`,参数:\n", createIssue)
	if l.TeamKey != "" {
		fmt.Fprintf(&sb, "   - team / teamKey: `%s`\n", l.TeamKey)
	} else {
		sb.WriteString("   - team: 用默认 team(配置里没有 team_key,自己选)\n")
	}
	sb.WriteString("   - title: 取 handoff summary 的第一行(或前 80 字),作为 issue 标题\n")
	fmt.Fprintf(&sb, "   - description: 贴 handoff summary 正文,**末尾必须追加**这行 HTML 注释作为绑定锚点(不要省略,后续 pickup/comment/retract 都靠它找回 issue):\n     `<!-- cc-handoff: %s -->`\n", ctx.HandoffID)
	if len(l.DefaultLabels) > 0 {
		fmt.Fprintf(&sb, "   - labels: `%s`\n", strings.Join(l.DefaultLabels, "`, `"))
	}
	fmt.Fprintf(&sb, "2. 拿到 Linear 返回的 issue identifier(如 `%s-456`)和 URL 后,调用 MCP 工具 `%s%s` 把绑定关系写回本地(让 status_handoff / 后续 sync 能直接读):\n", teamExample, CCHandoffMCPPrefix, ToolLinkLinear)
	fmt.Fprintf(&sb, "   参数:`{handoff: \"%s\", issue: \"<IDENTIFIER>\", url: \"<URL>\"}`\n", ctx.HandoffID)
	sb.WriteString("3. 如果创建 issue 失败或 Linear MCP 不可用,继续推进 — 这是后置同步,不影响 handoff 本身已经在 relay 上的状态。\n")
	return sb.String()
}

func renderPickupBlock(l config.LinearIntegration, ctx LinearSyncCtx) string {
	updateIssue := linearMCPName(l.MCPPrefix, "update_issue")
	createComment := linearMCPName(l.MCPPrefix, "create_comment")
	getIssue := linearMCPName(l.MCPPrefix, "get_issue")
	teamExample := l.TeamKey
	if teamExample == "" {
		teamExample = exampleTeamKey
	}
	var sb strings.Builder
	sb.WriteString("\n\n---\n\n## 同步到 Linear (pickup)\n\n")
	fmt.Fprintf(&sb, "刚接走 handoff `%s`。如果这个 handoff 关联了 Linear issue,请同步状态:\n\n", ctx.HandoffID)
	fmt.Fprintf(&sb, "1. 从 handoff summary 中找绑定锚点 `<!-- cc-handoff: %s -->`,锚点上下文里应当能拿到 issue identifier(如 `%s-123`)。\n", ctx.HandoffID, teamExample)
	fmt.Fprintf(&sb, "   - 没找到锚点 → 用 `%s` 按 handoff_id 全文搜一下 issue,搜不到就跳过本节(handoff 发送方可能没启用 sync_on_submit)。\n", getIssue)
	fmt.Fprintf(&sb, "2. 用 `%s` 把 issue state 改成 'In Progress'(或最贴近的进行中状态),assignee 改成 `%s`。\n", updateIssue, ctx.Me)
	fmt.Fprintf(&sb, "3. 用 `%s` 在 issue 上发一条评论:`picked up by %s — handoff %s materialized locally`。\n", createComment, ctx.Me, ctx.HandoffID)
	sb.WriteString("4. 同步失败不要中断主流程,继续按上面的 integration prompt 干活。\n")
	return sb.String()
}

func renderCommentBlock(l config.LinearIntegration, ctx LinearSyncCtx) string {
	createComment := linearMCPName(l.MCPPrefix, "create_comment")
	getIssue := linearMCPName(l.MCPPrefix, "get_issue")
	var sb strings.Builder
	sb.WriteString("\n\n---\n\n## 同步到 Linear (comment)\n\n")
	fmt.Fprintf(&sb, "刚在 handoff `%s` 上发了评论。请把同一条评论同步到关联的 Linear issue:\n\n", ctx.HandoffID)
	fmt.Fprintf(&sb, "1. 用 `%s` 按 `cc-handoff: %s` 锚点找到 issue。找不到则跳过。\n", getIssue, ctx.HandoffID)
	fmt.Fprintf(&sb, "2. 用 `%s` 发评论,正文格式:\n", createComment)
	fmt.Fprintf(&sb, "   ```\n   [cc-handoff comment from %s]\n   <这里贴本次评论原文>\n   ```\n", ctx.CommentBy)
	return sb.String()
}

func renderRetractBlock(l config.LinearIntegration, ctx LinearSyncCtx) string {
	updateIssue := linearMCPName(l.MCPPrefix, "update_issue")
	createComment := linearMCPName(l.MCPPrefix, "create_comment")
	getIssue := linearMCPName(l.MCPPrefix, "get_issue")
	var sb strings.Builder
	sb.WriteString("\n\n---\n\n## 同步到 Linear (retract)\n\n")
	fmt.Fprintf(&sb, "刚撤回了 handoff `%s`。请同步关闭关联的 Linear issue:\n\n", ctx.HandoffID)
	fmt.Fprintf(&sb, "1. 用 `%s` 按 `cc-handoff: %s` 锚点找到 issue。找不到则跳过。\n", getIssue, ctx.HandoffID)
	fmt.Fprintf(&sb, "2. 用 `%s` 把 state 改成 'Cancelled'(没有就加 label `cc-handoff-retracted`)。\n", updateIssue)
	if ctx.Reason != "" {
		fmt.Fprintf(&sb, "3. 用 `%s` 发评论:`handoff retracted by sender: %s`。\n", createComment, ctx.Reason)
	}
	return sb.String()
}
