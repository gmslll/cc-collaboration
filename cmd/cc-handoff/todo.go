package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/linear"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/todoschema"
)

// The `todo` subcommands are the scripted/no-AI-session fallback for the Todo
// feature (see the feature plan's Track E). AI sessions normally manage todos
// through the MCP tools (internal/mcp/todo_tools.go); this is for humans and
// shell scripts. Every subcommand goes through transport.Client, same as the
// handoff commands (submit.go, list.go, ...) — no local state, no bus.

const todoUsage = `cc-handoff todo — 待办事项(个人 / 团队),经 relay 云同步

用法:
  cc-handoff todo create <title> [选项]
  cc-handoff todo list   [选项]
  cc-handoff todo get    <id> [--json]
  cc-handoff todo status <id> <new-status>
  cc-handoff todo assign <id> <identity> [--session ID] [--label TEXT]
  cc-handoff todo assign <id> --unassign
  cc-handoff todo comment <id> <body...> | --list <id>
  cc-handoff todo import-linear --team KEY [--project ID]

create 选项:
  --body TEXT                  正文(Markdown)
  --project ID                 团队待办所属 Project(不传 = 个人待办)
  --priority low|normal|high   默认 normal
  --due RFC3339                截止时间,如 2026-07-10T18:00:00Z
  --recurrence daily|weekly|monthly   周期重复(不传 = 一次性)
  --assignee IDENTITY          指派对象身份
  --attach PATH                附件文件路径(可重复传多次)

list 选项:
  --scope personal|project|assigned|all   默认 personal
  --project ID   scope=project 时限定单个 Project(不传 = 所在全部 Project 的并集)
  --status S     按状态过滤(pending/assigned/in_progress/blocked/done/cancelled)
  --limit N
  --json

status 取值: pending | assigned | in_progress | blocked | done | cancelled

import-linear 选项:
  --team KEY     Linear team key(如 ENG)。省略则用 .cc-handoff.toml [integrations.linear] team_key
  --project ID   导入到的 cc-handoff Project ID(团队待办)。不传 = 个人待办

  按 source_ref(linear:<identifier>) 幂等:已导入过的 issue 会更新标题/正文/优先级/
  截止时间/状态,而不是建重复待办。需要先在用户配置里设置 linear_personal_token。
`

func runTodo(ctx context.Context, args []string) error {
	sub, rest := "", args
	if len(args) > 0 {
		sub, rest = args[0], args[1:]
	}
	switch sub {
	case "", "-h", "--help", "help":
		fmt.Print(todoUsage)
		return nil
	case "create":
		return runTodoCreate(ctx, rest)
	case "list":
		return runTodoList(ctx, rest)
	case "get":
		return runTodoGet(ctx, rest)
	case "status":
		return runTodoStatus(ctx, rest)
	case "assign":
		return runTodoAssign(ctx, rest)
	case "comment":
		return runTodoComment(ctx, rest)
	case "import-linear":
		return runTodoImportLinear(ctx, rest)
	default:
		return fmt.Errorf("unknown todo subcommand %q (want create|list|get|status|assign|comment|import-linear)", sub)
	}
}

// todoClient resolves .cc-handoff.toml from the current directory and builds
// a relay client from it — the same res.RelayURL/res.Token pair every other
// handoff command (submit.go, list.go, status.go, ...) uses.
func todoClient() (*transport.Client, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	res, err := config.Resolve(cwd)
	if err != nil {
		return nil, err
	}
	return transport.New(res.RelayURL, res.Token), nil
}

// attachFlag collects repeated `--attach PATH` occurrences into a slice.
type attachFlag []string

func (a *attachFlag) String() string { return strings.Join(*a, ",") }
func (a *attachFlag) Set(v string) error {
	*a = append(*a, v)
	return nil
}

