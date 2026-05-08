# cc-handoff 部署文档

完整的端到端部署指南：从 VPS 起一个 relay，到两台 Mac 接入 Claude Code 内的 `/handoff` `/pickup`，到日常运维。

按章节顺序做下来，约 30 分钟可以从零跑通。

---

## 总览

三个进程，分别跑在三台机器上：

```
后端开发者 Mac                   你的 VPS                  前端开发者 Mac
────────────────                ─────────                ─────────────────
Claude Code (后端)                                        Claude Code (前端)
  ↓ /handoff                                                ↑ /pickup
cc-handoff-mcp ────HTTPS────►   caddy:443                 ────► cc-handoff-mcp
                                  ↓                                ↑
                                cc-relay:8080 ◄────SSE────  cc-handoff watch (launchd)
                                  ↓
                                /var/lib/cc-handoff/relay.db
                                  + comments + attachments
```

- **VPS** 上跑 `cc-relay`（systemd 守护，监听 127.0.0.1:8080），caddy/nginx 终结 TLS
- **Mac** 上每个仓库装一份 `cc-handoff` CLI + 一份 `cc-handoff-mcp`（被 Claude Code / OpenAI Codex CLI / 其他 agent 通过 stdio 拉起的 MCP server）
- **接收侧 Mac** 额外起一个 `cc-handoff watch` 守护进程（launchd），SSE 长连接拉服务端事件、落盘到 `.cc-handoff/inbox/`（老仓库已有 `.claude/handoff-inbox/` 时继续沿用）、必要时弹通知或开新终端

---

## 前置条件

| 哪一端 | 要什么 |
|---|---|
| VPS | 一台 Linux（amd64 或 arm64），有 sudo；80/443 端口开放 |
| 域名 | 给 relay 一个二级域名，比如 `handoff.your-domain.com` |
| 反向代理 | VPS 上预装 caddy 或 nginx 之一 |
| Mac (两端) | macOS、Go 1.22+（用于本地构建）、git、`claude` CLI 已装并能登录 |
| 网络 | Mac → VPS 能走 HTTPS |

---

## 第一步：VPS 部署 relay

### 1.1 一键部署

在你 Mac 上 cc-collaboration 仓库根目录里：

```bash
make deploy HOST=user@your-vps
# 自定义 ssh：
make deploy HOST=user@your-vps SSH_OPTS="-p 2222 -i ~/.ssh/id_ed25519"
```

`scripts/deploy.sh` 自动做的事：

1. ssh 探测 VPS 架构（amd64 / arm64）
2. 用对应 GOARCH 跨编译静态 `cc-relay`（CGO_ENABLED=0）
3. scp 二进制 + `install.sh` + `uninstall.sh` + `rotate-token.sh` + `backup.sh` + systemd unit 到 VPS:`/tmp/cc-handoff-deploy/`
4. 远端执行 `install.sh`：
   - 创建 `cc-handoff` 系统用户（无 home、无 shell）
   - `cc-relay` 装到 `/usr/local/bin/`
   - `/var/lib/cc-handoff/`（SQLite 数据目录，权限 cc-handoff:cc-handoff 0755）
   - `/etc/cc-handoff/tokens.json`（初始示例 token，权限 root:cc-handoff 0640）
   - systemd unit 装到 `/etc/systemd/system/cc-handoff-relay.service`
   - `systemctl enable --now cc-handoff-relay`
5. 把 `uninstall.sh` / `rotate-token.sh` / `backup.sh` 安装到 `/usr/local/sbin/cc-handoff-{uninstall,rotate-token,backup}` 方便后续运维
6. `systemctl restart cc-handoff-relay` 并验证 active

**应该看到**：

```
▶ deployed
● cc-handoff-relay.service - cc-handoff relay
     Active: active (running) ...

binary  : /usr/local/bin/cc-relay
tokens  : /etc/cc-handoff/tokens.json
data    : /var/lib/cc-handoff/relay.db

ops:
  sudo cc-handoff-rotate-token <identity>
  sudo cc-handoff-backup
  sudo cc-handoff-uninstall [--purge]
```

幂等：第一次跑是全新部署，之后再跑就是滚动升级二进制+重启，配置和 DB 不动。

### 1.2 反向代理 + TLS

`cc-relay` 自身不做 TLS — 让 caddy/nginx 终结。

