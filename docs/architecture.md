# cc-handoff 架构

读完这份文档,你会知道每个组件做什么、数据怎么流、配置在哪、出错时该看哪里。
**面向想理解或扩展系统的开发者**;部署和日常运维看 [`deployment.md`](deployment.md),
跨端 schema 看 [`handoff-package.schema.json`](handoff-package.schema.json) 与
[`pkg/handoffschema/package.go`](../pkg/handoffschema/package.go)。

---

## 1. Components

三个 Go 二进制 + 两端的 Claude Code 进程。

| 组件 | 跑在哪 | 协议入口 | 主要职责 |
|---|---|---|---|
| `cc-relay` | VPS,systemd service | HTTP+SSE on `127.0.0.1:8080` | 收 / 发 handoff、广播 SSE 事件、按 recipient 鉴权 |
| `cc-handoff` (CLI) | 两端开发者 Mac | argv | `init` / `submit` / `list` / `pickup` / `watch` / `comment` / `watch print-unit` |
| `cc-handoff-mcp` | 两端开发者 Mac,Claude Code 通过 stdio 拉起 | MCP / stdio | 把 CLI 动作全部暴露为 MCP 工具,共 13 个:`submit_handoff` / `submit_request` / `list_inbox` / `pickup_handoff` / `comment_handoff` / `status_handoff` / `list_sent` / `list_history` / `retract_handoff` / `list_local_inbox` / `list_online_users` / `check_drift` / `link_linear`(最后一个走可选 Linear 集成,见 §11)。给 Claude Code 内的 `/handoff` `/pickup` `/request` `/handoff-from-linear` slash command 用 |
| `cc-handoff watch` (常驻) | 接收侧 Mac,launchd / systemd user | SSE 长连接 | 拉服务端事件、把 handoff 落到 `.claude/handoff-inbox/<id>/`、必要时弹通知 / `claude -p` |

VPS 一定挂反向代理(caddy / nginx)终结 TLS,relay 自己只听 loopback。
`flush_interval -1` 是 SSE 必须的反向代理配置。

---

## 2. Sequence diagrams

### 2.1 submit (后端发送)

```
后端 Claude        cc-handoff-mcp          cc-relay              接收侧 watch
   │                    │                    │                       │
   │ /handoff (slash)   │                    │                       │
   ├──────────────────► │                    │                       │
   │                    │ build package      │                       │
   │                    │   (git diff,       │                       │
   │                    │    swagger delta,  │                       │
   │                    │    rules → hints)  │                       │
   │                    │                    │                       │
   │                    │ POST /v1/handoffs  │                       │
   │                    ├──────────────────► │                       │
   │                    │                    │ INSERT handoffs       │
   │                    │                    │ broadcast SSE         │
   │                    │                    │   handoff.created ────┤
   │                    │ 201 + handoff_id   │                       │
   │                    │ ◄──────────────────┤                       │
   │ id, recipient,     │                    │                       │
   │ targeting hints    │                    │                       │
   │ ◄──────────────────┤                    │                       │
```

### 2.2 pickup (前端接收)

```
接收侧 watch                    cc-relay              前端 Claude       cc-handoff-mcp
   │ (always running)              │                    │                  │
   │ ── SSE handoff.created ───────┤                    │                  │
   │ GET /v1/handoffs/{id}         │                    │                  │
   │ ────────────────────────────► │                    │                  │
   │ 200 + package json            │                    │                  │
   │ ◄──────────────────────────── │                    │                  │
   │ Materialize:                  │                    │                  │
   │  .claude/handoff-inbox/<id>/  │                    │                  │
   │    summary.md prompt.md       │                    │                  │
   │    api-delta.md package.json  │                    │                  │
   │ Optional notify / launch      │                    │                  │
   │                               │                    │                  │
   │                               │                    │ /pickup (slash)  │
   │                               │                    ├────────────────► │
   │                               │ list_inbox         │                  │
   │                               │ ◄──────────────────┤ list_inbox       │
   │                               │ pickup_handoff     │                  │
   │                               │ ◄──────────────────┤ pickup_handoff   │
   │                               │ POST /v1/handoffs/ │                  │
   │                               │   {id}/ack         │                  │
   │                               │ Tool returns       │                  │
   │                               │ integration prompt │                  │
   │                               │   (also re-mat.)   │                  │
   │                               │                    │ Claude reads     │
   │                               │                    │ local code,      │
   │                               │                    │ writes           │
   │                               │                    │ INTEGRATION.md   │
```

### 2.3 comment (双向旁路)