func runTodoCreate(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("todo create", flag.ContinueOnError)
	body := fs.String("body", "", "正文(Markdown)")
	project := fs.String("project", "", "团队待办所属 Project ID(不传 = 个人待办)")
	priority := fs.String("priority", string(todoschema.PriorityNormal), "low|normal|high")
	due := fs.String("due", "", "截止时间,RFC3339,如 2026-07-10T18:00:00Z")
	recurrence := fs.String("recurrence", "", "daily|weekly|monthly(不传 = 一次性)")
	assignee := fs.String("assignee", "", "指派对象身份")
	var attach attachFlag
	fs.Var(&attach, "attach", "附件文件路径(可重复传多次)")
	pos, err := parseFlexible(fs, args)
	if err != nil {
		return err
	}
	if len(pos) < 1 {
		return fmt.Errorf("usage: cc-handoff todo create <title> [--body TEXT] [--project ID] [--priority low|normal|high] [--due RFC3339] [--recurrence daily|weekly|monthly] [--assignee IDENTITY] [--attach PATH ...]")
	}
	title := strings.Join(pos, " ")

	p := todoschema.Priority(*priority)
	if !todoschema.ValidPriority(p) {
		return fmt.Errorf("invalid --priority %q (want low|normal|high)", *priority)
	}
	r := todoschema.Recurrence(*recurrence)
	if !todoschema.ValidRecurrence(r) {
		return fmt.Errorf("invalid --recurrence %q (want daily|weekly|monthly, or omit)", *recurrence)
	}
	var dueAt *time.Time
	if *due != "" {
		t, err := time.Parse(time.RFC3339, *due)
		if err != nil {
			return fmt.Errorf("invalid --due %q (want RFC3339, e.g. 2026-07-10T18:00:00Z): %w", *due, err)
		}
		dueAt = &t
	}

	// Read attachment files up front so a bad path fails before we've created
	// anything on the relay.
	type pendingAttachment struct {
		name    string
		content []byte
	}
	pending := make([]pendingAttachment, 0, len(attach))
	for _, path := range attach {
		content, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("read attachment %s: %w", path, err)
		}
		pending = append(pending, pendingAttachment{name: filepath.Base(path), content: content})
	}

	client, err := todoClient()
	if err != nil {
		return err
	}
	out, err := client.CreateTodo(ctx, &todoschema.Todo{
		ProjectID:        *project,
		Title:            title,
		BodyMD:           *body,
		Priority:         p,
		Recurrence:       r,
		DueAt:            dueAt,
		AssigneeIdentity: *assignee,
	})
	if err != nil {
		return relayCompatError(err, "todo create")
	}

	for _, a := range pending {
		if err := client.UploadTodoAttachment(ctx, out.ID, a.name, a.content); err != nil {
			return fmt.Errorf("todo %s created but upload attachment %s failed: %w", out.ID, a.name, err)
		}
	}

	fmt.Printf("✓ created todo %s: %s\n", out.ID, out.Title)
	if out.ProjectID != "" {
		fmt.Printf("  project=%s\n", out.ProjectID)
	}
	if len(pending) > 0 {
		fmt.Printf("  attachments=%d\n", len(pending))
	}
	return nil
}

func runTodoList(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("todo list", flag.ContinueOnError)
	scope := fs.String("scope", "personal", "personal|project|assigned|all")
	project := fs.String("project", "", "scope=project 时限定单个 Project(不传 = 并集)")
	status := fs.String("status", "", "按状态过滤")
	limit := fs.Int("limit", 0, "最多返回条数")
	asJSON := fs.Bool("json", false, "输出 JSON 而非表格")
	if err := fs.Parse(args); err != nil {
		return err
	}

	client, err := todoClient()
	if err != nil {
		return err
	}
	items, err := client.ListTodos(ctx, transport.TodoListFilter{
		Scope:     *scope,
		ProjectID: *project,
		Status:    *status,
		Limit:     *limit,
	})
	if err != nil {
		return relayCompatError(err, "todo list")
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(items)
	}
	if len(items) == 0 {
		fmt.Println("no todos.")
		return nil
	}
	fmt.Printf("%-22s  %-11s  %-7s  %-19s  %s\n", "ID", "STATUS", "PRI", "DUE", "TITLE")
	for _, it := range items {
		due := "-"
		if it.DueAt != nil {
			due = it.DueAt.Local().Format(time.RFC3339[:19])
		}
		fmt.Printf("%-22s  %-11s  %-7s  %-19s  %s\n",
			it.ID, it.Status, it.Priority, due, truncRight(it.Title, 60))
	}
	return nil
}