**Caddy（推荐，一行 TLS）**：

```caddyfile
# /etc/caddy/Caddyfile
handoff.your-domain.com {
    reverse_proxy 127.0.0.1:8080 {
        flush_interval -1     # ★ SSE 必须，关响应缓冲
    }
}
```

```bash
sudo systemctl reload caddy
```

**Nginx**：

```nginx
server {
    listen 443 ssl http2;
    server_name handoff.your-domain.com;

    ssl_certificate     /etc/letsencrypt/live/handoff.your-domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/handoff.your-domain.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;          # ★ SSE 必须
        proxy_read_timeout 1h;        # ★ SSE 长连接
    }
}
```

冒烟测试：

```bash
curl -i https://handoff.your-domain.com/healthz
# 应看到 HTTP/2 200 + body {"ok":true}
```

> SSE 需要中间层不缓冲。caddy `flush_interval -1` 和 nginx `proxy_buffering off` 这两条**必须设**，否则 watch 收事件会延迟几十秒甚至卡死。

### 1.2.alt 不要反代,直接 `http://<ip>:8080`(仅在可信网络用)

适用场景:VPN / Tailscale / WireGuard / 公司内网 / 家庭实验 —— 链路本身已经被你信任了。不挂 caddy/nginx,不要域名,直接把 8080 端口暴露给客户端。

> ⚠️ **没有 TLS。** Bearer token 和 handoff 全文(可能含 git diff、commit message、API 文档)都在 HTTP 上明文跑。**任何能截获你这条链路的中间人都能读 + 重放。** 千万别在公网裸用 —— 真的要公网就回去用 §1.2 装反代 + 域名。

三处改动:

**1. relay 监听地址放开**

`scripts/systemd/cc-handoff-relay.service` 默认 `-addr 127.0.0.1:8080`(只 loopback,留给反代用)。改成 `0.0.0.0:8080`(所有网卡)或具体 IP(`10.0.0.5:8080`、Tailscale IP 等):

```bash
sudo sed -i 's|-addr 127.0.0.1:8080|-addr 0.0.0.0:8080|' /etc/systemd/system/cc-handoff-relay.service
sudo systemctl daemon-reload
sudo systemctl restart cc-handoff-relay
```

要持久化(下次 `make deploy` 不被覆盖):改仓库里 `scripts/systemd/cc-handoff-relay.service`,重新 deploy。

**2. 防火墙开端口**

```bash
# ufw —— 限到搭档的固定 IP(强烈推荐)
sudo ufw allow from <搭档公网 IP> to any port 8080 proto tcp comment 'cc-handoff'
# 或全开(只在 VPN-only 场景)
sudo ufw allow 8080/tcp

# firewalld
sudo firewall-cmd --add-port=8080/tcp --permanent && sudo firewall-cmd --reload
```

**3. 客户端 `init` 时填 `http://<ip>:8080`**

```
Relay URL: http://203.0.113.42:8080      # VPS 公网 IP
# 或:
Relay URL: http://100.64.1.7:8080        # Tailscale 100.x.x.x IP
```

等价于在 `~/.config/cc-handoff/config.toml` 里直接写:

```toml
relay_url = "http://203.0.113.42:8080"   # 注意是 http:// 不是 https://,且要带端口
token     = "<步骤 1.3 拿到的对应 token>"
identity  = "you@backend"
```

**冒烟测试:**

```bash
curl -i http://203.0.113.42:8080/healthz
# HTTP/1.1 200 OK + {"ok":true}
```

**想保留这种部署但加点保护?**

不上反代但又想要传输层加密:

- **Tailscale Funnel / Serve** —— `tailscale serve --https=443 --bg http://localhost:8080`,Tailscale 自动给你套 HTTPS,无需自己装反代;只对 tailnet / Funnel 客户端可见
- **WireGuard / OpenVPN** —— 链路加密,relay 绑到 VPN 网卡 IP(`-addr 10.8.0.1:8080`)

这俩比"裸 0.0.0.0:8080"安全得多,代价是搭一次 VPN —— 但既然链路已受信,应用层用 HTTP 就够了。

### 1.3 生成真实 token

`install.sh` 写的是占位 token。VPS 上替换：