任意一方 → `comment_handoff` MCP / `cc-handoff comment` CLI → relay → SSE
`comment.created` 推到对方的 watch → 追加到 `comments.md`。可读 / 可写,无 ack。

**wake-on-comment(可选,Claude Code 才有)**:接收端在 `.cc-handoff.toml` 设置
`[triggers].wake_on_comment = true` 后,watch 收到 partner comment 会额外落一份
`<inbox>/<id>/unread/<commentID>.json` marker;Claude Code 的 Stop hook 调用
`cc-handoff stop-hook`,在 Claude 试图结束 turn 时把 marker 内容塞进
`hookSpecificOutput.additionalContext` 并返回 `{"decision":"block"}`,Claude 会被
拉回下一 turn,reply 直接进 context;hook 在输出 JSON 前清掉 marker 防止循环。
`cc-handoff init --with-wake-on-comment` 会幂等地把这个 hook 写进
`.claude/settings.json`。

### 2.4 本地会话总线「真插话」(同机 peer,hook 注入)

桌面 App 把 peer 消息送进兄弟会话有两条路,按目标 agent 是否在跑 turn 选:

- **目标空闲** → 直接 paste 进对方 PTY(`pasteText(submit:true)`,立即起 turn)。
- **目标正忙(mid-turn)** → 写一份 `$CC_BUS_DIR/inbox/<session-id>/<seq>.json`
  (`internal/localbus`,原子 tmp+rename、FIFO),由目标会话的 **Stop hook**
  在当前 turn 结束时兜底(`{"decision":"block"}` 拉一个新 turn)。
  `PostToolUse` 只记录活动,不 drain inbox:Codex 的 PostToolUse feedback 会替换刚完成的工具输出,
  不适合做 peer-message 投递。`Stop` 且 `stop_hook_active` 时直接 bail(不 drain,留给下一次)以免丢消息。

忙/闲由 App 的 BEL「完成」检测推导(agent 停下才响铃):起 turn 置 `busy`,铃落清除。

**门控**:hook command 是 `[ -n "$CC_BUS_DIR" ] && cc-handoff bus-hook || true`。只有
App 唤起的会话才有 `CC_BUS_DIR`,所以这条装在用户级配置(Claude `~/.claude/settings.json`、
Codex `~/.codex/hooks.json`)里也只在 App 会话里真正干活,别处亚毫秒 no-op。两端 hook 字段
Stop 契约一致(`additionalContext`/`decision:block`),同一个 `cc-handoff bus-hook` 通吃;App 启动时
`cc-handoff bus-hook install` 幂等写入。Codex 的 `features.hooks` 默认开,首次可能需对该 hook
授信一次(或启动加 `--dangerously-bypass-hook-trust`)。

### Codex / Claude hook 事件记录

