package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/todoschema"
)

// This file wires the Todo feature (see pkg/todoschema and
// internal/transport/todo_client.go) up as MCP tools, following the same
// config.Resolve(cwd) → transport.New(...) → client.<Method>(...) →
// textResult(...) shape as the handoff tools earlier in this package.

// --- create_todo -------------------------------------------------------

func createTodoTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "title":             {"type": "string", "description": "待办标题，必填。"},
    "body_md":           {"type": "string", "description": "详情正文，Markdown。可选。"},
    "project_id":        {"type": "string", "description": "团队待办所属的 Project ID。省略 = 个人待办（仅自己可见，同一身份多端同步）。"},
    "priority":          {"type": "string", "enum": ["low", "normal", "high"], "description": "优先级，默认 normal。"},
    "due_at":            {"type": "string", "description": "截止时间，RFC3339 格式（如 2026-07-10T18:00:00Z）。省略 = 无截止时间。"},
    "recurrence":        {"type": "string", "enum": ["", "daily", "weekly", "monthly"], "description": "真实时间周期重复间隔，空字符串 = 一次性待办。标记 done 后会在此间隔后自动重新变回 pending（见 update_todo_status 的说明）。"},
    "assignee_identity": {"type": "string", "description": "创建时直接指派给的身份标识。省略 = 不指派。"},
    "attachment_paths":  {"type": "array", "items": {"type": "string"}, "description": "本地文件路径数组（绝对路径或相对 cwd）。创建成功拿到 id 后依次上传为附件。"},
    "cwd":               {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  },
  "required": ["title"]
}`)
	return Tool{
		Name:        ToolCreateTodo,
		Description: "Create a new todo (personal, or team if project_id is set) on the cc-handoff relay. Optionally attaches local files by path after creation.",
		InputSchema: schema,
		Handler:     createTodoHandler,
	}
}

type createTodoArgs struct {
	Title            string   `json:"title"`
	BodyMD           string   `json:"body_md"`
	ProjectID        string   `json:"project_id"`
	Priority         string   `json:"priority"`
	DueAt            string   `json:"due_at"`
	Recurrence       string   `json:"recurrence"`
	AssigneeIdentity string   `json:"assignee_identity"`
	AttachmentPaths  []string `json:"attachment_paths"`
	CWD              string   `json:"cwd"`
}

func createTodoHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a createTodoArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	if strings.TrimSpace(a.Title) == "" {
		return ToolResult{}, fmt.Errorf("title is required")
	}
	cwd, err := resolveCWD(a.CWD)
	if err != nil {
		return ToolResult{}, err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return ToolResult{}, err
	}

	priority := todoschema.PriorityNormal
	if a.Priority != "" {
		priority = todoschema.Priority(a.Priority)
		if !todoschema.ValidPriority(priority) {
			return ToolResult{}, fmt.Errorf("invalid priority %q (want low|normal|high)", a.Priority)
		}
	}
	recurrence := todoschema.RecurrenceNone
	if a.Recurrence != "" {
		recurrence = todoschema.Recurrence(a.Recurrence)
		if !todoschema.ValidRecurrence(recurrence) {
			return ToolResult{}, fmt.Errorf("invalid recurrence %q (want \"\"|daily|weekly|monthly)", a.Recurrence)
		}
	}
	var dueAt *time.Time
	if a.DueAt != "" {
		t, err := time.Parse(time.RFC3339, a.DueAt)
		if err != nil {
			return ToolResult{}, fmt.Errorf("invalid due_at %q: %w (want RFC3339, e.g. 2026-07-10T18:00:00Z)", a.DueAt, err)
		}
		dueAt = &t
	}

	// Read attachments up-front so a bad local path fails before the todo is
	// created (mirrors readAttachments' use in commentHandoffHandler).
	extras, names, err := readAttachments(cwd, a.AttachmentPaths)
	if err != nil {
		return ToolResult{}, err
	}

	client := transport.New(res.RelayURL, res.Token)
	out, err := client.CreateTodo(ctx, &todoschema.Todo{
		ProjectID:        a.ProjectID,
		Title:            a.Title,
		BodyMD:           a.BodyMD,
		Priority:         priority,
		Recurrence:       recurrence,
		DueAt:            dueAt,
		AssigneeIdentity: a.AssigneeIdentity,
	})
	if err != nil {
		return ToolResult{}, err
	}

	var uploaded, failed []string
	for _, name := range names {
		if err := client.UploadTodoAttachment(ctx, out.ID, name, extras[name]); err != nil {
			failed = append(failed, fmt.Sprintf("%s (%v)", name, err))
			continue
		}
		uploaded = append(uploaded, name)
	}

	var sb strings.Builder
	fmt.Fprintf(&sb, "Created todo `%s`: %s\n\n", out.ID, out.Title)
	sb.WriteString(formatTodoSummary(out))
	if len(uploaded) > 0 {
		fmt.Fprintf(&sb, "- attached: %s\n", strings.Join(uploaded, ", "))
	}
	if len(failed) > 0 {
		fmt.Fprintf(&sb, "- ⚠️ failed uploads: %s — todo was created but these files didn't go up.\n", strings.Join(failed, "; "))
	}
	return textResult(sb.String()), nil
}

// formatTodoSummary renders the field block shared by create/get/status/
// assign responses.
func formatTodoSummary(t *todoschema.Todo) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "- status: %s\n", t.Status)
	fmt.Fprintf(&sb, "- priority: %s\n", t.Priority)
	if t.ProjectID != "" {
		fmt.Fprintf(&sb, "- project_id: %s\n", t.ProjectID)
	} else {
		sb.WriteString("- scope: personal\n")
	}
	if t.AssigneeIdentity != "" {
		fmt.Fprintf(&sb, "- assignee: %s", t.AssigneeIdentity)
		if t.AssigneeSessionLabel != "" {
			fmt.Fprintf(&sb, " (session %s)", t.AssigneeSessionLabel)
		}
		sb.WriteString("\n")
	}
	if t.Recurrence != "" {
		fmt.Fprintf(&sb, "- recurrence: %s\n", t.Recurrence)
	}
	if t.DueAt != nil {
		fmt.Fprintf(&sb, "- due_at: %s\n", t.DueAt.Format(time.RFC3339))
	}
	if t.NextOccurrenceAt != nil {
		fmt.Fprintf(&sb, "- next_occurrence_at: %s\n", t.NextOccurrenceAt.Format(time.RFC3339))
	}
	if t.CompletedAt != nil {
		fmt.Fprintf(&sb, "- completed_at: %s\n", t.CompletedAt.Format(time.RFC3339))
	}
	fmt.Fprintf(&sb, "- comments: %d, attachments: %d\n", t.CommentCount, t.AttachmentCount)
	return sb.String()
}

// --- list_todos ----------------------------------------------------------

func listTodosTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "scope":      {"type": "string", "enum": ["personal", "project", "assigned"], "description": "personal(默认)=我创建的个人待办；project=我所在的所有 Project 的团队待办并集（配合 project_id 可限定到单个 Project）；assigned=指派给我的待办。"},
    "project_id": {"type": "string", "description": "配合 scope=project 使用，限定到某一个 Project；省略 = 我所在所有 Project 的并集。"},
    "status":     {"type": "string", "description": "按状态精确过滤（pending/assigned/in_progress/blocked/done/cancelled）。省略 = 不过滤。"},
    "limit":      {"type": "integer", "description": "最多返回条数。"},
    "cwd":        {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  }
}`)
	return Tool{
		Name:        ToolListTodos,
		Description: "List todos visible to the caller under the given scope/status filter. Use " + ToolGetTodo + " with an id for full detail including the attachment list.",
		InputSchema: schema,
		Handler:     listTodosHandler,
	}
}