```bash
ssh your-vps
TOK_BACK=$(openssl rand -hex 32)
TOK_FRONT=$(openssl rand -hex 32)

sudo tee /etc/cc-handoff/tokens.json >/dev/null <<JSON
[
  {"token": "$TOK_BACK",  "identity": "user@backend"},
  {"token": "$TOK_FRONT", "identity": "alex@frontend"}
]
JSON

sudo chown root:cc-handoff /etc/cc-handoff/tokens.json
sudo chmod 0640 /etc/cc-handoff/tokens.json

# 把这两个 token 各自记下来，下面客户端配置要用
echo "BACKEND : $TOK_BACK"
echo "FRONTEND: $TOK_FRONT"

sudo systemctl restart cc-handoff-relay
sudo journalctl -u cc-handoff-relay -n 20
```

> identity 字符串想叫什么都行（`user@backend`、`alex@frontend`、`team-a`、`team-b`），只要客户端 `~/.config/cc-handoff/config.toml` 里的 `identity` 与 `tokens.json` 一致即可。

### 1.4 验证

```bash
# 1. healthz 走得通（且经 TLS）
curl https://handoff.your-domain.com/healthz

# 2. 用真 token 验证 auth + 路由
curl -H "Authorization: Bearer $TOK_BACK" \
  "https://handoff.your-domain.com/v1/handoffs?recipient=user@backend"
# 期望: {"items":null}

# 3. 故意用错 token —— 应当 401
curl -i -H "Authorization: Bearer wrong" \
  "https://handoff.your-domain.com/v1/handoffs?recipient=user@backend"
# 期望: HTTP 401 invalid token

# 4. SSE 真实推送（建议另开一终端，按 Ctrl-C 退）
curl -N -H "Authorization: Bearer $TOK_BACK" \
  "https://handoff.your-domain.com/v1/events?recipient=user@backend"
# 期望: 立刻看到 ": connected"，每 20s 一行 ": ping"
```

如果第 4 步要等很久才出 `: connected`，反向代理的 buffering 没关 — 回 1.2 检查。

---

## 第二步：客户端安装（前后端各一次）

后端、前端两台 Mac 各自做一遍这一节。

### 2.1 构建二进制

```bash
cd /path/to/cc-collaboration
make build
# 出三个：bin/cc-handoff, bin/cc-relay, bin/cc-handoff-mcp

sudo install bin/cc-handoff     /usr/local/bin/
sudo install bin/cc-handoff-mcp /usr/local/bin/

# 验证
cc-handoff --version
# cc-handoff dev
```

> `bin/cc-relay` 是给 VPS 用的，本机不装。

### 2.2 init 仓库

最短路径(2.3 / 2.4 / 2.5 一并做掉):

```bash
cd /path/to/your-repo               # backend 用 test-backend，frontend 用 test-frontend
# agent 默认按 PATH 探测 (claude > codex > manual);也可显式 --agent <name> 覆盖。
cc-handoff init --with-mcp --with-commands --with-instructions

# 交互式输入：
#   Relay URL  : https://handoff.your-domain.com
#   Bearer     : <步骤 1.3 拿到的对应 token>
#   Identity   : user@backend  (或 alex@frontend)
#   Partner    : alex@frontend (或 user@backend)
#   Repo name  : test-backend (回车默认 = 仓库目录名)
#   Register cc-handoff MCP server with <agent>? [Y/n]: <回车>
#   Install <agent> slash commands? [Y/n]: <回车>            # codex / manual 不会问
#   Append cc-handoff usage snippet to CLAUDE.md / AGENTS.md? [Y/n]: <回车>
```

每个 `--with-*` 对应一个 init 子步骤,按当前 agent 分发:

| 子步骤 | claude | codex | manual |
|---|---|---|---|
| `--with-mcp` (2.3) | 自动调 `claude mcp add` | **打印 TOML 片段**让你贴到 `~/.codex/config.toml` | 打印通用 stdio 提示 |
| `--with-commands` (2.4) | 拷 `.claude/commands/*.md` 并打版本戳 | 跳过(Codex 没有 slash 机制) | 跳过 |
| `--with-instructions` (2.5) | 把 cc-handoff 用法段追加到 `CLAUDE.md` | 追加到 `AGENTS.md` | 跳过 |

任何 `--with-*` 都可以省(退化成只写 toml + 走交互问答)或换成 `--no-*` 显式跳过;脚本化场景配 `--non-interactive` 用。

