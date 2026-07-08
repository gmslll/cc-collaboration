# Infinite Agent Platform

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Go Reference](https://pkg.go.dev/badge/github.com/cc-collaboration.svg)](https://pkg.go.dev/github.com/cc-collaboration)

> [English](README.en.md) | **中文**

> Infinite Agent Platform 是 Infinite State Inc 面向企业内部研发团队的 Agent 开发与协作平台。它把项目、工作区、Agent 会话、协作任务、交付文档、审计历史和 relay 运维收进同一套自托管系统，让团队可以用 Claude Code、OpenAI Codex CLI 以及其它命令行 Agent 安全地协同完成研发工作。

> ⚙️ **兼容说明**：当前二进制、配置目录、MCP server 和部分 API 仍沿用 `cc-handoff` / `cc-relay` / `cc-handoff-mcp` 这些 legacy 名称，目的是让已部署的客户端、systemd unit、更新器和脚本不断线。产品名、UI 和文档定位从本版本起切换为 Infinite Agent Platform；命令示例中的 `cc-handoff` 是兼容层，不代表新的产品品牌。

## 平台定位

企业内部使用 AI 编码 Agent 时，真正难的不是“把一个 prompt 发给模型”，而是如何在团队、项目和机器之间建立可审计、可恢复、可治理的工作流：

- 多个 Agent 会话并行工作，需要知道谁在处理哪个项目、哪条分支、哪个工作区。
- 后端、前端、测试、运维之间需要交付上下文，而不是把临时说明散落在聊天窗口里。
- 内部平台需要账号、机器 token、项目成员、权限、审计、历史和安全运维，而不是每个人各自维护一堆本地脚本。
- 研发负责人需要一个能查看任务队列、协作交付、会话状态和项目入口的桌面 / Web / 移动端工作台。

Infinite Agent Platform 把这些能力组合成一个内部 Agent 开发平台：

- **Agent 工作台**：在 Flutter 桌面应用里管理工作区、项目、worktree、终端、git、代码编辑器和 Agent 会话。
- **协作任务队列**：把跨角色交付包装成结构化 work package，包含交付文档、Prompt、API delta、附件、评论、状态和审计历史。
- **企业 relay**：自托管 HTTP/SSE relay，提供账号登录、机器 token、项目成员、在线状态、协作任务、待办、胶囊广场和管理后台。
- **本地会话总线**：同一台机器上的多个 Agent 会话可以互发消息、读取可见屏幕、由 supervisor 统一协调。
- **移动与 Web 入口**：手机端用于远程查看 / 操作桌面工作区，Web UI 用于 relay 管理、协作任务查看、账号和 token 管理。

## 典型场景

- **跨团队交付**：后端 Agent 把接口变更、diff、swagger delta 和注意事项提交为 work package；前端 Agent 在自己的真实仓库中 pickup，生成集成计划或落地代码。
- **内部任务分派**：产品、测试、运维或项目负责人通过 relay 项目和待办把工作指派给成员或 Agent 会话，并持续追踪状态。
- **多 Agent 协作开发**：supervisor 观察多个会话，必要时读取屏幕、发消息、分配任务、汇总进度。
- **Agent 能力沉淀**：会话胶囊把一次有效 Agent 会话冻结成可复用的 persona、seed 和技能包，发布到内部 Agent 库。
- **安全运维**：管理员在 Web UI 创建 / 停用账号、重置密码、轮换机器 token，并通过自托管 relay 保留数据边界。

## 核心模块

**桌面 / 手机 App (`app/`)**

`app/` 是 Infinite Agent Platform 的主要工作台。桌面端聚焦研发执行：工作区 / 项目 / worktree 树、Claude / Codex 终端、git 面板、内置代码编辑器、任务队列、待办、会话总览、Agent 库和手机投屏。移动端聚焦远程查看、远程操作、状态提醒和轻量任务分派。

**企业 relay (`cc-relay`)**

relay 是自托管控制面，提供 REST + SSE、SQLite 持久化、账号和 token、项目权限、在线状态、任务队列、评论、附件、待办、会话胶囊和 Web 管理 UI。生产部署应放在 TLS 反向代理后，只监听 loopback。

**兼容 CLI / MCP (`cc-handoff`, `cc-handoff-mcp`)**

CLI / MCP 是现有部署的兼容入口。`cc-handoff submit/list/pickup/watch/comment`、Claude `/handoff` `/pickup`、Codex skill 和 MCP 工具仍然可用。新的产品语义把这些动作视为“创建 / 接收 / 审计 Agent work package”。

## 桌面 / 手机 App

**核心功能**

- **工作区 / 项目 / worktree 树**：一键在任意项目或分支 worktree 起 Claude / Codex 会话终端。终端懒恢复，支持从文件夹批量导入 git 仓库、项目按设备拖拽排序。
- **git 面板**：改动 / 暂存 / 提交 / 分支 / log / stash / diff，提供 JetBrains 风格逐文件右键菜单。
- **内置代码编辑器**：语法高亮、跳转到定义、可配置 LSP 和格式化插件。
- **任务队列**：查看分配给自己的 work package、我发起的任务、接收历史，支持接收并启动 Agent、复制执行 Prompt、评论、撤回、转交。
- **待办与项目管理**：relay 项目、成员、个人 / 团队待办、Linear 导入和 Agent 会话指派。
- **Agent 库**：把会话打成胶囊，沉淀成内部可复用的 Agent persona / seed / skill pack。
- **远程工作区**：把桌面 workspace 通过 relay 投到手机端，手机可查看 / 操作终端、传文件、看状态。

**平台**：桌面(macOS / Windows)为主，移动端(iOS / Android)侧重投屏 / 查看。终端、git、格式化、LSP 等本地能力仅桌面端生效。

**构建 / 运行**：`app/` 是标准 Flutter 工程，打包 / 签名脚本见 `scripts/`。桌面端功能需要宿主机装好对应命令行工具(git / 各语言服务器 / 格式化器)，没装的会在插件面板显示「未检测到」并给安装提示。

## 架构

最小生产拓扑包含一个企业 relay 和若干员工客户端:

```
员工桌面 / 手机 / Web              企业 VPS / 内网主机             员工 Agent 会话
──────────────────              ─────────────────             ───────────────
Flutter App / Web UI  ──HTTPS──►  TLS reverse proxy  ◄──SSE──  cc-handoff watch
Claude / Codex MCP    ──HTTPS──►        │                     cc-handoff-mcp
cc-handoff CLI        ──HTTPS──►  cc-relay:8080
                                        │
                              /var/lib/cc-handoff/relay.db
                              accounts + projects + queue + todos
```

- `cc-relay`:企业 relay systemd 服务,听 loopback,由反向代理终结 TLS。提供账号、项目、任务队列、待办、评论、附件、SSE、Web UI 和管理能力。
- Flutter App:员工桌面 / 手机工作台,连接 relay,同时在桌面端操作本地 git、终端、编辑器和 Agent 会话。
- `cc-handoff` (CLI):兼容入口。子命令:`init` / `submit` / `list` / `pickup` / `watch` / `comment` / `todo` / `workspace` 等。
- `cc-handoff-mcp`:Claude Code / Codex 通过 stdio 拉起的兼容 MCP server,把协作任务和 relay 操作暴露给 Agent。
- `cc-handoff watch`:接收侧常驻进程,SSE 长连接拉企业 relay 事件,落盘到 `.cc-handoff/inbox/<id>/`,必要时弹通知或按策略开新终端。

完整数据流、SQLite schema、auth、failure mode 见 [`docs/architecture.md`](docs/architecture.md)。

## 状态

v1.0.0 是 Infinite Agent Platform 的企业化重塑版本:

- ✓ 产品名、Flutter App、relay Web UI、文档和平台显示名切到 Infinite Agent Platform。
- ✓ legacy `cc-handoff` / `cc-relay` / `cc-handoff-mcp` 兼容层保留,便于已部署环境滚动升级。
- ✓ 企业 relay 支持账号、项目、机器 token、管理员、停用账号、关闭自助注册和任务队列。
- ✓ 桌面 / 手机工作台继续支持工作区、Agent 会话、git、编辑器、任务队列、待办、Agent 库和远程工作区。

## 快速部署

总耗时约 30 分钟,完整运维向手册见 **[`docs/deployment.md`](docs/deployment.md)**。

### 前置

| 哪一端 | 要什么 |
|---|---|
| VPS | Linux(amd64 或 arm64),有 sudo,80/443 端口开放 |
| 域名 | 给 relay 一个二级域名,如 `handoff.your-domain.com` |
| 反向代理 | VPS 上预装 caddy 或 nginx 之一(终结 TLS) |
| Mac / Linux 客户端 | Go 1.22+ 用于本地构建、git、`claude` CLI 已登录 |

### 1. VPS 起 relay

在你 Mac 上的 cc-collaboration 仓库根:

```bash
make deploy HOST=user@your-vps
# 自定义 ssh:
make deploy HOST=user@your-vps SSH_OPTS="-p 2222 -i ~/.ssh/id_ed25519"
```

幂等。第一次是全新部署,再跑就是滚动升级二进制 + 重启,配置和 DB 不动。
脚本会自动跨编译 `cc-relay` 到 VPS 架构、装 systemd unit、建 `cc-handoff` 系统用户、初始化 `/etc/cc-handoff/tokens.json` 与 `/var/lib/cc-handoff/relay.db`。

VPS 上挂反代,caddy 一行就好(`flush_interval -1` 是 SSE 必须的):

```caddyfile
handoff.your-domain.com {
    reverse_proxy 127.0.0.1:8080 {
        flush_interval -1
    }
}
```

### 2. 拿 token

VPS 上 `/etc/cc-handoff/tokens.json` 默认带一对示例 identity/token。
线上要给前后端各自分配一对:

```bash
sudo cc-handoff-rotate-token user@backend
sudo cc-handoff-rotate-token alex@frontend
```

输出的 token 各自保管,后面 `cc-handoff init` 要填。

### 3. 客户端装(前后端各一次)

**A. 一键装预编译版本(推荐 macOS / Linux)**

不需要本仓库代码,不需要 Go,直接拉最新 GitHub Release 二进制装到 PATH:

```bash
curl -fsSL https://raw.githubusercontent.com/gmslll/cc-collaboration/main/scripts/install-client.sh | bash
```

可调 env(都可选):`INSTALL_DIR=$HOME/.local/bin`(改装到哪)、`VERSION=v0.1.2`(锁版本,默认 latest)、`SKIP_RELAY=1`(linux 上不装 cc-relay,只装 cli + mcp)。脚本会校验 sha256,装好后 `cc-handoff version` 验一下。

Windows:从 [Releases 页](https://github.com/gmslll/cc-collaboration/releases/latest) 下 `cc-handoff_v*_windows_<arch>.zip`,解压后把 .exe 放进 PATH(或跑 `scripts/install.ps1`,见 §Windows 支持)。

**B. 从源码编译**

需要本仓库 + Go 1.22+:

```bash
make build && sudo install bin/cc-handoff bin/cc-handoff-mcp /usr/local/bin/
```

---

装好二进制后(A 或 B 都行),进你的工作仓库 init:

```bash
# 在你的工作仓库里 init —— 同时:
#   写两个 toml(user 级 / 仓库级)
#   --agent <name>     默认按 PATH 探测 (claude > codex > manual);可显式覆盖
#   --with-mcp         注册 MCP server(claude 跑 `claude mcp add`;
#                      codex 跑 `codex mcp add`)
#   --with-commands    安装 agent 工作流入口(Claude: .claude/commands/;
#                      Codex: $CODEX_HOME/skills/cc-handoff-*/)
#   --with-instructions 把 cc-handoff 用法段追加到 CLAUDE.md / AGENTS.md
cd /path/to/your-repo
cc-handoff init --with-mcp --with-commands --with-instructions
```

所有 `--with-*` 都可选。省略时 `cc-handoff init` 退化为只写两个 toml,
其余步骤(`bash scripts/install-mcp.sh`、复制 commands / skill 文件)自己跑 ——
适合 CI 或想完全控制每一步的场景。

### 4. 接收侧起 watch 守护

只有"等接对接"那一端要起。**macOS** 用 launchd:

```bash
cc-handoff watch print-unit --workdir=$(pwd) > ~/Library/LaunchAgents/com.cc-handoff.watch.plist
launchctl load ~/Library/LaunchAgents/com.cc-handoff.watch.plist
```

**Linux** 用 systemd user unit:

```bash
cc-handoff watch print-unit --platform=systemd --workdir=$(pwd) \
  > ~/.config/systemd/user/cc-handoff-watch.service
systemctl --user daemon-reload
systemctl --user enable --now cc-handoff-watch
```

`print-unit` 只打印模板,load / enable 由你显式做 —— 反对悄悄改用户的 launchd / systemd 配置。

### 5. 验证

后端 Claude Code 内:

```
> 我现在有哪些 MCP 工具?
```

应当看到上文「架构」段列出的 13 个工具(`submit_handoff` 等)。命令行验证:

```bash
claude mcp list
# cc-handoff: /usr/local/bin/cc-handoff-mcp  - ✓ Connected
```

---

VPS 之前先在本机试一遍?`bash scripts/dogfood.sh setup` 一键起本地隔离环境,
自带 test-backend / test-frontend 仓库。`scripts/dogfood.sh` 顶部有完整说明,
也支持 `cleanup` / `status` 子命令。

## 在 Claude Code 内使用

### 后端发送

按场景挑一种:

- **`/handoff`(diff 模式)** —— 刚写完一段改动想推过去时用。Claude 读分支 diff、写对接说明、调 `submit_handoff`。
- **`/handoff-module <module-path> [more...]`(模块 brief 模式)** —— 某模块早就合并、前端要新做集成时用。Claude 读模块下的 routes/handlers/dto/swagger,整理成自包含的 API 契约文档,调 `submit_handoff` 时带 `module_paths`,接收端会自动切到「模块对接」prompt 模板。一次可以传多个模块,空格分隔。

两种模式下 Claude 都会先**问一次产品需求 / 设计意图 (PRD)**(支持文件路径 / 粘贴 / 口头描述,作为业务背景渲染到接收端 prompt,**不**强制逐条响应),再**问一次跨端备注 / 约束**(错误码对照、字段大小写规则、分页默认值等,note 渲染为「必读 / 逐条响应」)。两步都没有就连回两次 `没有`。

### 前端接收

```
/pickup
```

Claude 看 `list_inbox`,有多条会让你挑一条,然后 `pickup_handoff` 拉取、materialize 到 `.cc-handoff/inbox/<id>/`,产出 `INTEGRATION.md` 草稿等你 review。

中途要问后端:`comment_handoff` MCP 工具,或命令行 `cc-handoff comment <id> "你的问题"`。后端那边 watch 会推 SSE,落到 `.cc-handoff/inbox/<id>/comments.md`。

### 前端反向发起需求 `/request`

前端发现后端设计不全(返回缺字段、某能力没暴露、响应结构不对)时,在 Claude Code 内一条 `/request`:

- Claude 读相关前端代码,描述清楚「缺什么、为什么需要、什么样算 OK」,调 `submit_request`(没有 git diff,summary 即需求正文)
- 后端那边 `list_inbox` 看到 `[REQUEST]` 标签,跑 `/pickup` 拉下来 —— 接收端 prompt 自动切到 request 模板,引导后端「读需求 → 设计响应方案到 `docs/requests/<id>.md` → 等人工 review」(direct 模式则直接改代码后停下等 review)
- 后端实现完跑 `/handoff` 时带 `responds_to=<原 request id>`,前端那边 prompt 顶端就会显示「↩️ 这次 handoff 是在回应你之前发起的需求 r_xxx」,闭环可追溯

发起时同样会先**问一次 PRD**(产品给前端的需求 / 设计意图,作为业务背景过给后端 pickup),再**问一次跨端约束**(「不要破坏现有调用方」「字段命名跟 X 一致」「兼容现存数据」之类)。整套流程是 `/handoff` 的对称反向,复用同一份 inbox / comment / status / retract 机制。

### 状态可见性 / 翻车处理

发送之后想知道对方是不是收到 / 看了 / 回了:

```bash
cc-handoff status <id>      # 查 relay:state / picked_at / 评论数 + 最近一条评论摘要
cc-handoff sent              # 列我作为 sender 发出去的近 N 条 + 各自状态
```

发错了想撤(对方还没 pickup 才能撤;已 pickup 的去 comment 协调):

```bash
cc-handoff retract <id> --reason "wrong branch"    # 标记 retracted,recipient watch 收 SSE 写 RETRACTED.md + 弹通知
```

接收侧关掉了终端 / 重启了机器,想找回某条 handoff 的会话:

```bash
cc-handoff inbox             # 列本地已物化的 handoff(含 RET / C 标记)
cc-handoff open <id>         # 重新调起当前 agent 的终端跑那条 prompt
```

MCP 工具同样齐全:`status_handoff` / `list_sent` / `retract_handoff` / `list_local_inbox`,在 agent 会话里直接调即可。

### 图形界面

不想一切走命令行,有两个入口:

```bash
cc-handoff ui --open            # 在默认浏览器里打开 relay 内嵌的 Web UI
cc-handoff desktop              # 同一个 UI,但用 Chrome/Edge 起一个 app 窗口,token 自动注入
cc-handoff desktop --width 1400 --height 900
cc-handoff desktop --chrome "/path/to/your/browser"   # 指定浏览器二进制
```

`desktop` 子命令是纯 Go 的 Lorca 封装,会按 Chrome → Edge → Brave → Chromium 顺序探测本机已装的浏览器。Windows 10/11 自带 Edge 直接可用;macOS 用户多数都有 Chrome。没装任何 Chromium 内核浏览器时会回退提示用 `cc-handoff ui --open` 走默认浏览器。

两个入口共用同一份 UI 资源,功能完全一致(inbox / sent / history / 评论 / ack / retract / 在线用户)。`desktop` 模式下 token 由本地 config 自动注入,免去手动输入。

收件详情页里还能直接处理 handoff,不用回命令行:

- **接收并物化** —— 一键 pickup + 物化。`desktop` 模式下直接调本地 pickup,落到当前仓(或自动发现的 defaultRepo)。
- **Prompt 面板** —— 预览接收侧的 prompt,配「**复制 Prompt**」和「**复制 CLI**」两个按钮,把 prompt 文本或对应的 `cc-handoff` 命令拷到终端即可。
- **转交** —— 弹出对话框选目标用户 + 填转交原因,把任务转给别人;**仅对 pending 的 bug 类 handoff 显示**。同类还有 bug 专属的 **reassign**(改派)按钮。

### 同人多仓接收

一个 identity 对应多个 receiver repo 的场景(比如同一个前端同事同时维护 `frontend-project1` 和 `frontend-project2`,后端的 handoff 落到哪边由 handoff 内容决定)。

配置:每个 receiver repo 各自一份 `.cc-handoff.toml`,都声明同一个 `identity.me`(比如 `you@frontend`)。Relay 端 token 只注册一份。

接收姿势:

```bash
# 在最常用的仓里起 watch,但跳过预物化(否则所有 handoff 都会落到这一个仓)
cc-handoff watch --no-materialize

# 收到通知 + 看摘要后,显式选 repo 物化
cc-handoff pickup h_xxx --repo ~/work/frontend-project1
cc-handoff pickup h_xxx --repo ~/work/frontend-project2
```

`--no-materialize` 让 watch 只发通知,不在 receiver 端自动落地文件;`pickup --repo` 让你不用 cd 就能把包物化到任意 repo。这两个 flag 组合等同于"通知归通知、路由由人决定"。

如果你只有一个 receiver repo,什么都不用配,默认行为就是对的。

## 命令行速查

装好后用 `cc-handoff <子命令>`;每个子命令都有 `--help`。

**handoff 协作**

| 命令 | 作用 |
|---|---|
| `init` | 在工作仓初始化(写 user / 仓库级 toml,可选装 MCP、工作流命令、说明段) |
| `submit` | (发送侧)打包 git diff + swagger 增量 + commit log,推到 relay |
| `list` / `inbox` | relay 上待接收 / 本地已物化的 handoff |
| `pickup <id>` | 拉取 + 物化 + ack(`--worktree` 在独立分支 worktree 上接,`--direct` 直接落当前仓) |
| `status` / `sent` / `history` / `open` / `retract` | 状态 / 我发过的 / 接收历史 / 重开 agent / 撤回 |
| `comment <id> …` / `check-drift` | 评论 / 上次 handoff 后 swagger 是否漂移 |
| `watch` | 接收侧常驻:SSE 入任务队列 + 通知 + 紧急自动开终端(`watch print-unit` 生成 launchd / systemd / Windows 任务单元) |
| `online` | 已注册身份 + 谁在 watching |

**本地会话总线 / 会话编排**(桌面 App 内的多 agent 协作)

| 命令 | 作用 |
|---|---|
| `msg send <target> <text>` | 同机 agent 会话点对点发消息(不走 relay,在 App 生成的终端里跑) |
| `msg read <target>` | 拉取对方会话屏幕的纯文本快照 |
| `msg list` / `msg whoami` | 列会话 / 我是谁 |
| `supervisor …` | 总管 agent 辅助:`overview` / `queue` / `read` / `send` / `decide` |

**工作区 / 项目 / worktree / 日志**

| 命令 | 作用 |
|---|---|
| `workspace (ws) list\|create\|add\|open` | 管理并一键启动项目目标 |
| `worktree (wt) add\|list\|open\|remove` | 分支 worktree(`remove --prune-merged` 清理已合并的) |
| `logs <project>` | 拉项目日志、抽取 + 评分最新错误(去重),可 `--open` 起 agent 定位 |

**其它**:`ui` / `desktop`(relay 管理界面 / Chromium 窗口)、`alert`(把服务器日志告警转发到队友 watch)、`link-linear` / `linear-sync`(Linear 集成)、`config`、`stop-hook` / `bus-hook`(agent 钩子入口)、`version`。

## 日常运维

```bash
# VPS 上(deploy 自动装到 /usr/local/sbin/)
sudo cc-handoff-rotate-token <identity>     # 轮换 token
sudo cc-handoff-backup                       # 热备份 SQLite,KEEP=N 保留份数
sudo cc-handoff-uninstall [--purge]          # 卸载

# 实时审计日志
sudo journalctl -u cc-handoff-relay -f
```

详细排错(watch 连不上 / token 过期 / SSE 不通 / 升级回滚)见
[`docs/deployment.md`](docs/deployment.md) 的「故障排查」章。

## Linear 集成(可选)

把 cc-handoff 的四类事件(submit / pickup / comment / retract)与 Linear issue 绑定,出入双向。**零 secret**:cc-handoff 二进制不直接调 Linear API,所有同步动作都委托给 Claude Code 里已经装好的 Linear MCP server(`mcp__linear__*` 工具)。

**配置**:在仓库的 `.cc-handoff.toml` 加一段:

```toml
[integrations.linear]
enabled = true
team_key = "ENG"                  # Linear team prefix,生成示例 issue id 用
default_labels = ["cc-handoff"]   # 创建 issue 时打的 label
mcp_prefix = "linear"             # Linear MCP 工具的前缀(若装的不是默认 mcp__linear__,改这里)
sync_on_submit = true
sync_on_pickup = true
sync_on_comment = true
sync_on_retract = true
```

缺省 `enabled = false`,关闭时所有命令输出与未集成时完全一致。

**出站流程**(发出 handoff 或操作 handoff 时):跑五个操作型 MCP 工具(`submit_handoff` / `submit_request` / `pickup_handoff` / `comment_handoff` / `retract_handoff`)任一个后,工具返回的 prompt 末尾追加「## 同步到 Linear」段,告诉 Claude:
1. 用 `mcp__linear__create_issue` / `update_issue` / `create_comment` 同步状态
2. 用 `mcp__cc-handoff__link_linear` 把返回的 issue identifier 写回本地 `<inbox>/sent/<id>/linear.json` 映射

整条链路一个 Bash 权限确认都不触发。

**入站流程**(从 Linear issue 起手):在 Claude Code 里跑 `/handoff-from-linear ENG-123` → skill 读 Linear issue 内容 → 转成 cc-handoff request → 把 `<!-- cc-handoff: h_xxx -->` 锚点写回 Linear issue 描述,后续 sync 靠这个锚点找回 issue。

**失败降级**:Linear MCP 不可用时,Claude 会跳过同步段、handoff 主流程不受影响。

## Windows 支持

Windows 是一等支持平台,所有功能(CLI / MCP / watch / 通知 / 紧急 handoff 自动开终端 / 守护进程)都可用。

**前置依赖**:Windows 10 1809+ 或 Windows 11;PowerShell 5.1+(预装);`claude` CLI 在 PATH。

**安装**:

```powershell
# 仓库根目录,先交叉编译(产出 amd64 + arm64 两个架构 cli/mcp 共 4 个 .exe)
make windows

# 一键装到 %LOCALAPPDATA%\Programs\cc-handoff,加 PATH,注册 watch 任务
.\scripts\install.ps1 -RegisterTask
```

**手动注册守护进程**(已装好 cc-handoff.exe 后):

```powershell
# PowerShell 5.1 的 `>` 默认写 UTF-16 LE BOM,会和模板里的 UTF-8 声明对不上,
# schtasks 会拒收。用 WriteAllText 强制 UTF-8 无 BOM。
$xml = cc-handoff watch print-unit
[System.IO.File]::WriteAllText("cc-handoff-watch.xml", ($xml -join "`n"), [System.Text.UTF8Encoding]::new($false))
schtasks /Create /XML cc-handoff-watch.xml /TN cc-handoff-watch
schtasks /Run /TN cc-handoff-watch
```

**关键路径与配置项**:

| 项目 | 位置 |
|---|---|
| 用户配置 | `%AppData%\cc-handoff\config.toml` |
| 仓库配置 | `<repo>\.cc-handoff.toml`(同 macOS / Linux) |
| `terminal_app` 取值 | `windows-terminal`(默认,wt.exe 不在 PATH 时回退到 powershell)、`powershell` |

**清理**:

```powershell
schtasks /Delete /TN cc-handoff-watch /F
Remove-Item -Recurse "$env:LOCALAPPDATA\Programs\cc-handoff"
```

## 多 agent 支持

| agent | CLI 调用 | MCP 注册 | 命令 | 项目级说明文件 |
|---|---|---|---|---|
| `claude`(默认) | `claude -p "$(cat prompt.md)"` | 自动 `claude mcp add --scope user --transport stdio` | `.claude/commands/{handoff,handoff-module,pickup,request}.md` | `CLAUDE.md`(追加段) |
| `codex` | `codex exec "$(cat prompt.md)"` | 自动 `codex mcp add cc-handoff -- <bin>` | `$CODEX_HOME/skills/cc-handoff-*/` workflow skills;这些 skills 调用 cc-handoff MCP tools | `AGENTS.md`(追加段) |
| `manual` | 不自动开终端 | init 打印通用 stdio 提示 | 无 | 无 |

**选哪个 agent**:`cc-handoff init` 默认按 PATH 探测(claude > codex > manual)。手动指定:`cc-handoff init --agent codex`。结果写到 `~/.config/cc-handoff/config.toml`(Linux/macOS)或 `%AppData%\cc-handoff\config.toml`(Windows)的 `agent` 字段,后续命令一直按这个走。

**`cc-handoff init` 子步骤**(各自独立可关):

- `--with-mcp` / `--no-mcp` —— 注册 MCP 服务(claude 自动跑 `claude mcp add`,codex 自动跑 `codex mcp add`)
- `--with-commands` / `--no-commands` —— 装 agent 工作流入口(Claude slash commands;Codex workflow skills)
- `--with-instructions` / `--no-instructions` —— 把 cc-handoff 用法段追加到 `CLAUDE.md` 或 `AGENTS.md`(已含 `## cc-handoff` 标题则跳过,幂等)

**Codex 用户**:`--with-mcp` 会直接写入 Codex MCP 配置。cc-handoff 仍然以 MCP tools 的形式执行;`--with-commands` 会把每个 `internal/setup/templates/commands/*.md` workflow 安装成一个 Codex skill,路径是 `$CODEX_HOME/skills/cc-handoff-*/`。重启 Codex 后可说「使用 cc-handoff-handoff 处理当前 API 改动」或「使用 cc-handoff-pickup」。

**inbox 目录路径**:新装默认 `.cc-handoff/inbox/`;已有 `.claude/handoff-inbox/` 的老仓库继续沿用,不需要迁移。`.cc-handoff.toml` 里 `[inbox] dir = "..."` 可以显式 override(绝对或相对路径)。

## 进一步阅读

| 文档 | 说什么 |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | 概念向 —— 组件、数据流、SQLite schema、auth、threat model、failure mode、扩展点 |
| [`docs/deployment.md`](docs/deployment.md) | 运维向 —— 端到端部署、TLS、监控、token 轮换、升级回滚、故障排查 |
| [`docs/workspaces.md`](docs/workspaces.md) | 工作区 / 工作树启动器 —— 一键启动、分支 worktree、handoff 隔离 |
| [`docs/logs.md`](docs/logs.md) | 日志排查 —— 配置日志来源、`cc-handoff logs` 拉取最新 error、push 告警自动排查 |
| [`scripts/dogfood.sh`](scripts/dogfood.sh) | 在本机起隔离环境,先把流程跑一遍再上 VPS(脚本顶部有完整说明) |
| [`docs/handoff-package.schema.json`](docs/handoff-package.schema.json) | handoff 包的 JSON schema |
| [`pkg/handoffschema/package.go`](pkg/handoffschema/package.go) | 同上的 Go 类型定义 |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本变更 |

## License

MIT — see [`LICENSE`](LICENSE)。