type listTodosArgs struct {
	Scope     string `json:"scope"`
	ProjectID string `json:"project_id"`
	Status    string `json:"status"`
	Limit     int    `json:"limit"`
	CWD       string `json:"cwd"`
}

func listTodosHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a listTodosArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	scope := a.Scope
	if scope == "" {
		scope = "personal"
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
	items, err := client.ListTodos(ctx, transport.TodoListFilter{
		Scope:     scope,
		ProjectID: a.ProjectID,
		Status:    a.Status,
		Limit:     a.Limit,
	})
	if err != nil {
		return ToolResult{}, err
	}
	if len(items) == 0 {
		return textResult(fmt.Sprintf("No todos (scope=%s).", scope)), nil
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "%d todo(s) (scope=%s):\n\n", len(items), scope)
	for _, t := range items {
		fmt.Fprintf(&sb, "- [%s] `%s` %s priority=%s", t.Status, t.ID, t.Title, t.Priority)
		if t.ProjectID != "" {
			fmt.Fprintf(&sb, " project=%s", t.ProjectID)
		}
		if t.AssigneeIdentity != "" {
			fmt.Fprintf(&sb, " assignee=%s", t.AssigneeIdentity)
		}
		if t.DueAt != nil {
			fmt.Fprintf(&sb, " due=%s", t.DueAt.Format("2006-01-02"))
		}
		if t.CommentCount > 0 || t.AttachmentCount > 0 {
			fmt.Fprintf(&sb, " (💬%d 📎%d)", t.CommentCount, t.AttachmentCount)
		}
		sb.WriteString("\n")
	}
	sb.WriteString("\nUse " + ToolGetTodo + " with an id for full detail.")
	return textResult(sb.String()), nil
}