func runTodoGet(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("todo get", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "输出 JSON 而非人类可读格式")
	pos, err := parseFlexible(fs, args)
	if err != nil {
		return err
	}
	if len(pos) < 1 {
		return fmt.Errorf("usage: cc-handoff todo get <id> [--json]")
	}

	client, err := todoClient()
	if err != nil {
		return err
	}
	t, err := client.GetTodo(ctx, pos[0])
	if err != nil {
		return relayCompatError(err, "todo get")
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(t)
	}
	printTodoDetail(t)
	return nil
}

func printTodoDetail(t *todoschema.Todo) {
	fmt.Printf("todo %s\n", t.ID)
	fmt.Printf("  title     : %s\n", t.Title)
	scope := "personal"
	if t.ProjectID != "" {
		scope = "project=" + t.ProjectID
	}
	fmt.Printf("  scope     : %s\n", scope)
	fmt.Printf("  owner     : %s\n", t.OwnerIdentity)
	fmt.Printf("  status    : %s\n", t.Status)
	fmt.Printf("  priority  : %s\n", t.Priority)
	if t.Recurrence != "" {
		fmt.Printf("  recurrence: %s\n", t.Recurrence)
	}
	if t.AssigneeIdentity != "" {
		if t.AssigneeSessionID != "" {
			fmt.Printf("  assignee  : %s (session=%s label=%q)\n", t.AssigneeIdentity, t.AssigneeSessionID, t.AssigneeSessionLabel)
		} else {
			fmt.Printf("  assignee  : %s\n", t.AssigneeIdentity)
		}
	}
	if t.DueAt != nil {
		fmt.Printf("  due       : %s\n", t.DueAt.Local().Format(time.RFC3339))
	}
	if t.NextOccurrenceAt != nil {
		fmt.Printf("  next      : %s\n", t.NextOccurrenceAt.Local().Format(time.RFC3339))
	}
	fmt.Printf("  created   : %s\n", t.CreatedAt.Local().Format(time.RFC3339))
	fmt.Printf("  updated   : %s\n", t.UpdatedAt.Local().Format(time.RFC3339))
	if t.CompletedAt != nil {
		fmt.Printf("  completed : %s\n", t.CompletedAt.Local().Format(time.RFC3339))
	}
	fmt.Printf("  comments  : %d\n", t.CommentCount)
	if len(t.Attachments) > 0 {
		fmt.Println("  attachments:")
		for _, a := range t.Attachments {
			fmt.Printf("    - %s (%d bytes)\n", a.Name, a.Size)
		}
	} else if t.AttachmentCount > 0 {
		fmt.Printf("  attachments: %d\n", t.AttachmentCount)
	}
	if t.BodyMD != "" {
		fmt.Printf("\n%s\n", t.BodyMD)
	}
}

func runTodoStatus(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("todo status", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "输出 JSON 而非人类可读格式")
	pos, err := parseFlexible(fs, args)
	if err != nil {
		return err
	}
	if len(pos) < 2 {
		return fmt.Errorf("usage: cc-handoff todo status <id> <pending|assigned|in_progress|blocked|done|cancelled>")
	}
	s := todoschema.Status(pos[1])
	if !todoschema.ValidStatus(s) {
		return fmt.Errorf("invalid status %q (want pending|assigned|in_progress|blocked|done|cancelled)", pos[1])
	}

	client, err := todoClient()
	if err != nil {
		return err
	}
	out, err := client.SetTodoStatus(ctx, pos[0], s)
	if err != nil {
		return relayCompatError(err, "todo status")
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(out)
	}
	fmt.Printf("✓ todo %s status -> %s\n", out.ID, out.Status)
	if out.NextOccurrenceAt != nil {
		fmt.Printf("  next_occurrence=%s\n", out.NextOccurrenceAt.Local().Format(time.RFC3339))
	}
	return nil
}