写出两个文件：

- `~/.config/cc-handoff/config.toml`：本机所有仓库共享的 user 级配置（relay URL + token + identity）
- `<repo-root>/.cc-handoff.toml`：仓库级配置（partner、swagger 路径、partner_mapping 规则、triggers）

打开 `<repo-root>/.cc-handoff.toml` 按需补 partner_mapping 规则。test 风格的示例可以参考 `configs/cc-handoff.test-backend.toml`：

```toml
[paths]
swagger = "docs/swagger.yaml"

[partner_mapping]
[[partner_mapping.rule]]
when_path_matches = "^internal/module/(?P<group>[^/]+)/(?P<domain>[^/]+)/handler/"
suggest_edit      = ["lib/api/{domain}.ts", "lib/api/{domain}s.ts"]

[[partner_mapping.rule]]
when_path_matches = "^internal/module/(?P<domain>[^/]+)/handler/"
suggest_edit      = ["lib/api/{domain}.ts", "lib/api/{domain}s.ts"]
```

### 2.3 注册 MCP server（若 2.2 没用 `--with-mcp`）

把 `cc-handoff-mcp` 注册给当前 agent，让它看得到 `submit_handoff` / `list_inbox` / `pickup_handoff` / `comment_handoff` 四个工具。注册方式按 agent 分:

**Claude Code** —— 命令行直接注册:

```bash
claude mcp remove cc-handoff --scope user                                 # 幂等，已存在先 remove
claude mcp add --scope user --transport stdio cc-handoff -- /usr/local/bin/cc-handoff-mcp
```

或运行打包好的脚本（**仅 Claude 用户的离线 fallback** —— 主流程已被 `cc-handoff init --with-mcp` 取代）:

```bash
bash /path/to/cc-collaboration/scripts/install-mcp.sh           # user scope (默认)
bash /path/to/cc-collaboration/scripts/install-mcp.sh project   # 写到当前目录的 .mcp.json
```

**OpenAI Codex CLI** —— Codex 不开放 CLI 注册接口，需手动编辑 `~/.codex/config.toml` 加一段:

```toml
[mcp_servers.cc-handoff]
command = "/usr/local/bin/cc-handoff-mcp"
args = []
```

然后**重启 codex** 让它重新加载配置。`cc-handoff init --with-mcp` 会把这段 TOML 直接打印到 stdout，复制粘贴即可（避免自动改 `config.toml` 破坏其他段落的注释和格式）。

**manual** —— 按你的 agent 自身文档把 `/usr/local/bin/cc-handoff-mcp` 注册成 stdio MCP server。`cc-handoff init --with-mcp` 会打印通用提示行（含绝对路径）作参考。

### 2.4 安装 slash commands(若 2.2 没用 `--with-commands`)

> Codex / manual 用户跳过本节 —— Codex 没有 slash 命令机制,直接在会话里调 MCP 工具名(`submit_handoff` / `submit_request` / `list_inbox` / `pickup_handoff` / `comment_handoff`)即可;manual 同理。

把 `/handoff`、`/handoff-module`、`/pickup`、`/request` 拷到目标仓库:

```bash
cd /path/to/your-repo
mkdir -p .claude/commands
cp /path/to/cc-collaboration/.claude/commands/{handoff,handoff-module,pickup,request}.md .claude/commands/
```

`cc-handoff init --with-commands` 把这一步内嵌进二进制了 — 拷出来的文件
末尾会带 `<!-- cc-handoff-version: vX.Y.Z -->`,二跑 init 时若版本旧于二进制
会触发 `[o]verwrite / [s]kip / [b]ackup` 提示。

> 实际用法按角色分:后端仓库主要用 `/handoff`(diff 模式)和 `/handoff-module`(模块 brief — 推送已有模块的完整 API 契约文档);前端仓库主要用 `/pickup`(领取后端推过来的对接)和 `/request`(反向给后端发起需求 —— 缺字段、缺能力、响应结构问题等)。**`/pickup` 双方都用** —— 接收端不论是 delivery 还是 request,流程是对称的。四份都拷无妨,Claude 不会去调没意义的那条。

### 2.5 验证客户端

**重启 agent session**(让它重新发现 MCP 工具)。然后随便开一个会话:

```
> 我现在有哪些 MCP 工具？
```