// --- get_todo --------------------------------------------------------------

func getTodoTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "id":  {"type": "string", "description": "Todo id."},
    "cwd": {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  },
  "required": ["id"]
}`)
	return Tool{
		Name:        ToolGetTodo,
		Description: "Fetch full detail for a single todo by id, including its body, comment/attachment counts, and (unlike " + ToolListTodos + ") the attachment name/size list.",
		InputSchema: schema,
		Handler:     getTodoHandler,
	}
}

type getTodoArgs struct {
	ID  string `json:"id"`
	CWD string `json:"cwd"`
}

func getTodoHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a getTodoArgs
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
	t, err := client.GetTodo(ctx, a.ID)
	if err != nil {
		return ToolResult{}, err
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "todo `%s`: %s\n\n", t.ID, t.Title)
	sb.WriteString(formatTodoSummary(t))
	fmt.Fprintf(&sb, "- owner: %s\n", t.OwnerIdentity)
	fmt.Fprintf(&sb, "- created: %s\n- updated: %s\n",
		t.CreatedAt.Format("2006-01-02 15:04:05"), t.UpdatedAt.Format("2006-01-02 15:04:05"))
	if t.BodyMD != "" {
		fmt.Fprintf(&sb, "\n%s\n", t.BodyMD)
	}
	if len(t.Attachments) > 0 {
		sb.WriteString("\nattachments:\n")
		for _, at := range t.Attachments {
			fmt.Fprintf(&sb, "- %s (%d bytes)\n", at.Name, at.Size)
		}
	}
	return textResult(sb.String()), nil
}

// --- update_todo_status ------------------------------------------------

func updateTodoStatusTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "id":     {"type": "string", "description": "Todo id."},
    "status": {"type": "string", "enum": ["pending", "assigned", "in_progress", "blocked", "done", "cancelled"], "description": "新状态。done 会自动记录完成时间 completed_at；如果该待办是周期性的（recurrence != \"\"），还会自动计算 next_occurrence_at 并安排下次出现时间——relay 的周期扫描 goroutine 到点后会把它自动重置回 pending，不会打断当前状态之外的其它待办。"},
    "cwd":    {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  },
  "required": ["id", "status"]
}`)
	return Tool{
		Name:        ToolUpdateTodoStatus,
		Description: "Transition a todo to a new status. There is no separate \"complete\" tool — completing a todo is status=done.",
		InputSchema: schema,
		Handler:     updateTodoStatusHandler,
	}
}

type updateTodoStatusArgs struct {
	ID     string `json:"id"`
	Status string `json:"status"`
	CWD    string `json:"cwd"`
}

func updateTodoStatusHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a updateTodoStatusArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	if a.ID == "" {
		return ToolResult{}, fmt.Errorf("id is required")
	}
	status := todoschema.Status(a.Status)
	if !todoschema.ValidStatus(status) {
		return ToolResult{}, fmt.Errorf("invalid status %q (want pending|assigned|in_progress|blocked|done|cancelled)", a.Status)
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
	t, err := client.SetTodoStatus(ctx, a.ID, status)
	if err != nil {
		return ToolResult{}, err
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "todo `%s` status → %s\n\n", t.ID, t.Status)
	sb.WriteString(formatTodoSummary(t))
	return textResult(sb.String()), nil
}

// --- assign_todo -----------------------------------------------------------

func assignTodoTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "id":                     {"type": "string", "description": "Todo id."},
    "assignee_identity":      {"type": "string", "description": "指派给的身份标识。传空字符串 \"\" 表示取消指派（同时清空 assignee_session_id/assignee_session_label）。"},
    "assignee_session_id":    {"type": "string", "description": "可选，指派到的本机会话 ID（如 ts2）。仅在 assignee_identity 非空时有意义。"},
    "assignee_session_label": {"type": "string", "description": "可选，指派到的本机会话展示名。"},
    "cwd":                    {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  },
  "required": ["id", "assignee_identity"]
}`)
	return Tool{
		Name:        ToolAssignTodo,
		Description: "Set (or clear, with assignee_identity=\"\") the assignee on a todo. For team todos this only marks who owns the work — cross-machine assignment does not push the task into a session; that hand-off is a separate, out-of-scope mechanism.",
		InputSchema: schema,
		Handler:     assignTodoHandler,
	}
}

type assignTodoArgs struct {
	ID                   string `json:"id"`
	AssigneeIdentity     string `json:"assignee_identity"`
	AssigneeSessionID    string `json:"assignee_session_id"`
	AssigneeSessionLabel string `json:"assignee_session_label"`
	CWD                  string `json:"cwd"`
}

func assignTodoHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a assignTodoArgs
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
	t, err := client.AssignTodo(ctx, a.ID, a.AssigneeIdentity, a.AssigneeSessionID, a.AssigneeSessionLabel)
	if err != nil {
		return ToolResult{}, err
	}
	var sb strings.Builder
	if a.AssigneeIdentity == "" {
		fmt.Fprintf(&sb, "todo `%s` assignment cleared.\n\n", t.ID)
	} else {
		fmt.Fprintf(&sb, "todo `%s` assigned → `%s`.\n\n", t.ID, a.AssigneeIdentity)
	}
	sb.WriteString(formatTodoSummary(t))
	return textResult(sb.String()), nil
}

// --- comment_todo ------------------------------------------------------

func commentTodoTool() Tool {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "id":   {"type": "string", "description": "Todo id."},
    "body": {"type": "string", "description": "评论正文，Markdown。"},
    "cwd":  {"type": "string", "description": "Repo working directory. Defaults to the MCP server's cwd."}
  },
  "required": ["id", "body"]
}`)
	return Tool{
		Name:        ToolCommentTodo,
		Description: "Post a back-channel comment on a todo. Anyone with view rights on the todo gets a todo.comment_created SSE event.",
		InputSchema: schema,
		Handler:     commentTodoHandler,
	}
}

type commentTodoArgs struct {
	ID   string `json:"id"`
	Body string `json:"body"`
	CWD  string `json:"cwd"`
}

func commentTodoHandler(ctx context.Context, raw json.RawMessage) (ToolResult, error) {
	var a commentTodoArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return ToolResult{}, fmt.Errorf("decode args: %w", err)
	}
	if a.ID == "" {
		return ToolResult{}, fmt.Errorf("id is required")
	}
	if a.Body == "" {
		return ToolResult{}, fmt.Errorf("body is required")
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
	c, err := client.CommentTodo(ctx, a.ID, a.Body)
	if err != nil {
		return ToolResult{}, err
	}
	return textResult(fmt.Sprintf("Posted comment #%d on todo `%s`.", c.ID, c.TodoID)), nil
}