func runTodoAssign(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("todo assign", flag.ContinueOnError)
	session := fs.String("session", "", "指派到的本机会话 ID(配合桌面 App 的会话总线,可选)")
	label := fs.String("label", "", "会话展示名(配合 --session)")
	unassign := fs.Bool("unassign", false, "取消指派(等价于把 identity/session/label 都清空)")
	pos, err := parseFlexible(fs, args)
	if err != nil {
		return err
	}
	if len(pos) < 1 {
		return fmt.Errorf("usage: cc-handoff todo assign <id> <identity> [--session ID] [--label TEXT] | cc-handoff todo assign <id> --unassign")
	}
	id := pos[0]
	identity, sessionID, sessionLabel := "", *session, *label
	switch {
	case *unassign:
		identity, sessionID, sessionLabel = "", "", ""
	case len(pos) >= 2:
		identity = pos[1]
	default:
		return fmt.Errorf(`identity required (pass an identity, an explicit "", or --unassign to clear)`)
	}

	client, err := todoClient()
	if err != nil {
		return err
	}
	out, err := client.AssignTodo(ctx, id, identity, sessionID, sessionLabel)
	if err != nil {
		return relayCompatError(err, "todo assign")
	}
	if out.AssigneeIdentity == "" {
		fmt.Printf("✓ cleared assignment on todo %s\n", out.ID)
		return nil
	}
	fmt.Printf("✓ assigned todo %s to %s\n", out.ID, out.AssigneeIdentity)
	if out.AssigneeSessionID != "" {
		fmt.Printf("  session=%s label=%q\n", out.AssigneeSessionID, out.AssigneeSessionLabel)
	}
	return nil
}

func runTodoComment(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("todo comment", flag.ContinueOnError)
	listMode := fs.Bool("list", false, "列出该待办的评论,而不是发一条新的")
	pos, err := parseFlexible(fs, args)
	if err != nil {
		return err
	}
	if len(pos) < 1 {
		return fmt.Errorf("usage: cc-handoff todo comment <id> <body...> | --list <id>")
	}
	id := pos[0]
	if !*listMode && len(pos) < 2 {
		return fmt.Errorf("comment body required (or pass --list)")
	}

	client, err := todoClient()
	if err != nil {
		return err
	}

	if *listMode {
		comments, err := client.ListTodoComments(ctx, id)
		if err != nil {
			return relayCompatError(err, "todo comment --list")
		}
		if len(comments) == 0 {
			fmt.Println("no comments yet.")
			return nil
		}
		for _, c := range comments {
			fmt.Printf("[%s] %s: %s\n",
				c.CreatedAt.Local().Format("2006-01-02 15:04:05"), c.AuthorIdentity, c.Body)
		}
		return nil
	}

	body := strings.Join(pos[1:], " ")
	c, err := client.CommentTodo(ctx, id, body)
	if err != nil {
		return relayCompatError(err, "todo comment")
	}
	fmt.Printf("✓ posted comment #%d on todo %s\n", c.ID, c.TodoID)
	return nil
}

// runTodoImportLinear is the CLI entry point for the shared import flow in
// internal/linear/import.go (also used by the import_linear_issues MCP
// tool) — see cmd/cc-handoff/todo.go's package doc and the feature plan's
// Track A.
func runTodoImportLinear(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("todo import-linear", flag.ContinueOnError)
	team := fs.String("team", "", "Linear team key(如 ENG),省略则用 .cc-handoff.toml [integrations.linear] team_key")
	project := fs.String("project", "", "导入到的 cc-handoff Project ID(团队待办);不传 = 个人待办")
	if err := fs.Parse(args); err != nil {
		return err
	}

	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	result, err := linear.ImportTeamIssuesForRepo(ctx, cwd, *team, *project)
	if err != nil {
		return relayCompatError(err, "todo import-linear")
	}
	fmt.Printf("✓ imported from Linear team %s: %d issue(s) — %d created, %d updated\n",
		result.TeamKey, result.Issues, result.Created, result.Updated)
	return nil
}