应当列出 `submit_handoff` / `list_inbox` / `pickup_handoff` / `comment_handoff`。也可以走 agent 自带的命令行验:

```bash
# Claude
claude mcp list
# cc-handoff: /usr/local/bin/cc-handoff-mcp

# Codex —— 没有等价的 list 命令,直接看配置
grep -A2 '\[mcp_servers.cc-handoff\]' ~/.codex/config.toml
```

---

## 第三步：接收侧 watch 守护进程（仅前端 Mac）

后端不需要这一节 — 只有「等接对接」那一侧才需要常驻进程拉 SSE。

### 3.1 launchd 配置

二进制自带 plist 模板,渲染好直接喂给 LaunchAgents:

```bash
WORKDIR=/path/to/test-frontend

cc-handoff watch print-unit --workdir="$WORKDIR" \
  > ~/Library/LaunchAgents/com.cc-handoff.watch.plist

launchctl load ~/Library/LaunchAgents/com.cc-handoff.watch.plist

# 验证在跑
launchctl list | grep cc-handoff
# - 0 com.cc-handoff.watch
```

Linux 接收侧改成 systemd user unit:

```bash
cc-handoff watch print-unit --platform=systemd --workdir="$WORKDIR" \
  > ~/.config/systemd/user/cc-handoff-watch.service
systemctl --user daemon-reload
systemctl --user enable --now cc-handoff-watch
```

`print-unit` 只打印,不动 launchd / systemd — 所有 load / enable 由你显式做。

`KeepAlive` 已配，断了会自动重起。

日志：

```bash
tail -f /tmp/cc-handoff.watch.out.log
tail -f /tmp/cc-handoff.watch.err.log
```

第一行应当是 `watching for handoffs to <你的 identity> on https://handoff.your-domain.com …`。

### 3.2 macOS 权限（仅当 auto_launch=true 用）

如果你要用 urgent 自动开终端那条路径，第一次 watch 触发 `osascript` 控制 Terminal/iTerm2 时，macOS 会弹"cc-handoff 想要控制 Terminal"的权限对话框 — 点允许。

（默认 `auto_launch=false`，不会触发这个 — 只有你在 `.cc-handoff.toml` 里显式打开才需要。）

### 3.3 不想用 launchd

也行，开个常驻终端跑：

```bash
cc-handoff watch
```

按 Ctrl-C 退。这种模式下机器睡了/重启就停，需要你手动起。launchd 模式机器一开机就在了。

---

## 第四步：冒烟联调

最后一步：实际走一遍 `/handoff` → `/pickup`，确认全链路通。

### 4.1 后端 Claude 投递

后端 Mac，在 `test-backend` 里随便起一个真实改动（或用现成的 feature 分支）：

```bash
cd test-backend
git checkout -b smoke-test
echo "package handler" > internal/module/foo/handler/dummy.go
git add . && git commit -m "smoke"
```

打开 Claude Code（在 test-backend 目录里），输入 `/handoff`。Claude 会：

1. 读最近 diff 与会话
2. 写一段对接 markdown
3. 调 `submit_handoff` 工具
4. 报告回包：handoff id、recipient、targeting_hints / api_delta / attachments 数

### 4.2 前端 watch 接收

接收侧 Mac，几秒内：

```bash
tail -1 /tmp/cc-handoff.watch.out.log
# ⇣ h_20260429_XXXXXXXX from user@backend → /path/to/test-frontend/.cc-handoff/inbox/h_...
# (老仓库已有 .claude/handoff-inbox/ 时落到那里)
```

macOS 右上角同时会弹一条 cc-handoff 通知。

### 4.3 前端 agent 领取

**Claude** —— 打开前端 Claude Code(在 test-frontend 目录里),输入 `/pickup`。Claude 会:

1. 调 `list_inbox`,看到刚才那条
2. 调 `pickup_handoff(id)`,拿到 prompt(含建议编辑哪个 `lib/api/<domain>.ts`)
3. 立即开始读现有相邻文件、按本仓库风格写代码

**Codex** —— 没有 slash 命令,在 codex 会话里直接说"调 cc-handoff 的 list_inbox 看下收件箱、然后 pickup_handoff 拿那个 id";Codex 自己会按 MCP schema 调对应工具,流程一致。

观察:

