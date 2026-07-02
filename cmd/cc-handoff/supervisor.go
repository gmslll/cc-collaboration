package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const supervisorUsage = `cc-handoff supervisor — 总管理 AI 的本地会话管理助手

用法:
  cc-handoff supervisor init [--dir DIR]
  cc-handoff supervisor context [--dir DIR]
  cc-handoff supervisor overview [--json]
  cc-handoff supervisor queue [--json]
  cc-handoff supervisor read <目标> [--lines N] [--screen] [--json]
  cc-handoff supervisor send <目标> <内容…> [--no-submit]
  cc-handoff supervisor usage <目标> [--pretty]
  cc-handoff supervisor kill <目标>
  cc-handoff supervisor spawn <项目> [--agent claude|codex|shell] [--supervisor] [--worktree PATH] [--workspace NAME]
  cc-handoff supervisor decide [--dir DIR] <标题> <内容…>

说明:
  overview / queue / read / send / usage / kill / spawn 依赖桌面 App 注入的 CC_BUS_DIR。
  kill 关闭目标会话(杀 PTY + 从会话列表移除);不能关闭自己或总管会话。
  spawn 让 App 在指定项目下开一个托管会话(进会话树、上总线),等价于项目右键『起 claude/codex/总管』。
  init / context / decide 默认读写当前目录下 .cc-handoff/supervisor。
`

func runSupervisor(ctx context.Context, args []string) error {
	sub, rest := "", args
	if len(args) > 0 {
		sub, rest = args[0], args[1:]
	}
	switch sub {
	case "", "-h", "--help", "help":
		fmt.Print(supervisorUsage)
		return nil
	case "init":
		return runSupervisorInit(rest)
	case "context":
		return runSupervisorContext(rest)
	case "overview":
		return runSupervisorOverview(rest, false)
	case "queue":
		return runSupervisorOverview(rest, true)
	case "read":
		return runSupervisorRead(ctx, rest)
	case "send":
		return runMsgSend(ctx, rest)
	case "usage":
		return runMsgUsage(ctx, rest)
	case "kill":
		return runMsgKill(ctx, rest)
	case "whoami":
		return runMsgWhoami()
	case "spawn":
		return runSupervisorSpawn(ctx, rest)
	case "decide":
		return runSupervisorDecide(rest)
	default:
		return fmt.Errorf("unknown supervisor subcommand %q (want init|context|overview|queue|read|send|usage|kill|spawn|decide)", sub)
	}
}

func supervisorDirFromFlag(args []string, name string) (*flag.FlagSet, *string) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	dir := fs.String("dir", ".", "项目目录")
	return fs, dir
}

func supervisorRoot(dir string) string {
	return filepath.Join(dir, ".cc-handoff", "supervisor")
}

func runSupervisorInit(args []string) error {
	fs, dir := supervisorDirFromFlag(args, "supervisor init")
	if err := fs.Parse(args); err != nil {
		return err
	}
	root := supervisorRoot(*dir)
	if err := os.MkdirAll(filepath.Join(root, "knowledge"), 0o755); err != nil {
		return err
	}
	files := map[string]string{
		"profile.md": `# Supervisor Profile

你是这个工作区的总管理 AI。你的职责是观察其它 AI 会话、读取 PRD/知识库、处理待确认事项、协调分歧，并在需要时向用户请求确认。

默认原则:
- 先读取上下文，再裁决。
- 高风险操作必须让用户确认。
- 有产品/架构决策时写入 decisions.md。
- 开子会话前按分档策略判断隔离档:默认共享 Tier1;重活/并行改同模块/破坏性 git/要 build-run → spawn --worktree(Tier2);只读 → Tier0。多会话共享同一工作树/.git 时,Tier1 会话提交须走共享 .git 提交协议(提交前 git fetch && git reset --mixed origin/main 对齐 → 提交锁串行 → 只 hunk 级 add 自己文件、绝不 add -A → 原子 git commit && git push origin HEAD:main;若有 cc-handoff commit 则优先用)。详见 principles.md。
`,
		"prd.md": `# PRD

在这里放需求文档。
`,
		"principles.md": `# Principles

在这里放你的思考方式、产品原则、工程偏好和验收标准。

## 开子会话的分档策略(spawn tiers)—— 每次开子会话前先判断

若多会话【共享同一工作树 / .git / index】,并发写 git 会互相踩(共享 index 被 restore 干扰、HEAD 一度 detached、提交被并发移走)。每次 supervisor spawn 前按任务性质选隔离档:

- Tier0 · 只读/答疑:不写 git、不改文件 → 原地开,无需隔离。
- Tier1 · 默认(共享工作树):普通改代码任务 → 原地开(不加 --worktree),遵守下面的共享 .git 提交协议。
- Tier2 · 独立 worktree(spawn --worktree):命中任一即隔离 → ① 会在其中 build/run App;② 长任务/跨多文件/epic;③ 预期与别的会话并行改同一模块;④ 破坏性 git(rebase/改史/大重构);⑤ pickup 物化量大。代价:Flutter 每 worktree 重生 .dart_tool/build,故只在命中时才上。

口诀:默认 Tier1;重活/并行同模块/破坏性 git/要 build-run → Tier2;只读 → Tier0。

## 共享 .git 提交协议(所有 Tier1 会话必须遵守)

1. 提交前对齐本地:git fetch && git reset --mixed origin/main(只移分支指针+刷新 index,不动工作树、保留未提交改动),确认 HEAD == origin/main。
2. 提交锁串行:总线播「提交锁·<id>·开始」→ 他人暂停一切 git 写 → push 完播「完成」。同一时刻只一个会话动 git。
3. 只 hunk 级 add 自己的文件/行,git diff --cached --stat 自查;绝不 git add -A / commit -a。
4. 原子提交推送:git commit -m '..' && git push origin HEAD:main;non-ff 就再 fetch,绝不 force、绝不在 dirty 共享树 rebase。
5. 若有 cc-handoff commit 子命令,优先用:cc-handoff commit -m '..' -- <只你自己的路径>(独立 GIT_INDEX_FILE + flock + commit-tree 直建于 origin/main + 原子 FF 推,免 index/HEAD 竞态)。
`,
		"decisions.md": "# Decisions\n\n",
		"knowledge/README.md": `# Knowledge

把项目知识库按主题放到这个目录。
`,
	}
	for name, body := range files {
		p := filepath.Join(root, filepath.FromSlash(name))
		if _, err := os.Stat(p); err == nil {
			continue
		} else if err != nil && !os.IsNotExist(err) {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			return err
		}
	}
	fmt.Println(root)
	return nil
}

