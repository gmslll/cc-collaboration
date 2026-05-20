# cc-handoff

[![CI](https://github.com/gmslll/cc-collaboration/actions/workflows/ci.yml/badge.svg)](https://github.com/gmslll/cc-collaboration/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Go Reference](https://pkg.go.dev/badge/github.com/cc-collaboration.svg)](https://pkg.go.dev/github.com/cc-collaboration)

> [English](README.en.md) | **中文**

> 跨机器 AI 编码 agent 协作工具 —— 让"后端写完接口、前端去对接"这件事从「手抄群里贴 + 自己读 swagger」变成「`/handoff` 一条命令推过去,前端 `/pickup` 一条命令接住」。原生支持 Claude Code 与 OpenAI Codex CLI;其他 agent 走 manual 模式可用纯 CLI 流程。

## 它解决什么问题

前后端分仓远程协作时,API 对接的真实流程通常是:

1. 后端写完接口、合并 PR
2. 后端在群里贴一段说明:有几个新 endpoint、字段名、错误码、踩坑点
3. 前端开发者拷回去,自己再去翻 swagger / 读后端代码 / 在群里反复确认细节
4. 写出客户端代码,出问题时重复步骤 3

这个流程的痛点是**对接信息散在群里、PR 描述里、后端记忆里**,且每次都要前端重新读后端代码做心理建模。

cc-handoff 把这一段变成结构化的 handoff:

- **后端**在 Claude Code 内一条 `/handoff`,Claude 读 git diff + swagger 增量 + commit log,自动写出对接说明,打包推到自有 VPS
- **前端**机器上常驻进程默认入收件箱、系统通知、紧急任务自动开新终端
- **前端**一条 `/pickup`,Claude 读后端推过来的包**+ 本地真实代码**,产出 `INTEGRATION.md` 草稿
- **人工 review** `INTEGRATION.md` 后再让 Claude 落代码,接收端 Claude 默认**写完停下等 review,不直接改代码**

跟纯人力贴说明 / 让一个共享 Claude session 来回切换的方案相比,优点:

| | 群里贴 + 自己读 | 共享 Claude session | cc-handoff |
|---|---|---|---|
| 对接说明结构化 | ✗ | △(看本次 prompt) | ✓ (handoff package + schema) |
| 接收端读真实代码 | ✗(靠后端记忆) | △(共享 session 不 ground 在前端真代码上) | ✓(接收端 Claude 在前端机器上读) |
| 跨机器、跨时区 | △(异步靠群) | ✗(要同时在线) | ✓(SSE + 持久化 inbox) |
| 上下文不被对方污染 | ✓ | ✗(共用一个会话) | ✓(各自的 Claude session) |
| 历史可回查 | ✗ | ✗ | ✓(SQLite + comments + attachments) |
| 紧急自动唤起对方 | ✗ | ✗ | ✓(可配,默认关) |

设计原则:

- **手动可控,反对自动魔法**。MVP 没有 Stop hook 自动触发,没有自动重试,没有"悄悄帮你改文件"。每个动作都打印将做什么、用户回车确认。
- **接收端 Claude 写,人工 review**。发送端不知道前端真实目录结构,只能给启发式建议;真正的对接决策由前端那边的 Claude(看到真代码)做,且默认停下等人。
- **边界清晰胜于代码复用**。三个二进制(CLI / MCP / relay)各管各的,中间走 HTTP+SSE,不共享数据库。

## 架构

三个 Go 二进制,跑在三台机器上:

```
后端开发者 Mac                      你的 VPS                    前端开发者 Mac
────────────────                  ─────────                  ─────────────────
Claude Code (后端)                                            Claude Code (前端)
  ↓ /handoff                                                    ↑ /pickup
cc-handoff-mcp ──HTTPS──►       caddy:443                  ──► cc-handoff-mcp
                                   ↓                              ↑
                                cc-relay:8080 ◄──SSE──── cc-handoff watch (launchd/systemd)
                                   ↓
                                /var/lib/cc-handoff/relay.db
                                   + comments + attachments
```

- `cc-relay`:VPS 上 systemd 服务,听 loopback,反代终结 TLS。HTTP REST + SSE,SQLite 持久化。
- `cc-handoff` (CLI):两端各装一份。子命令:`init` / `submit` / `list` / `pickup` / `watch` / `comment`。
- `cc-handoff-mcp`:Claude Code 通过 stdio 拉起的 MCP server,把上面的子命令全部暴露成 MCP 工具,共 15 个:`submit_handoff` / `submit_request` / `submit_bug` / `reassign_bug` / `list_inbox` / `pickup_handoff` / `comment_handoff` / `status_handoff` / `list_sent` / `list_history` / `retract_handoff` / `list_local_inbox` / `list_online_users` / `check_drift` / `link_linear`(最后一个用于可选的 Linear 集成)。
- **三角协作(可选)**:除了 `backend ↔ frontend` 的标准 2 方流(`/handoff` 交付 + `/request` 反向需求),还支持引入测试端做 bug 上报。tester 在 `.cc-handoff.toml` 配 `identity.partners = ["backend", "frontend"]`,用 `/submit-bug` 同时发给两端;接收端 prompt 内置归属判断决策树:是自己的就修,不是自己的用 `reassign_bug` 转给对端(同一 bug_group 内的评论自动同步给三方)。
- `cc-handoff watch`:接收侧常驻进程,SSE 长连接拉服务端事件,落盘到 `.cc-handoff/inbox/<id>/`(老仓库已有 `.claude/handoff-inbox/` 时继续沿用),必要时弹通知或按当前 agent 开新终端(`claude -p` / `codex exec` / …)。

完整数据流、SQLite schema、auth、failure mode 见 [`docs/architecture.md`](docs/architecture.md)。

## 状态

四个里程碑全部完成,v0.1.0 已发布:

- ✓ **M1** 手动 submit / list / pickup
- ✓ **M2** SSE + watch 守护 + osascript 通知 + partner_mapping 规则引擎 + Swagger 增量
- ✓ **M3** MCP server(Claude `/handoff` `/pickup`;Codex 稳定路径是直接调 MCP tools,可选装 plugin command files)
- ✓ **M4** 自动唤起新终端 + back-channel comments + 附件通道 + 结构化审计日志

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
#   --with-commands    安装 agent 命令(Claude: .claude/commands/;
#                      Codex: 可选 .codex/plugins/cc-handoff/ command files)
#   --with-instructions 把 cc-handoff 用法段追加到 CLAUDE.md / AGENTS.md
cd /path/to/your-repo
cc-handoff init --with-mcp --with-commands --with-instructions
```

所有 `--with-*` 都可选。省略时 `cc-handoff init` 退化为只写两个 toml,
其余步骤(`bash scripts/install-mcp.sh`、复制 commands / plugin 文件)自己跑 ——
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
| `codex` | `codex exec "$(cat prompt.md)"` | 自动 `codex mcp add cc-handoff -- <bin>` | 稳定路径:让 Codex 直接调 MCP tools;可选 `.codex/plugins/cc-handoff/commands/*.md` 仅在客户端支持并加载 repo plugin commands 时出现在 `/` | `AGENTS.md`(追加段) |
| `manual` | 不自动开终端 | init 打印通用 stdio 提示 | 无 | 无 |

**选哪个 agent**:`cc-handoff init` 默认按 PATH 探测(claude > codex > manual)。手动指定:`cc-handoff init --agent codex`。结果写到 `~/.config/cc-handoff/config.toml`(Linux/macOS)或 `%AppData%\cc-handoff\config.toml`(Windows)的 `agent` 字段,后续命令一直按这个走。

**`cc-handoff init` 子步骤**(各自独立可关):

- `--with-mcp` / `--no-mcp` —— 注册 MCP 服务(claude 自动跑 `claude mcp add`,codex 自动跑 `codex mcp add`)
- `--with-commands` / `--no-commands` —— 装 agent 命令(Claude slash commands;Codex 可选 plugin command files)
- `--with-instructions` / `--no-instructions` —— 把 cc-handoff 用法段追加到 `CLAUDE.md` 或 `AGENTS.md`(已含 `## cc-handoff` 标题则跳过,幂等)

**Codex 用户**:`--with-mcp` 会直接写入 Codex MCP 配置。稳定用法是在 Codex 里自然语言要求调用 `submit_handoff` / `pickup_handoff` 等 MCP 工具;`--with-commands` 只安装 repo-local plugin command files,是否出现在 `/` 取决于当前 Codex 客户端是否支持并加载这类 commands。

**inbox 目录路径**:新装默认 `.cc-handoff/inbox/`;已有 `.claude/handoff-inbox/` 的老仓库继续沿用,不需要迁移。`.cc-handoff.toml` 里 `[inbox] dir = "..."` 可以显式 override(绝对或相对路径)。

## 进一步阅读

| 文档 | 说什么 |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | 概念向 —— 组件、数据流、SQLite schema、auth、threat model、failure mode、扩展点 |
| [`docs/deployment.md`](docs/deployment.md) | 运维向 —— 端到端部署、TLS、监控、token 轮换、升级回滚、故障排查 |
| [`scripts/dogfood.sh`](scripts/dogfood.sh) | 在本机起隔离环境,先把流程跑一遍再上 VPS(脚本顶部有完整说明) |
| [`docs/handoff-package.schema.json`](docs/handoff-package.schema.json) | handoff 包的 JSON schema |
| [`pkg/handoffschema/package.go`](pkg/handoffschema/package.go) | 同上的 Go 类型定义 |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本变更 |

## License

MIT — see [`LICENSE`](LICENSE)。