```bash
ls /path/to/test-frontend/.cc-handoff/inbox/<id>/
# package.json  summary.md  prompt.md  full.diff  api-delta.md
# (老仓库走 .claude/handoff-inbox/<id>/ 同样这些文件)
```

如果到这一步都顺，整套部署成功。`git status` 在前端仓库会看到 Claude 编辑的具体文件，review 然后 commit 即可。

---

## 日常运维

### 轮换 token

```bash
ssh your-vps
sudo cc-handoff-rotate-token alex@frontend
# 或自带 token：
sudo cc-handoff-rotate-token user@backend --token "$(openssl rand -hex 32)"
```

输出会打印新 token。把这条新 token 同步到对应客户端的 `~/.config/cc-handoff/config.toml`：

```toml
token = "<new>"
```

watch 守护进程会在下一次 SSE 重连时自动用新 token（最长 30s）。如果想立即生效，`launchctl kickstart -k gui/$(id -u)/com.cc-handoff.watch`。

### 备份 SQLite

VPS 上一次性：

```bash
sudo cc-handoff-backup           # 默认保留最近 7 份
sudo KEEP=30 cc-handoff-backup   # 留 30 份
```

输出位置：`/var/lib/cc-handoff/backups/relay-YYYYMMDDTHHMMSSZ.db.gz`。

挂 cron 每天凌晨 4 点：

```bash
sudo bash -c 'cat > /etc/cron.d/cc-handoff-backup <<EOF
0 4 * * * root /usr/local/sbin/cc-handoff-backup >> /var/log/cc-handoff-backup.log 2>&1
EOF'
```

恢复：

```bash
sudo systemctl stop cc-handoff-relay
sudo gunzip -c /var/lib/cc-handoff/backups/relay-XXXX.db.gz > /var/lib/cc-handoff/relay.db
sudo chown cc-handoff:cc-handoff /var/lib/cc-handoff/relay.db
sudo systemctl start cc-handoff-relay
```

> `sqlite3 .backup` 用的是热快照，备份时 relay 不必停；只有恢复时要停。

### 升级 relay

Mac 上重跑：

```bash
make deploy HOST=user@your-vps
```

幂等的：只是替换 `/usr/local/bin/cc-relay` 并 `systemctl restart`。配置、DB、token 全保留。

### 升级客户端 CLI / MCP

每台 Mac 重跑：

```bash
cd /path/to/cc-collaboration
git pull
make build
sudo install bin/cc-handoff     /usr/local/bin/
sudo install bin/cc-handoff-mcp /usr/local/bin/

# watch 守护重启用最新二进制
launchctl kickstart -k gui/$(id -u)/com.cc-handoff.watch
```

### 看日志

VPS 上结构化 JSON 审计日志（每一行一条 HTTP 请求）：

```bash
sudo journalctl -u cc-handoff-relay -f                # 实时跟踪
sudo journalctl -u cc-handoff-relay --since "1h ago" | jq .   # 过去 1h，jq 美化
```

每行字段：`{time, level, msg:"relay.request", method, path, status, ms, identity?, handoff_id?}`。

> handoff_id 仅在路径形如 `/v1/handoffs/{id}/...` 时填；普通 `POST /v1/handoffs` 没有 id 段，那行只看 method+path+status+identity。

接收侧 Mac watch 日志：

```bash
tail -f /tmp/cc-handoff.watch.out.log     # 收事件 / 落盘
tail -f /tmp/cc-handoff.watch.err.log     # 警告 / 错误
```

### 卸载

VPS 上：

```bash
sudo cc-handoff-uninstall              # 默认保留 DB 与 tokens.json
sudo cc-handoff-uninstall --purge      # 一并清掉 /var/lib/cc-handoff、/etc/cc-handoff、cc-handoff 用户
```

接收侧 Mac：

```bash
launchctl unload ~/Library/LaunchAgents/com.cc-handoff.watch.plist
rm ~/Library/LaunchAgents/com.cc-handoff.watch.plist
```

每台 Mac：

```bash
sudo rm /usr/local/bin/cc-handoff /usr/local/bin/cc-handoff-mcp

# Claude 用户
claude mcp remove cc-handoff

# Codex 用户 —— 编辑 ~/.codex/config.toml,删掉 [mcp_servers.cc-handoff] 那段

rm -rf ~/.config/cc-handoff
```