func runSupervisorContext(args []string) error {
	fs, dir := supervisorDirFromFlag(args, "supervisor context")
	if err := fs.Parse(args); err != nil {
		return err
	}
	root := supervisorRoot(*dir)
	sections := []string{
		"profile.md",
		"prd.md",
		"principles.md",
		"decisions.md",
	}
	for _, rel := range sections {
		printSupervisorFile(root, rel)
	}
	knowledgeRoot := filepath.Join(root, "knowledge")
	_ = filepath.WalkDir(knowledgeRoot, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(strings.ToLower(d.Name()), ".md") {
			return nil
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return nil
		}
		printSupervisorFile(root, rel)
		return nil
	})
	return nil
}

func printSupervisorFile(root, rel string) {
	p := filepath.Join(root, filepath.FromSlash(rel))
	b, err := os.ReadFile(p)
	if err != nil {
		return
	}
	fmt.Printf("\n--- %s ---\n%s\n", filepath.ToSlash(rel), strings.TrimRight(string(b), "\n"))
}

func runSupervisorOverview(args []string, queueOnly bool) error {
	name := "supervisor overview"
	if queueOnly {
		name = "supervisor queue"
	}
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "输出 JSON 而非表格")
	if err := fs.Parse(args); err != nil {
		return err
	}
	dir, err := busDir()
	if err != nil {
		return err
	}
	ss, err := loadSessions(dir)
	if err != nil {
		return err
	}
	self := os.Getenv("CC_SESSION_ID")
	out := make([]busSession, 0, len(ss))
	for _, s := range ss {
		if s.ID == self {
			continue
		}
		if queueOnly && !supervisorQueueCandidate(s) {
			continue
		}
		out = append(out, s)
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(out)
	}
	if len(out) == 0 {
		if queueOnly {
			fmt.Println("没有待处理会话。")
		} else {
			fmt.Println("没有其它会话。")
		}
		return nil
	}
	fmt.Printf("%-6s  %-12s  %-8s  %-20s  %s\n", "ID", "STATUS", "AGENT", "NAME", "DIR")
	for _, s := range out {
		status := s.Status
		if status == "" {
			status = "unknown"
		}
		agent := s.Agent
		if agent == "" && s.Supervisor {
			agent = "supervisor"
		}
		fmt.Printf("%-6s  %-12s  %-8s  %-20s  %s\n", s.ID, status, agent, s.Label, s.Workdir)
		if s.StatusDetail != "" {
			fmt.Printf("        detail: %s\n", s.StatusDetail)
		}
		if s.Preview != "" {
			fmt.Printf("        preview: %s\n", oneLine(s.Preview, 160))
		}
	}
	return nil
}

func supervisorQueueCandidate(s busSession) bool {
	switch s.Status {
	case "needsReview",
		"working",
		"runningTool",
		"toolDone",
		"toolFailed",
		"waitingPermission",
		"compacting",
		"subagent":
		return true
	}
	d := strings.ToLower(s.StatusDetail)
	return strings.Contains(d, "权限") ||
		strings.Contains(d, "permission") ||
		strings.Contains(d, "失败") ||
		strings.Contains(d, "failed") ||
		strings.Contains(d, "error")
}

