# cc-handoff

跨机器 Claude Code 协作工具。后端开发者写完接口后，用一条 `/handoff` 把 Swagger 增量、commit 元信息、Claude 写的会话总结打包，结合前端项目目录约定生成定位提示，推送到自有 VPS 上的中转服务；前端开发者机器上的常驻进程收到后，默认入收件箱+系统通知+一键唤起 Claude，**接收端 Claude 读本地真实代码后产出 `INTEGRATION.md` 作为对接文档**，人工 review 后再执行。紧急任务可自动开新终端跑 `claude -p`。

四个里程碑全部完成。架构与数据流见 [`docs/architecture.md`](docs/architecture.md)，部署与运维见 [`docs/deployment.md`](docs/deployment.md)。

## 里程碑

- ✓ **M1** 手动 submit / list / pickup
- ✓ **M2** SSE + watch 守护 + osascript 通知 + partner_mapping 规则引擎 + Swagger 增量
- ✓ **M3** MCP server（`/handoff` `/pickup` slash command）
- ✓ **M4** 自动唤起新终端 + back-channel comments + 附件通道 + 结构化审计日志

## 部署

完整端到端部署 + 运维 + 故障排查见 **[`docs/deployment.md`](docs/deployment.md)**。最常用的几条：

```bash
# 第一次部署 / 升级 relay 到 VPS（Mac 上跑）
make deploy HOST=user@your-vps

# VPS 上随时可用（deploy 自动安装到 /usr/local/sbin/）
sudo cc-handoff-rotate-token <identity>     # 轮换 token
sudo cc-handoff-backup                       # 热备份 SQLite，KEEP=N 保留份数
sudo cc-handoff-uninstall [--purge]          # 卸载

# 实时审计日志
sudo journalctl -u cc-handoff-relay -f
```

VPS 一定要挂反向代理终结 TLS。caddy 一行就好（`flush_interval -1` 是 SSE 必须的）：

```caddyfile
handoff.your-domain.com {
    reverse_proxy 127.0.0.1:8080 {
        flush_interval -1
    }
}
```

客户端（前后端各一次）：

```bash
# 1) 编译并装到 PATH
make build && sudo install bin/cc-handoff bin/cc-handoff-mcp /usr/local/bin/

# 2) 在你的工作仓库里 init —— 写两个 toml,
#    --with-mcp 顺手 `claude mcp add`,
#    --with-commands 顺手把 /handoff /handoff-module /pickup 装到 .claude/commands/
cd /path/to/your-repo
cc-handoff init --with-mcp --with-commands
```

`--with-*` 可省;省略时 `cc-handoff init` 退化为只写两个 toml,
其余步骤需自己跑 `bash /path/to/cc-collaboration/scripts/install-mcp.sh`
和 `cp .claude/commands/*.md`(适合 CI / 想完全控制每一步的场景)。

接收侧 Mac 还要起常驻 watch:

```bash
# launchd 模板由二进制自带,渲染好的 plist 直接喂给 ~/Library/LaunchAgents/
cc-handoff watch print-unit --workdir=$(pwd) > ~/Library/LaunchAgents/com.cc-handoff.watch.plist
launchctl load ~/Library/LaunchAgents/com.cc-handoff.watch.plist
```

Linux 接收侧用 `--platform=systemd` 输出 user unit:

```bash
cc-handoff watch print-unit --platform=systemd --workdir=$(pwd) \
  > ~/.config/systemd/user/cc-handoff-watch.service
systemctl --user daemon-reload
systemctl --user enable --now cc-handoff-watch
```

VPS 之前想先在本机试一遍：见 [`docs/dogfood-runbook.md`](docs/dogfood-runbook.md)，`bash scripts/dogfood.sh setup` 一键起本地隔离环境。

## 在 Claude Code 内使用

后端两种入口,看场景挑:

- **`/handoff`（diff 模式）**:刚写完一段改动想推过去时用。Claude 读分支 diff、写对接说明、调 `submit_handoff`。
- **`/handoff-module <module-path> [more...]`（模块 brief 模式）**:某模块早就合并、前端要新做集成时用。Claude 读模块下的 routes/handlers/dto/swagger,整理成自包含的 API 契约文档,调 `submit_handoff` 时带 `module_paths`,接收端会自动切到「模块对接」prompt 模板。一次可以传多个模块,空格分隔。

前端 `/pickup` → Claude 看 `list_inbox` 后用 `pickup_handoff` 拉取,产出 `docs/integrations/<id>.md` 等人工 review。中途要问问题用 `comment_handoff` 工具(或 `cc-handoff comment <id> <body>`)。