仓库里的 `.cc-handoff.toml` 与 `.cc-handoff/inbox/`（或 legacy `.claude/handoff-inbox/`）、`CLAUDE.md` / `AGENTS.md` 里的 `## cc-handoff` 段自己看着删。

---

## 故障排查

| 现象 | 检查 |
|---|---|
| `cc-handoff submit` 返回 401 | token 不对 / `tokens.json` 里 identity 拼错 / 客户端 `~/.config/cc-handoff/config.toml` 与 VPS `tokens.json` 不一致 |
| `cc-handoff submit` 报 `no recipient` | `.cc-handoff.toml` 漏了 `[identity] partner = ...` |
| `cc-handoff submit` 报 `swagger delta: parse...` | swagger 文件解析失败，把出错文件片段贴出来 |
| `cc-handoff submit` 报 `base ref ... unreachable` | 默认 base 是 `origin/main`，本地没 fetch / 仓库用的 master/develop。改 `.cc-handoff.toml` 的 `[paths] base = "..."` |
| 前端 watch 没收到通知 | (1) `journalctl -u cc-handoff-relay` 看 submit 的请求是不是 201；(2) `/tmp/cc-handoff.watch.err.log` 看 SSE 连接状态；(3) 反向代理 SSE 缓冲是不是关了（章节 1.2） |
| `/v1/events` 在反代背后返回 5xx | nginx/caddy 的 `proxy_buffering`/`flush_interval` 没设；或 caddy 之前用过 HTTP/3 出 bug，强制 `protocols h1 h2` |
| Claude Code 看不见 MCP 工具 | (1) 没重启 Claude Code session；(2) `claude mcp list` 看有没有 cc-handoff；(3) `cc-handoff-mcp` 二进制没装到 PATH |
| urgent 没自动开终端 | (1) `.cc-handoff.toml` 里 `triggers.auto_launch = true` 没设；(2) watch 不在跑；(3) macOS 隐私权限被拒了，去"系统设置 → 隐私 → 自动化"把 cc-handoff-mcp / cc-handoff 控制 Terminal 的权限打开 |
| 普通优先级也想自动开终端 | 接收侧 `.cc-handoff.toml` 里再加 `triggers.auto_launch_normal = true`(`auto_launch=true` 是前提)。改完重启 watch |
| `make deploy` ssh 失败 | 用 `SSH_OPTS="-i ~/.ssh/id_xxx -p 2222"` 透传给 ssh/scp |
| 升级后 watch 还连旧 token | `launchctl kickstart -k gui/$(id -u)/com.cc-handoff.watch` 强制重启 |
| `cc-handoff status / sent / retract` 返回 "relay does not implement this endpoint" | relay 还是旧版本(没多 agent / 状态可见性那批)。`make deploy HOST=<vps>` 升级 relay |
| `cc-handoff retract` 返回 409 | 对方已经 pickup,无法 retract。改用 `cc-handoff comment <id> "..."` 协调 |
| 不知道某 handoff 还在不在 / 状态如何 | `cc-handoff status <id>`(发件人)/ `cc-handoff inbox`(收件人本地)/ `cc-handoff list`(收件人 relay 上 pending) |

---

## 附录 A：架构与数据流细节

### 一次完整 handoff 的字节流

```
后端 Mac                 VPS                          前端 Mac
────────                ─────                        ─────────

Claude /handoff
  │
  ▼
cc-handoff-mcp.submit_handoff
  │  (1) 写 .draft-summary.md
  │  (2) handoff.Build:
  │      - git diff origin/main...HEAD
  │      - swagger 增量 (与 ~/.cache/cc-handoff/<hash>/swagger.last.yaml 对比)
  │      - rules 引擎跑 partner_mapping
  │      - 大于 200KB 的 diff 截断 + 准备 attachment
  │  (3) POST https://.../v1/handoffs   ─────►  cc-relay
  │                                              │
  │                                              ├─ INSERT handoffs(id,...)
  │                                              ├─ Hub.Publish handoff.created → recipient
  │                                              │                 │
  │                                              │                 │ SSE
  │                                              │                 ▼
  │                                              │                 cc-handoff watch
  │  (4) 大附件 POST /attachments/full.diff       │                 │  (1) GET /v1/handoffs/{id}
  │                                                                │  (2) inbox.Materialize
  │                                                                │       → .cc-handoff/inbox/<id>/  (legacy: .claude/handoff-inbox/<id>/)
  │                                                                │  (3) GET /attachments/full.diff
  │                                                                │       → attachments/full.diff
  │                                                                │  (4) osascript 通知
  │                                                                │  (5) urgent 时 osascript 开终端
  │                                                                │       跑 claude -p / codex exec / … (按当前 agent)
                                                                   ▼
                                                                  Claude /pickup
                                                                    │
                                                                    ▼
                                                                  cc-handoff-mcp.pickup_handoff
                                                                    │
                                                                    ├─ list_inbox → 列表
                                                                    └─ GET → ack → 返回 prompt.md 内容
                                                                              ↓
                                                                            Claude 直接开干
```