func runSupervisorRead(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("supervisor read", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "输出 JSON {id,lines,text} 而非纯文本")
	lines := fs.Int("lines", 200, "最多读取的尾部行数")
	screen := fs.Bool("screen", false, "读屏幕快照而非结构化 transcript")
	timeout := fs.Duration("timeout", 5*time.Second, "等待快照返回的超时")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rest := fs.Args()
	if len(rest) < 1 {
		return errors.New("usage: cc-handoff supervisor read <session-id> [--lines N] [--screen] [--json]")
	}
	target := rest[0]
	ob, err := supervisorReadOnce(ctx, target, *lines, !*screen, *timeout)
	if err != nil && !*screen && shouldFallbackToScreen(err) {
		// Transcript is the richer default, but a fresh agent may not have an
		// on-disk session id yet. Fall back to the rendered screen so the
		// supervisor can still inspect the session instead of dead-ending.
		ob, err = supervisorReadOnce(ctx, target, *lines, false, *timeout)
	}
	if err != nil {
		return err
	}
	text := string(ob)
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(map[string]any{
			"id":    target,
			"lines": *lines,
			"text":  text,
		})
	}
	fmt.Println(text)
	return nil
}

func supervisorReadOnce(ctx context.Context, target string, lines int, transcript bool, timeout time.Duration) ([]byte, error) {
	payload, err := json.Marshal(map[string]any{
		"from":       os.Getenv("CC_SESSION_ID"),
		"to":         target,
		"kind":       "read",
		"lines":      lines,
		"transcript": transcript,
	})
	if err != nil {
		return nil, err
	}
	return publishAndAwait(ctx, payload, timeout)
}

func shouldFallbackToScreen(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "transcript") ||
		strings.Contains(msg, "不是 agent") ||
		strings.Contains(msg, "没有 transcript")
}

// runSupervisorSpawn asks the desktop App to open a NEW app-managed session in a
// named project. It drops a kind:"spawn" request into the same outbox the App
// already watches; the App resolves the project, launches the session via the
// same path as the project right-click (so it lands in the session tree, gets
// CC_BUS_DIR seeded, and shows up in `supervisor overview`), and writes the new
// session id back as the <id>.ok receipt — which we print. This is the managed
// alternative to `workspace open --window`, which only spawns a detached shell.
func runSupervisorSpawn(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("supervisor spawn", flag.ContinueOnError)
	agent := fs.String("agent", "claude", "agent: claude|codex|shell")
	supervisor := fs.Bool("supervisor", false, "起总管会话(agent 仍为 claude|codex)")
	worktree := fs.String("worktree", "", "在项目的某个 worktree 目录下开(默认项目根;必须是项目根或其 .worktrees/ 下)")
	workspace := fs.String("workspace", "", "项目名重复时用 workspace 名消歧")
	timeout := fs.Duration("timeout", 10*time.Second, "等待 App 开会话返回的超时")
	// parseFlexible so `spawn <project> --agent codex` works regardless of order.
	pos, err := parseFlexible(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return errors.New("usage: cc-handoff supervisor spawn <project> [--agent claude|codex|shell] [--supervisor] [--worktree PATH] [--workspace NAME]")
	}
	payload, err := json.Marshal(map[string]any{
		"from":       os.Getenv("CC_SESSION_ID"),
		"kind":       "spawn",
		"project":    pos[0],
		"workspace":  *workspace,
		"agent":      *agent,
		"supervisor": *supervisor,
		"workdir":    *worktree,
	})
	if err != nil {
		return err
	}
	ob, err := publishAndAwait(ctx, payload, *timeout)
	if err != nil {
		return err
	}
	id := strings.TrimSpace(string(ob))
	if id == "" {
		fmt.Printf("已在项目 %s 下开会话\n", pos[0])
	} else {
		fmt.Printf("已开会话 %s(项目 %s)\n", id, pos[0])
	}
	return nil
}

func runSupervisorDecide(args []string) error {
	fs, dir := supervisorDirFromFlag(args, "supervisor decide")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rest := fs.Args()
	if len(rest) < 2 {
		return errors.New("usage: cc-handoff supervisor decide [--dir DIR] <title> <body...>")
	}
	root := supervisorRoot(*dir)
	if err := os.MkdirAll(root, 0o755); err != nil {
		return err
	}
	path := filepath.Join(root, "decisions.md")
	now := time.Now().Format("2006-01-02 15:04")
	entry := fmt.Sprintf("\n## %s %s\n\n%s\n", now, rest[0], strings.Join(rest[1:], " "))
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.WriteString(entry); err != nil {
		return err
	}
	fmt.Println(path)
	return nil
}

func oneLine(s string, max int) string {
	s = strings.Join(strings.Fields(s), " ")
	if max <= 0 || len(s) <= max {
		return s
	}
	if max <= 1 {
		return s[:max]
	}
	return s[:max-1] + "…"
}
