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

---

## 3. Handoff package schema

完整定义见 `pkg/handoffschema/package.go`,JSON schema 见
[`handoff-package.schema.json`](handoff-package.schema.json)。要点:

- **diff 模式 vs module-brief 模式 vs request 模式**(见 §6)
- **`Kind`**:`""` / `"delivery"`(默认,正向 /handoff)或 `"request"`(反向 /request)。
  空字符串通过 `Package.EffectiveKind()` 解释为 delivery,保证旧 payload 兼容
- **`RespondsTo`**:request 模式不携带;delivery 模式可以携带原 request id,
  接收端 prompt / summary.md 会渲染「↩️ 回应 r_xxx」banner 闭环
- **附件分离**:`Attachments` 只存元信息(name / sha256 / size),字节通过单独的
  `/v1/handoffs/{id}/attachments/{name}` 端点上传 / 下载。设计上是为了让 `package.json`
  本身保持小、可 inline,大文件(全量 diff 截图等)按需取
- **`SchemaVersion = 1`**:破坏性变更先写迁移路径再升版本
- **`ReplacesID`**:重发场景下指向被替换的旧 handoff,但 relay 当前不做级联失效

---

## 4. SQLite schema

VPS `/var/lib/cc-handoff/relay.db`,WAL 模式。三张表:

```sql
CREATE TABLE handoffs (
  id          TEXT PRIMARY KEY,           -- h_YYYYMMDD_XXXXXXXX
  sender      TEXT NOT NULL,
  recipient   TEXT NOT NULL,
  urgency     TEXT NOT NULL,              -- normal | urgent
  state       TEXT NOT NULL,              -- pending | picked | retracted
  created_at  INTEGER NOT NULL,           -- unix millis
  picked_at   INTEGER,                    -- set by ack
  repo_name   TEXT NOT NULL,              -- denormalized for /list
  branch      TEXT NOT NULL,
  headline    TEXT NOT NULL,              -- first line of summary_md
  kind        TEXT NOT NULL DEFAULT '',   -- '' (legacy) / 'delivery' / 'request'
  payload     TEXT NOT NULL               -- full Package JSON
);
CREATE INDEX idx_handoffs_recipient_state_created
  ON handoffs(recipient, state, created_at);

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

- 列表查询(`GET /v1/handoffs?recipient=X`)只读 denormalized 列,不解 payload
- `kind` 列 是后加的 —— 老库通过启动时 `ALTER TABLE handoffs ADD COLUMN kind ...`
  幂等迁移补上(SQLite 报 "duplicate column name" 时跳过)。`kind=''` 视作 delivery
- ack 是 conditional UPDATE + 二次读判定,保证幂等(已 picked 不报错,只是不动 state)
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

## 6. Mode 区分:diff / module-brief / request

cc-handoff 有三种发送场景,通过 `Package.Kind` + `Package.Git` 字段区分:

| | diff 模式 | module-brief 模式 | request 模式(反向) |
|---|---|---|---|
| **触发命令** | `/handoff` slash | `/handoff-module <path...>` | `/request` slash |
| **方向** | sender → recipient(后端 → 前端) | sender → recipient(后端 → 前端) | sender → recipient(前端 → 后端) |
| **场景** | 刚写完一段改动想推过去 | 模块早就合并、前端要新做集成 | 前端发现后端缺字段 / 缺能力,让后端补 |
| **`Kind`** | `delivery`(或空,向前兼容) | `delivery` | `request` |
| **`Git` 字段** | 有(commits + changed_paths) | nil | nil(只取 branch / head_sha 做参考) |
| **`ModulePaths`** | 空 | 用户给的模块路径数组 | 空(reject 非空) |
| **`APIDelta`** | 有(若 swagger 配置) | 无 | 无 |
| **`TargetingHints`** | 有(rules 跑 changed_paths) | 有(rules 跑模块 *.go 文件) | 无 |
| **`SummaryMD`** | Claude 写的对接说明 | Claude 读 routes/dto 后整理的完整 API 契约 brief | Claude 写的需求描述(what's needed / why / acceptance) |
| **接收端 prompt 模板** | "读 diff 配 INTEGRATION.md" | "按 brief 调对应客户端、注意契约一致" | "读需求 → 设计响应方案到 `docs/requests/<id>.md` → 等 review;实现完跑 /handoff 时带 `responds_to`" |
| **`RespondsTo`** | 可选,关联到 request 触发的回送 | 可选,同 diff | 不携带(API 阻止) |

接收端模板选择顺序:`renderPromptMD` 先判断 `EffectiveKind() == KindRequest` 走 request 分支;
否则按现有 `Git == nil` 逻辑挑 module-brief / diff,这样不依赖 `ModulePaths` 字段的存在(兼容老 MCP)。

**闭环**:request 通过 `/request` 发送 → 后端 `/pickup` 拉到 request 模板 →
后端实现完 `/handoff` 时把 `responds_to=<原 request id>` 设进去 →
前端 `/pickup` 看到这次 handoff 的 prompt 顶端有「↩️ 回应 r_xxx」banner,可追溯。

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

`me` / `partner` / `repo_name` 在多个来源之间合并,优先级从高到低:

| 字段 | 1. CLI flag | 2. repo `.cc-handoff.toml` | 3. user `~/.config/cc-handoff/config.toml` | 4. 默认 |
|---|---|---|---|---|
| `Me` | (无 flag) | `[identity].me` | `identity` | — (必须有) |
| `Partner` | `--to ID` (submit) | `[identity].partner` | — | — (必须有) |
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