### 数据落盘位置

| 路径 | 作用 |
|---|---|
| `/var/lib/cc-handoff/relay.db` | VPS SQLite，handoffs/comments/attachments 三张表 |
| `/var/lib/cc-handoff/backups/` | `cc-handoff-backup` 输出目录 |
| `/etc/cc-handoff/tokens.json` | VPS token → identity 映射 |
| `~/.config/cc-handoff/config.toml` | Mac user 级（relay URL、token、identity） |
| `<repo>/.cc-handoff.toml` | Mac 仓库级（partner、partner_mapping、triggers） |
| `~/.cache/cc-handoff/<repo-hash>/swagger.last.yaml` | swagger 增量计算的上次基线 |
| `<repo>/.cc-handoff/inbox/<id>/`（老仓库 `.claude/handoff-inbox/<id>/`） | 物化的 handoff（package.json、summary.md、prompt.md、full.diff、api-delta.md、comments.md、attachments/） |
| `<repo>/.cc-handoff/inbox/.draft-summary.md`（老仓库 `.claude/handoff-inbox/.draft-summary.md`） | `submit_handoff` 时 agent 写的草稿（每次 submit 都读，不自动清） |

### 安全姿态

- 传输层：TLS 终结在 caddy/nginx，原始流量永不裸跑
- 应用层：每个请求要 `Authorization: Bearer <token>`，token 与 identity 多对一映射存 `tokens.json`，relay 启动时一次性载入内存（hash 后比对）
- 存储层：handoffs / comments / attachments 都按 `recipient` / `sender` 限制读取（postComment、listComments、attachments 端点只允许 sender 或 recipient）
- 审计层：每个请求一条结构化 JSON 日志到 stderr（journald 自动收）
- **没做**：端到端加密。relay 看得到全部 payload。如果你的对接信息含敏感数据（生产凭据、内部 IP），把 relay 部到你完全控制的机器，或者开 issue 推动 M6 的 libsodium sealed box

### 端口与默认值

| 项 | 值 | 在哪改 |
|---|---|---|
| relay 监听 | 127.0.0.1:8080 | systemd unit `ExecStart` `-addr` |
| 反向代理 | :443 | caddy/nginx 配置 |
| SSE keepalive ping | 20s | server.go 写死，需要的话改 server.go events() |
| watch SSE 重连 backoff | 500ms → 30s 指数 | sse_client.go |
| 内嵌 diff 上限 | 200 KB | handoff/build.go `DiffInlineLimit` |
| attachment 上限 | 50 MB | server.go `attachmentMaxBytes` |
| comments.json 单条 body | 64 KB | server.go postComment 的 `MaxBytesReader` |

---

## 附录 B：本地 dogfood

如果想在 VPS 之前先在本机验一遍，看 `docs/dogfood-runbook.md`。流程是：用 `scripts/dogfood.sh setup` 起一个本地 relay + 隔离的 HOME，按 runbook 在 test-* 真实仓库里走 submit/pickup/comment 全程，跑完 `bash scripts/dogfood.sh cleanup` 一键清干净。

---

## 后续改进路径

详见 cc-collaboration plan 文档末尾"待决策事项"。优先级排序：

1. **重复提交去重 + retention 自动清理** — 现在同一分支多次 submit 会留多条；relay 也不会自己删老的 picked handoff
2. **Stop hook 自动触发** — 让后端 Claude 一次会话结束就自动 submit，不用每次手敲 `/handoff`
3. **端到端加密** — libsodium sealed box，relay 只见密文（生产/跨公司联调前必做）