依据 OpenAI Codex hooks 文档(https://developers.openai.com/codex/hooks),当前 Codex
生命周期事件共 10 类。`cc-handoff bus-hook` 全部安装,用于记录执行活动和捕获 `session_id`;
只有 `Stop` 会 drain 本地 bus inbox 并用 `decision:block` 拉起 continuation。

通用字段:
`session_id`、`transcript_path`、`cwd`、`hook_event_name`、`model`;
turn-scoped 事件带 `turn_id`;
`SessionStart`、`PreToolUse`、`PermissionRequest`、`PostToolUse`、`UserPromptSubmit`、
`SubagentStart`、`SubagentStop`、`Stop` 还带 `permission_mode`。

| Hook | 什么时候触发 | 额外可记录字段 |
| --- | --- | --- |
| `SessionStart` | 会话 startup/resume/clear/compact 时 | `source` |
| `UserPromptSubmit` | 用户 prompt 提交前 | `turn_id`, `prompt` |
| `PreToolUse` | 支持的工具调用前 | `turn_id`, `tool_name`, `tool_use_id`, `tool_input` |
| `PermissionRequest` | Codex 准备请求权限时 | `turn_id`, `tool_name`, `tool_input`, `tool_input.description` |
| `PostToolUse` | 支持的工具返回后 | `turn_id`, `tool_name`, `tool_use_id`, `tool_input`, `tool_response` |
| `PreCompact` | compact 前 | `turn_id`, `trigger` |
| `PostCompact` | compact 后 | `turn_id`, `trigger` |
| `SubagentStart` | 子代理启动时 | `turn_id`, `agent_id`, `agent_type`, `permission_mode` |
| `SubagentStop` | 子代理停止时 | `turn_id`, `agent_id`, `agent_type`, `agent_transcript_path`, `stop_hook_active`, `last_assistant_message` |
| `Stop` | turn 停止时 | `turn_id`, `stop_hook_active`, `last_assistant_message` |

依据 Claude Code hooks 文档(https://code.claude.com/docs/en/hooks),Claude Code 当前
hook 面更大。安装层为 Claude 和 Codex 分开维护事件列表:Claude 默认安装记录型事件,Codex
只装 Codex 官方支持的 10 类,避免 Codex hooks.json 出现未知事件。`MessageDisplay` 会按输出
delta 高频触发,默认不装,否则会明显拖慢 Claude 输出;`WorktreeCreate` 需要 hook 返回 worktree
path,也默认不装,避免日志型 hook 干扰 Claude 自己创建 worktree。

Claude 通用字段:
`session_id`、`transcript_path`、`cwd`、`hook_event_name`;
多数 turn/tool/subagent/permission 相关事件还带 `permission_mode`。

| Claude Hook | 什么时候触发 | 额外可记录字段 |
| --- | --- | --- |
| `SessionStart` | 会话 startup/resume/clear/compact 时 | `source` |
| `Setup` | 会话首次 prompt 前的初始化阶段 | 通用字段 |
| `UserPromptSubmit` | 用户 prompt 提交前 | `prompt` |
| `UserPromptExpansion` | prompt expansion 前后 | expansion 相关输入(按 Claude 版本 payload) |
| `MessageDisplay` | Claude 输出内容显示前 | `turn_id`, `message_id`, `index`, `final`, `delta` |
| `PreToolUse` | 工具调用前 | `tool_name`, `tool_input`, `tool_use_id` |
| `PermissionRequest` | 即将请求用户权限时 | `tool_name`, `tool_input`, `permission_suggestions` |
| `PermissionDenied` | 权限被拒后 | `tool_name`, `tool_input`, denial 相关字段 |
| `PostToolUse` | 工具成功完成后 | `tool_name`, `tool_input`, `tool_response`, `tool_use_id`, `duration_ms` |
| `PostToolUseFailure` | 工具失败后 | `tool_name`, `tool_input`, error/result 相关字段 |
| `PostToolBatch` | 一批工具调用完成后 | batch/tool results 相关字段 |
| `PreCompact` | compact 前 | `trigger` |
| `PostCompact` | compact 后 | compact 后通用字段 |
| `SubagentStart` | 子代理启动时 | `agent_id`, `agent_type` |
| `SubagentStop` | 子代理停止时 | `stop_hook_active`, `agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message`, `background_tasks`, `session_crons` |
| `TaskCreated` | agent team 任务创建时 | `task_id`, `task_subject`, `task_description`, `teammate_name`, `team_name` |
| `TaskCompleted` | agent team 任务完成/关闭时 | `task_id`, `task_subject`, `task_description`, `teammate_name`, `team_name` |
| `TeammateIdle` | agent team 队友空闲时 | teammate/team/task 相关字段 |
| `Stop` | turn 停止时 | `stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons` |
| `StopFailure` | Stop continuation 失败时 | `error`, `error_details`, `last_assistant_message` |
| `Notification` | Claude 发送通知时 | `message`, `notification_type` |
| `ConfigChange` | settings/policy/skill 配置变化时 | `source`, `file_path` |
| `WorktreeCreate` | 创建 worktree 时 | worktree 相关路径/上下文字段 |
| `WorktreeRemove` | 删除 worktree 时 | worktree 相关路径/上下文字段 |
| `CwdChanged` | 当前工作目录变化时 | `old_cwd`, `new_cwd` |
| `FileChanged` | watch path 下文件变化时 | `file_path` |
| `InstructionsLoaded` | 指令文件加载后 | instruction/source 相关字段 |
| `SessionEnd` | 会话退出/sigint/error 时 | exit/error 相关字段 |
| `Elicitation` | MCP server 请求用户输入前 | `mcp_server_name`, `message`, `mode`, `requested_schema`, `url` |
| `ElicitationResult` | 用户响应 MCP elicitation 后 | `mcp_server_name`, `action`, `mode`, `elicitation_id`, `content` |

执行记录落盘在 `$CC_BUS_DIR/events/<session-id>/`,保留最近 200 条。记录会保留通用字段、
常见事件字段和一个用于 UI 的 `summary`;会话总览只携带最近几条截断摘要,打开/监听具体会话时
才广播更完整的最近执行记录。

---

## 3. Handoff package schema

完整定义见 `pkg/handoffschema/package.go`,JSON schema 见
[`handoff-package.schema.json`](handoff-package.schema.json)。要点:

- **diff 模式 vs module-brief 模式 vs request 模式**(见 §6)
- **`Kind`**:`""` / `"delivery"`(默认,正向 /handoff)、`"request"`(反向 /request)、`"bug"` 或 `"capsule"`。
  空字符串通过 `Package.EffectiveKind()` 解释为 delivery,保证旧 payload 兼容
- **`DeliveryTarget`**:可选;记录发送时选择的团队定向(`project_id` / `org_id` / `member`),
  在 relay 已展开成具体 `Recipients` 后仍保留原始团队边界,方便接收端区分团队包和普通多收件包
- **`RespondsTo`**:request 模式不携带;delivery 模式可以携带原 request id,
  接收端 prompt / summary.md 会渲染「↩️ 回应 r_xxx」banner 闭环
- **附件分离**:`Attachments` 只存元信息(name / sha256 / size),字节通过单独的
  `/v1/handoffs/{id}/attachments/{name}` 端点上传 / 下载。设计上是为了让 `package.json`
  本身保持小、可 inline,大文件(全量 diff 截图等)按需取
- **`SchemaVersion = 1`**:破坏性变更先写迁移路径再升版本
- **`ReplacesID`**:重发场景下指向被替换的旧 handoff,但 relay 当前不做级联失效

---

## 4. SQLite schema

VPS `/var/lib/cc-handoff/relay.db`,WAL 模式。四张表:

```sql
CREATE TABLE handoffs (
  id           TEXT PRIMARY KEY,           -- h_YYYYMMDD_XXXXXXXX
  sender       TEXT NOT NULL,
  recipient    TEXT NOT NULL,              -- 单收件人(2 方流);多收件人时仍存 recipients[0]
  recipients   TEXT NOT NULL DEFAULT '',   -- JSON 数组,bug kind 用;空表示走单收件人语义
  urgency      TEXT NOT NULL,              -- normal | urgent
  state        TEXT NOT NULL,              -- pending | picked | retracted
  created_at   INTEGER NOT NULL,           -- unix millis
  picked_at    INTEGER,                    -- 全部 slot terminal 时才置
  repo_name    TEXT NOT NULL,              -- denormalized for /list
  branch       TEXT NOT NULL,
  headline     TEXT NOT NULL,              -- first line of summary_md
  kind         TEXT NOT NULL DEFAULT '',   -- '' (legacy) / 'delivery' / 'request' / 'bug'
  bug_group_id TEXT NOT NULL DEFAULT '',   -- 同一 bug 的转交链共享;评论按它广播
  payload      TEXT NOT NULL               -- full Package JSON
);
CREATE INDEX idx_handoffs_recipient_state_created
  ON handoffs(recipient, state, created_at);
CREATE INDEX idx_handoffs_bug_group
  ON handoffs(bug_group_id);

-- 每个 recipient 一行,bug kind 用来跟踪 per-slot 状态。
-- 2 方 handoff 也有一行(迁移时回填),让 JOIN 查询统一。
CREATE TABLE handoff_recipients (
  handoff_id TEXT NOT NULL REFERENCES handoffs(id) ON DELETE CASCADE,
  recipient  TEXT NOT NULL,
  state      TEXT NOT NULL DEFAULT 'pending',  -- pending | picked | reassigned
  picked_at  INTEGER,
  PRIMARY KEY (handoff_id, recipient)
);
CREATE INDEX idx_handoff_recipients_recipient_state
  ON handoff_recipients(recipient, state);

CREATE TABLE comments (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  handoff_id  TEXT NOT NULL REFERENCES handoffs(id) ON DELETE CASCADE,
  sender      TEXT NOT NULL,
  body        TEXT NOT NULL,
  created_at  INTEGER NOT NULL
);

CREATE TABLE attachments (
  handoff_id  TEXT NOT NULL REFERENCES handoffs(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  sha256      TEXT NOT NULL,
  size        INTEGER NOT NULL,
  content     BLOB NOT NULL,
  PRIMARY KEY (handoff_id, name)
);
```

- 列表查询(`GET /v1/handoffs?as=recipient`)走 `handoffs JOIN handoff_recipients` —— 多收件人 bug 在每个收件人的 inbox 里都看得到,直到他们各自 ack 或 reassign
- `kind` / `recipients` / `bug_group_id` 列 都是后加的 —— 老库通过启动时 `ALTER TABLE handoffs ADD COLUMN ...` 幂等迁移补上(SQLite 报 "duplicate column name" 时跳过)。`kind=''` 视作 delivery
- 迁移时一次性把 legacy `handoffs` 行回填到 `handoff_recipients`(一行/handoff),确保旧数据走新 JOIN 路径
- `Ack(id, identity)` 翻 caller 那一行的 `handoff_recipients.state` → `picked`;只有所有 slot terminal(picked 或 reassigned)时才把 `handoffs.state` 推到 `picked`。已 ack 是幂等的(不报错)
- `Reassign(id, from, newPkg, reason)` 在一个事务里:翻 from 那行为 `reassigned`、给原 handoff 分配/继承 `bug_group_id`、写入新 handoff 继承同 group。**环路防护**:`to` 出现在同 group 内任何 handoff_recipients 行(不论 state)即拒(`ErrConflict`,server 映射 409),用户改用 `comment_handoff` 协商
- **评论可见性 SQL**:`ListCommentsSince` 用 CTE 收集 caller 参与的所有 bug_group,然后 OR 进过滤条件 —— 旧 2 方 handoff `bug_group_id=''`,CTE 为空,语义等价旧查询
- 备份脚本 `scripts/backup.sh`(VPS 上 `cc-handoff-backup`):热备份 SQLite,
  `KEEP=N` 控制保留份数

---

## 5. Auth model

每个 identity(`me@team` / `alex@frontend`)在 VPS 端有一条 token,存在
`/etc/cc-handoff/tokens.json`。所有 HTTP 请求必须带 `Authorization: Bearer <token>`。

请求权限按 token 解出的 identity 检查:

| 端点 | 写约束 | 读约束 |
|---|---|---|
| POST /v1/handoffs | sender 必须等于 token identity | — |
| GET /v1/handoffs?recipient= | — | recipient 必须等于 token identity(只能列自己的) |
| GET /v1/handoffs/{id} | — | recipient 或 sender 等于 token identity |
| POST /v1/handoffs/{id}/ack | recipient 必须等于 token identity | — |
| POST /v1/handoffs/{id}/comments | sender 或 recipient 等于 token identity | — |
| GET /v1/handoffs/{id}/comments | — | sender 或 recipient 等于 token identity |
| GET /v1/comments?since=&limit= | — | 只返回调用者参与的 handoff 上、非自己发的 comment |
| GET/POST /v1/handoffs/{id}/attachments/* | 同上 | 同上 |
| GET /v1/events?recipient= | — | recipient 必须等于 token identity |

token 轮换:VPS 上 `sudo cc-handoff-rotate-token <identity>` 重写 tokens.json 并 SIGHUP relay。

---

## 6. Mode 区分:diff / module-brief / request / bug

cc-handoff 有四种发送场景,通过 `Package.Kind` + `Package.Git` 字段区分:

| | diff 模式 | module-brief 模式 | request 模式(反向) | bug 模式(测试端) |
|---|---|---|---|---|
| **触发命令** | `/handoff` slash | `/handoff-module <path...>` | `/request` slash | `/submit-bug` slash |
| **方向** | sender → recipient(后端 → 前端) | sender → recipient(后端 → 前端) | sender → recipient(前端 → 后端) | sender → recipients[](tester → backend/frontend/both) |
| **场景** | 刚写完一段改动想推过去 | 模块早就合并、前端要新做集成 | 前端发现后端缺字段 / 缺能力,让后端补 | 测试发现 bug,不一定知道哪端,先发一边或两边都发 |
| **`Kind`** | `delivery`(或空,向前兼容) | `delivery` | `request` | `bug` |
| **`Recipients` 字段** | 空(用 `Recipient` 单字段) | 空 | 空 | 数组,1-N 个收件人 |
| **`BugGroupID`** | 空 | 空 | 空 | 转交链上的 handoff 共享同一 group id;评论按 group 广播给所有参与者 |
| **`Git` 字段** | 有(commits + changed_paths) | nil | nil(只取 branch / head_sha 做参考) | nil |
| **`ModulePaths`** | 空 | 用户给的模块路径数组 | 空(reject 非空) | 空(reject 非空) |
| **`APIDelta`** | 有(若 swagger 配置) | 无 | 无 | 无 |
| **`TargetingHints`** | 有(rules 跑 changed_paths) | 有(rules 跑模块 *.go 文件) | 无 | 无 |
| **`DeliveryTarget`** | 可选,团队定向发送时记录 project/org/member | 同左 | 同左 | 同左 |
| **`SummaryMD`** | Claude 写的对接说明 | Claude 读 routes/dto 后整理的完整 API 契约 brief | Claude 写的需求描述(what's needed / why / acceptance) | 测试端写的 bug 描述(symptom / repro / expected / actual / 怀疑归属) |
| **接收端 prompt 模板** | "读 diff 配 INTEGRATION.md" | "按 brief 调对应客户端、注意契约一致" | "读需求 → 设计响应方案到 `docs/requests/<id>.md` → 等 review;实现完跑 /handoff 时带 `responds_to`" | "判定归属决策树:是我的 → 修复 + `docs/bugs/<id>.md`;不是我的 → `reassign_bug`;不确定 → `comment_handoff` 协商" |
| **`RespondsTo`** | 可选,关联到 request 触发的回送 | 可选,同 diff | 不携带(API 阻止) | 不携带 |

接收端模板选择顺序:`renderPromptMD` 按 `EffectiveKind()` switch —— `KindRequest` → request 模板;
`KindBug` → bug 模板;否则按 `Git == nil` 逻辑挑 module-brief / diff,这样不依赖 `ModulePaths` 字段的存在(兼容老 MCP)。

### Bug 模式与 reassign / 评论广播

bug 模式特有的多收件人和 reassign 链由 store 层的两个表协作:
- `handoffs.recipients` (JSON 数组) + `handoffs.bug_group_id` —— 多收件人元数据
- `handoff_recipients` —— 每个收件人一行(handoff_id, recipient, state ∈ {pending, picked, reassigned}, picked_at);
  `Ack` 只翻调用方那一行,所有行都 terminal 时才把 `handoffs.state` 推到 `picked`
- `Reassign(id, from, newPkg, reason)` —— 在事务里把 caller 那一行翻 `reassigned`、给原 handoff 分配/继承 `bug_group_id`、把新 handoff 写进 group(`ReassignedFrom`、`ReassignedReason` 都进 payload)。若原 bug 携带 `DeliveryTarget`,新包继承 `project_id` / `org_id`,并把 `member` 重定向为新的接收人
- **环路防护**:`Reassign` 拒绝把 bug 转给同一 group 内**已经出现过的任何身份**(不论该身份现在是 pending/picked/reassigned),让回旋只能通过 `comment_handoff` 协商
- **评论可见性 SQL**:`ListCommentsSince` 走一个 CTE 收集"我参与过的全部 bug_group_id",再 union 出"我是 sender/recipient" 的 handoff —— 旧 2 方 handoff 的 `bug_group_id` 为空,CTE 跑出来是空集,语义和老查询一致

**闭环 1(request)**:request 通过 `/request` 发送 → 后端 `/pickup` 拉到 request 模板 →
后端实现完 `/handoff` 时把 `responds_to=<原 request id>` 设进去 →
前端 `/pickup` 看到这次 handoff 的 prompt 顶端有「↩️ 回应 r_xxx」banner,可追溯。

**闭环 2(bug)**:tester `/submit-bug` 同时发给 backend、frontend → 任一端 `/pickup` 后按决策树走:
是自己的 → 修复 + ack;不是 → `reassign_bug` 转交对端(新 handoff 沿用同一个 `bug_group_id`,
原 slot 标 `reassigned`);不确定 → `comment_handoff` 拉对端协商 —— 因为评论按 `bug_group_id`
广播给三方,tester 不再需要人肉中转。`status_handoff` 的 `pickup_by` 字段给 tester 看每端的 pickup 状态。

---

## 7. Threat model

MVP 安全姿态有意保守。明确防的 / 不防的:

- **TLS + Bearer token 防的**:
  - 公网窃听(TLS)
  - 误把别人 inbox 的 handoff 拿走(token-bound identity 校验)
  - VPS 公开监听(loopback-only,反代终结 TLS)
- **不防的**:
  - VPS 沦陷 → 攻击者能读全部 handoff payload 与 comment(plaintext at rest)
  - token 泄漏 → 等价于该 identity 的全部权限,直到 rotate
  - 客户端到 Claude Code 的 stdio 通道 → 信任本机
- **延后**:E2E 加密(sender 公钥加密 payload,recipient 私钥解)— 设计上预留
  schema 字段位置但未实施;判断点是 VPS 攻击面变大或 payload 含敏感凭证时

---

## 8. Extension points

不规定方案,只标位置,方便后人接:

- **触发**:目前只手动 `/handoff`。Stop hook / pre-commit / CI artifact 想接进来,
  挂在 `cc-handoff submit` 这一层(`cmd/cc-handoff/submit.go`)
- **包内容**:`internal/handoff/build.go::Build` 是构造 `Package` 的唯一入口,
  新增字段先在这里塞,接收端在 `internal/inbox/materialize.go` 渲染
- **协议变更**:bump `pkg/handoffschema.SchemaVersion`,在 store 迁移加新列,
  接收端基于版本兜底
- **第三个 / 第 N 个收件人**:relay schema 已经按 `recipient` 索引,改成多收件人
  需要 fan-out 逻辑(insert N 行)+ 协议层带 `recipients[]`
- **rules 引擎**:`internal/rules/engine.go` 是把 changed_paths 映射到前端建议位置
  的纯函数;新增映射形态(比如根据 commit 主题)在这里加
- **workspace / worktree 启动**:`config.BuildLaunchCommand` 是启动命令的唯一真相源;
  cmd 层 `launchProject`(`cmd/cc-handoff/launch.go`)负责执行它——`execInShell` 原地
  替换当前进程(SSH 友好),`notify.OpenTerminalCommand` 开新终端窗。要加新启动策略
  (tmux/远程触发等)就接到 `launchProject`,命令串本身不变。详见 [`workspaces.md`](workspaces.md)

---

## 9. Failure modes & recovery

| 故障 | 行为 | 用户怎么处理 |
|---|---|---|
| relay 不可达 | submit 直接报错,不重试,不入队 | 用户重发(`/handoff` 再点一次)。**故意不做后台队列**——状态可见性优于"看起来什么都没发生" |
| 部分 pickup(已下载未 ack) | `pickup_handoff --no-ack` 让用户先看再 ack;ack 是幂等的(已 picked 重发依旧返回成功) | 重新跑 `pickup_handoff` 即可 |
| watch SSE 断开 / 前端机器下线 | `internal/transport/sse_client.go` 指数退避重连;同时 watch 启动时跑一次 catch-up:`/v1/handoffs?state=pending` 拉所有未 pickup 的 handoff、`/v1/comments?since=<cursor>` 拉新 comment,经同一 SSE handler 派发(通知+落盘+auto-launch)。游标存 `.claude/handoff-inbox/.watch-cursor.json`,首次运行 bootstrap 到当前 max id 不重放历史 | 重启 watch 即可补;`--no-catchup` 可临时关掉 |
| token 过期 / 轮换 | 客户端 401 直接报错 | VPS 上 `cc-handoff-rotate-token`,客户端改 user config 后重启 watch |
| sender 改了文件再发 | `ReplacesID` 字段标了但 relay 不级联失效旧的 | 接收端通过 list 看到两条;按 created_at 取最新即可 |
| 接收端 `INTEGRATION.md` 写错 | 文档里强调"写完停下等 review,不直接改代码" | 人工 review 时驳回;接收端 Claude 重做 |

---

## 10. Identity & repo resolution

团队/项目模式下,发送者身份由登录态或 machine token 决定,relay 会覆盖客户端包里的 `sender`。项目配置里的 `[identity]` 只作为旧点对点兼容入口保留。

| 字段 | 1. CLI flag | 2. repo `.cc-handoff.toml` | 3. user `~/.config/cc-handoff/config.toml` | 4. 默认 |
|---|---|---|---|---|
| `Me` | (无 flag) | `[identity].me` (legacy override) | `identity` | — (必须有) |
| `Recipient` | `--to ID` (legacy) / `--project` / `--org` / `--member` | `[identity].partner` (legacy only) | — | bound team project |
| `RelayURL` / `Token` | — | — | `relay_url` / `token` | — (必须有) |
| `RepoName` | `--repo NAME` (init) | `[paths].repo` | — | `basename(repoRoot)` |
| `Base` | `--base REF` | `[paths].base` | — | `origin/main` |
| `Swagger` | `--swagger PATH` (init) | `[paths].swagger` | — | (空,跳过 API delta) |

合并逻辑在 `internal/config/config.go::Resolve`。
**仓库根判定**:`RepoConfigPath` 从 cwd 向上找 `.git`,找到的目录就是 repo 根,
否则 fallback 到 cwd。

---

## 11. Linear integration

可选的双向同步层。设计原则:**cc-handoff 二进制不直接调 Linear API**,所有 Linear 调用都通过 prompt 让 Claude Code 用自己已经装好的 Linear MCP server(`mcp__linear__*` 工具)去做。零 secret,零额外认证。

### 11.1 触发点

五个操作型 MCP 工具(`submit_handoff` / `submit_request` / `pickup_handoff` / `comment_handoff` / `retract_handoff`)在 handler 返回前条件追加一段 markdown:

```
## 同步到 Linear (<事件名>)
请用 mcp__linear__<op> ...
```

只有当 `Resolved.Linear.Enabled && Resolved.Linear.SyncOnX == true` 时才渲染,否则返回空串,工具输出与未集成时字节一致。实现在 `internal/mcp/linear.go:linearSyncBlock`,5 个 handler 调用点都在 `internal/mcp/tools.go`。

### 11.2 数据流

```
Claude Code ──► mcp__cc-handoff__<op>  ──►  cc-handoff-mcp
                       │                          │
                       ▼ (sync block in result)   ▼
                Claude reads prompt        relay SQLite (handoff itself)
                       │
                       ▼
                mcp__linear__<op>  ──►  Linear API (auth/HTTP owned by Linear MCP)
                       │
                       ▼
                mcp__cc-handoff__link_linear  ──►  <inbox>/sent/<id>/linear.json
```

`link_linear` 是闭环工具:Claude 拿到 Linear issue identifier 后调它,把 `{handoff_id, identifier, url, linked_at}` 通过 `inbox.WriteLinearLink` 原子写到本地。后续 `status_handoff` / 同步段都能从这里恢复 issue id。

### 11.3 绑定锚点

两套互补的存储:

- **Linear 端**:issue 描述末尾嵌 `<!-- cc-handoff: h_YYYYMMDD_XXXXXXXX -->`(HTML 注释,Linear markdown 编辑器保留),后续 sync 段让 Claude 用 `mcp__linear__get_issue` 全文搜锚点反查 issue
- **本地端**:`<inbox-dir>/sent/<handoff-id>/linear.json`(发送方),tmp+rename 原子写,格式见 `inbox.LinearLink`

两端任一存在都能恢复绑定。

### 11.4 配置 `[integrations.linear]`

| 字段 | 类型 | 含义 |
|---|---|---|
| `enabled` | bool | 总开关。`false` 时所有 sync block 返回空串,handoff 行为与未集成时一致 |
| `team_key` | string | Linear team prefix,用于 prompt 内的示例 issue id(如 `ENG-456`)。空时占位写 `ENG` |
| `default_labels` | []string | 创建 issue 时打的 label |
| `mcp_prefix` | string | Linear MCP 工具名前缀,缺省 `linear`(→ `mcp__linear__*`)。不同社区 MCP 实现可能用其它前缀,这里改 |
| `sync_on_submit` | bool | submit_handoff / submit_request 后是否追加 sync block |
| `sync_on_pickup` | bool | pickup_handoff 后是否追加 |
| `sync_on_comment` | bool | comment_handoff 后是否追加 |
| `sync_on_retract` | bool | retract_handoff 后是否追加 |

入口结构:`internal/config/config.go::LinearIntegration`,透传到 `Resolved.Linear`。

### 11.5 入站(reverse)流程

`/handoff-from-linear ENG-123` slash command(`internal/setup/templates/commands/handoff-from-linear.md`):

1. Claude 用 `mcp__linear__get_issue` 读 issue
2. 拼出 cc-handoff request summary(包含 title / description / acceptance / source URL)
3. 调 `mcp__cc-handoff__submit_request` 发出 handoff
4. 调 `mcp__linear__update_issue` 把 `<!-- cc-handoff: <new-id> -->` 锚点追加到 issue 描述
5. 调 `mcp__cc-handoff__link_linear` 写本地映射

### 11.6 失败降级

- Linear MCP 未配置 / 工具名错:Claude 看到指令但找不到工具 → 跳过同步段,handoff 主流程不受影响(prompt 里也明确写了"失败不要中断主流程")
- `link_linear` 写盘失败:tmp+rename,中途崩 tmp 残留下次覆盖,不会污染主映射

---

## State ownership

| 状态 | 由谁拥有 | 何时清理 |
|---|---|---|
| relay SQLite (`/var/lib/cc-handoff/relay.db`) | VPS | 不自动清理(MVP);备份脚本按 KEEP 滚动保留 |
| 接收端 `.claude/handoff-inbox/<id>/` | 接收侧 Mac | 用户手动;ack 后不删,留作 review 历史 |
| 接收端 `.claude/handoff-inbox/<id>/INTEGRATION.md` | 接收侧 Claude 写、人工 review、人工提交 | 进入接收端 git 仓库后由 git 管 |
| 发送侧 git refs | 发送侧 Mac(本地 git) | git 自己管;cc-handoff 不动 |
| MCP stdio session | Claude Code 进程 | 进程结束即销毁;无持久化 |
| user config `~/.config/cc-handoff/config.toml` | 用户 home(0o600) | 用户手动;`cc-handoff init` 会 prompt 后覆盖 |
| repo config `<repo>/.cc-handoff.toml` | 仓库根 | 提交进 git;`init` 会 prompt 后覆盖 |
| Claude Code MCP 注册 | `~/.claude.json` (user scope) 或 `.mcp.json` (project scope) | `claude mcp remove`;`init --with-mcp` 会先 remove 再 add(幂等) |
| `.claude/commands/{handoff,handoff-module,pickup,request}.md` | 仓库根 | 提交进 git;`init --with-commands` 带版本戳,旧版本会触发冲突 prompt |
