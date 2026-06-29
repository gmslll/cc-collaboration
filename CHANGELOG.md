# Changelog

All notable changes to cc-handoff are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows [SemVer](https://semver.org/).

The single source of truth for the version number is the `VERSION` file at the repo root. `make release-tag` refuses to tag unless `CHANGELOG.md` has a matching `## [X.Y.Z]` heading.

## [Unreleased]

## [0.6.16] - 2026-06-29

### Fixed

- **手机端「竖排 / 内容稀疏散落」再修（host PTY 被钉成 1 列）** — 实测有会话的 host PTY 是 `1×79`：路由切换的细条布局把列数 floor 成 1，经 onResize/adoptSize 把 host PTY 钉到 1 列，agent 就把整屏 UI 画进一列（每字一行或几个元素散落在一条竖线上）。0.6.14 为「回 0.6.5 基线」撤掉了 `render.dart` 的退化保护和 host 下限，使其再现。现把退化保护加回（`_updateViewportSize` 忽略 cols<2/rows<2 的瞬时布局），并给 host `resizeFromRemote` 加 `>=2` 兜底（旧版 client 发来的 cols=1 也拒绝）。**此保护与「谁在看就重画谁的」尺寸协商正交**——只过滤退化的 1 列/1 行值，绝不碰真实视口尺寸，所以不会重新引入它当初造成的尺寸钉死。补回 0.6.14 误删的 widget 回归测试，防止该 guard 再被无意撤掉。

> 注：已经被钉成 1 列的旧会话需在手机上重开该会话（或点工具栏「适配」）触发一次正常 resize 才会恢复；新发生的会被上述保护挡住。

### Fixed

- **桌面端 Codex 终端不再把鼠标滚轮/拖拽上报给进程** — Codex 启用 mouse reporting 后，桌面端 xterm 把滚轮和拖拽都当 mouse-report 发给 Codex 进程，但 Codex 的 scrollback 在 xterm（不在进程）、文本选择也该走 GUI，导致滚轮翻不动历史、拖拽选不中（旧版 Codex 也一直如此）。新增 `Terminal.ignoreMouseReports`，Codex 会话置真后 `setMouseMode/setMouseReportMode` 不再生效、mouseMode 恒为 none，滚轮与拖拽回到 xterm 本地路径；Claude（alt-screen，靠 wheel 上报滚自己）不受影响。

### Diagnostics

- 终端右键菜单临时加「诊断(复制)」项，复制当前会话的 `agent/isUsingAltBuffer/mouseMode/lines/view/sel` 运行时状态，用于定位 Codex 选区失效根因（alt vs main buffer / 拖拽是否真的设置了选区）；修复定位后移除。

### Fixed

- **远程终端尺寸回到 0.6.5 正常基线，并新增「当前设备主动适配」** — 0.6.5 的尺寸逻辑（client onResize 首次立即上报、`render.dart` 无退化 guard、host `resizeFromRemote` 用 `rows>0&&cols>0`）原本工作正常；之后 0.6.9 为防竖排叠的一套尺寸 guard、以及随后两版（render `cols<2` guard、把 `_sizedSids` 拆成纯 debounce）反而把它越改越偏，表现为 web/手机看终端时内容缩在中间、看历史记录不正常。现把这几处尺寸改动全部回退到 0.6.5 基线（codex 滚动等不碰尺寸的修复保持不变）。
- **多设备看同一会话「以正在看的为准」** — 此前 host PTY 被「先设过尺寸的设备」固定：web 看过一个会话后切到手机看，PTY 仍是 web 宽度（手机看就缩在中间），因为手机再次打开缓存会话时本地终端尺寸没变、`onResize` 不触发、不会重发尺寸。新增 `RemoteClient.adoptSize`：进入/重连会话页时按本设备视口主动把尺寸推给 host，agent 据此重画；并在终端页工具栏加「适配」按钮（`Icons.fit_screen`）手动兜底——谁在看、谁点，就按谁的屏幕重画。

### Fixed

- **远程终端尺寸改回「谁在看就重画谁的」，修 web 端内容只占中间一条** — web/手机连上会话后，host 端 PTY 应当跟随当前观看 client 的视口尺寸、agent 据此重画。0.6.9 为防竖排叠加的一套尺寸协商（`_sizedSids`「首次立即发、后续 debounce」+ client `w<20` / host `cols>=20` 的 guard）会把某个中间尺寸定死：实测被镜像会话的 host PTY 卡在桌面 spawn 的 132 列（一批会话都是这个统一初值），没跟随更宽的 web 浏览器视口，于是 claude 终端内容只铺到中间、左右大片空白。现在拆掉 `_sizedSids` 与那些 app 层尺寸 guard，onResize 改回「最终稳定视口尺寸经一次 debounce 直接送达 host PTY」，host `resizeFromRemote` 放回 `rows>0 && cols>0`。竖排防护已由 0.6.12 的 `render.dart` 源头保护（cols 永不 <2）独立承担，与尺寸协商干净解耦；`remoteSink` 让权 + 手机断开 `restoreLocalSize` 恢复桌面宽度保持不变。

## [0.6.12] - 2026-06-29

### Fixed

- **手机 Codex 终端竖排 / 滚动只见一列，从根上修复** — 0.6.9 在应用层拦截「过小 resize」只挡住了「手机→电脑」这一条路径，没挡住手机本地 xterm 缓冲区本身。路由切换/键盘动画时 TerminalView 的渲染框会短暂变成「细条」（满高、约 1 格宽），vendored xterm 的 `_updateViewportSize` 把列数向下取整成 1，直接把**手机本地缓冲区重排成 1 列**——每个字符单独换行（竖排）。Claude 用备用屏幕、电脑会重绘自愈；Codex 历史在主缓冲区滚动条里、没有重绘机制，于是竖排定格，上滑也只是看到更多单列行（即「能滚但只有一列」）。现在在 `render.dart` 退化布局保护里忽略 1×N / N×1 的瞬时布局；电脑 PTY、手机→电脑 resize 全部源于这次 resize，一处即护住所有路径。真机全屏终端不可能只有 1~2 列，故无副作用；0.6.9 的应用层保护保留作双保险。新增 widget 回归测试：细条布局不再把终端压成 1 列。

## [0.6.11] - 2026-06-29

### Added

- **账号切换保留多个账号** — 成功登录过的账号会保存在本地账号列表，桌面、手机和 Web 都可以从「切换账号」或登录页直接点选已保存账号，不需要先退出再重新输入密码；当前活跃账号仍会同步写入 `config.toml` 供 CLI/hook 使用。

### Fixed

- **Mac 更新下载安装会自动替换应用** — macOS 下载新版 zip 后会自动解压，点击「重启安装」后退出当前 app、覆盖当前 `.app` 并重新打开，不再只下载文件让用户手动拖拽覆盖。

## [0.6.10] - 2026-06-29

### Fixed

- **Mac 端 Codex 终端恢复滚动历史** — 桌面端不再把 Codex 的滚轮事件送入 mouse-reporting TUI 路径，Codex 会话保留 xterm 本地 scrollback；Claude 仍保持原来的全屏 TUI 滚轮行为。

## [0.6.9] - 2026-06-29

### Fixed

- **手机连接 Codex 终端不再变成竖排文字** — 手机端 TerminalView 初始布局可能短暂上报极小宽度，之前会立刻把 Mac 端 PTY resize 到 1 列，导致 Codex 每个字符单独换行。现在手机端忽略过小 resize，Mac 端也拒绝无效远程终端尺寸；刷新终端会重新等待首个有效手机尺寸。

## [0.6.8] - 2026-06-29

### Added

- **会话总览状态更丰富** — 总览卡片在原有「思考中 / 待 review / 空闲 / shell」主状态下新增细状态，基于 hook 活动流显示正在运行的工具、工具完成或失败、权限等待、prompt 已提交、上下文压缩、完成待查看等信息；桌面总览、手机远程会话卡和快捷预览同步显示。

## [0.6.7] - 2026-06-29

### Fixed

- **Mac 端检查更新不再把检查失败误报为“已是最新”** — 更新检查以前完全依赖未认证 GitHub REST `releases/latest`，公共 IP 被限流或网络失败时会返回空结果，UI 误显示当前版本已是最新。现在先用 GitHub 网页 `/releases/latest` 跳转解析最新 tag，只有确认没有新版才显示“已是最新”；REST 只用于获取平台安装包资产，失败时仍会提示新版并打开 release 页面。

## [0.6.6] - 2026-06-29

### Added

- **账号切换** — 桌面端、手机端和 Web 远程页都支持从当前账号直接登录另一个账号；新账号登录成功后才切换，取消或登录失败不会影响当前会话。
- **Hook 活动流** — `cc-handoff bus-hook` 现在记录轻量结构化事件摘要，并覆盖 `SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PermissionRequest`、`PostToolUse`、`PreCompact`、`PostCompact`、`SubagentStart`、`SubagentStop`、`Stop`。桌面端会把正在手机端观看的会话活动推送到手机，远程终端页新增可折叠「活动」浮层，显示最近工具调用、prompt、退出码等信息。

### Security

- Hook 活动摘要包含 prompt/tool 输入输出片段，落盘时使用本地私有权限目录/文件，避免复用普通配置写入的宽权限。

## [0.6.5] - 2026-06-29

### Fixed

- **手机端 codex 会话可以上滑查看历史记录** — codex 的 transcript 在 main buffer 里有真实 scrollback，即使它启用了 mouse reporting，手机端也不应像 Claude 全屏 TUI 那样禁用本地 scrollback 并只发 host wheel。现在手机端识别为 codex 的会话保留原生本地滚动；Claude 仍沿用原来的 host wheel 滚动路径。

## [0.6.4] - 2026-06-28

### Fixed

- **codex rejected our `hooks.json` ("unknown field `PostToolUse`, expected `hooks`")** — the bus-hook installer wrote the lifecycle events at the file root, but codex requires them under a top-level `hooks` object (same nested matcher-group shape as Claude's `settings.json`). It now writes the correct shape and migrates an existing root-layout file in place. Because codex shows a blocking "trust hooks" dialog for any new/changed hook config, app-spawned codex sessions now launch with `--dangerously-bypass-hook-trust` (the app vouches for its own env-guarded bus hook), so the hook actually runs — interjections + hook-based session capture work on codex — without a dialog stalling interactive or automated launches.

## [0.6.3] - 2026-06-28

### Fixed

- **codex终端满屏后不滚动、只替换最后一行** — codex renders its transcript in the main buffer with a scroll region that reserves the bottom rows for its composer (`ESC[1;5r`). The vendored xterm's `index()` grew scrollback (inserting a line below the margin) whenever the top margin was 0, which — once scrollback existed — inserted at a non-end index of the circular buffer (silent corruption in release) and pinned output to the last line. A region with a real bottom margin now scrolls in place. (claude was unaffected because it uses the alternate screen.) Guarded by a regression test that replays a real codex byte stream.

## [0.6.2] - 2026-06-28

### Fixed

- **Account-page hook self-check wrongly reported "未安装"** — the desktop hook status (and the reinstall prompt) always showed the bus hook as missing even when it was installed, because the check matched the full shell command against the raw config file, whose embedded quotes and `&&` are JSON-escaped on disk. It now matches the escaping-invariant `cc-handoff bus-hook` invocation. The hook itself always worked — only the status display was wrong.

## [0.6.1] - 2026-06-28

### Fixed

- **Android updates install in place (no more "软件包冲突")** — release APKs are now signed with a stable, committed keystore instead of a per-machine/per-CI debug key, so an update installs over the previous one and the in-app updater works. The APK's versionName/versionCode are derived from the `VERSION` file (e.g. 0.6.1 → versionCode 601) so each release outranks the last. (One-time migration: uninstall the old debug-signed app once, then install this; future updates are seamless.)

## [0.6.0] - 2026-06-28

### Added

- **Exact agent session-id binding & recovery (claude + codex)** — a reopened or restarted session now resumes the *exact* prior conversation instead of guessing. codex's session id (which can't be set at launch) is captured the moment it starts from the rollout file it holds open (asked of the OS via `lsof` on the codex process under the PTY), so it no longer races on file mtimes. On resume with no captured id, the tab picks *this folder's* newest rollout (`codex resume <id>`) instead of the blind `codex resume --last`, so it can't resume a different directory's session.
- **Hook-based session-id capture** — the existing `cc-handoff bus-hook` (PostToolUse/Stop, installed for both Claude Code and Codex) now also records each session's own agent session id to `$CC_BUS_DIR/sessions/<id>.json`, keyed by the tab's `CC_SESSION_ID`. Event-driven and authoritative (the agent reporting its own id via the hook payload), and the only capture path on Windows where `lsof` is unavailable. Writes are skipped when unchanged.
- **Hook self-check (账号 page, desktop)** — shows whether the bus hook is installed in each agent's config (claude `~/.claude/settings.json`, codex `$CODEX_HOME/hooks.json`) with a one-tap reinstall, backed by a new `cc-handoff bus-hook status` so the paths and "installed" criterion have one source of truth in the CLI.

### Fixed

- **Phone-created sessions no longer start blank** — the PTY launches immediately on creation instead of waiting for the desktop to render the terminal pane, so a session created from the phone (while the desktop's terminal panel is collapsed or on another view) starts its agent right away.
- **Desktop restart no longer leaves the phone mirroring a permanently blank terminal** — session ids are persisted and restored, so a phone holding an id still resolves it after the desktop restarts (ids no longer re-mint from zero each launch).
- **codex sessions no longer go blank or resume the wrong conversation** after a desktop restart — fixed by the stable ids plus the exact session-id capture above.

## [0.5.0] - 2026-06-28

### Added

- **Session overview (会话总览)** — a desktop top-level page + a phone grid that lay every open session out flat, grouped by workspace → project → worktree; each card shows the agent's latest-reply preview, status (working / needs-review / idle), and token usage so you can see at a glance which sessions finished and need review. Each session gets a deterministic generated "robot" avatar (consistent across the tab strip, project tree, overview, and phone), and working sessions get a subtle breathing animation.
- **Quick-reply popup** — tapping a session in the overview opens a live, *colored* terminal preview plus confirm/reply controls (↵ / 1·2·3 / y·n / Esc / free text) so you can act without switching to the workspace or the full-screen mirror. The phone pulls the current screen via a new `screen` frame; an 账号 toggle makes the popup the default tap action (else the tap opens the full terminal).
- **Per-session token usage / estimated cost** (claude + codex) — a desktop overlay chip and the phone overview / Live Activity, computed incrementally from each session's on-disk transcript.
- **Phone mirror improvements** — full pre-connect history replay + stick-to-bottom on open + first-frame sizing reported at the phone's width; bidirectional in-session file transfer + terminal sync; an idle session-history cache that re-pulls fresh; an adjustable terminal font size (so a wide full-screen TUI like codex lays out with enough columns to read).
- **Cross-device workspace/project sync** — desktop-side create/remove of a workspace or project now propagates to connected phones, and the `roots` frame carries all workspace names so an empty workspace is visible (and can receive its first project) from the phone's 管理 tab.
- **In-app update** — checks the public GitHub Releases and offers one-tap download + install (Android → system installer; macOS → download + reveal, since an ad-hoc/un-notarized app can't self-install silently). The build's version is injected at build time via `--dart-define=APP_VERSION` (from the `VERSION` file).
- **Three-platform app packaging to Releases** — `package-apps.yml` attaches the macOS / Windows / Android packages to the GitHub Release on a `v*` tag (alongside the Go CLI binaries from `release.yml`).
- **Android AI status** (foreground service + persistent notification, a Live-Activity equivalent) and **iOS** device-info integration.
- **Diff full/changed toggle + read-only code view** on the phone; `msg read` gains a structured `transcript` channel that reads a peer session's on-disk transcript instead of screen-scraping.
- Local session bus **mid-turn interjection** — a peer message sent to a *busy* agent session (mid-turn) no longer just queues behind the running turn. The desktop app now routes by the target's busy/idle state (derived from the existing BEL "turn finished" detector): an **idle** target still gets the message pasted straight into its PTY (immediate turn), while a **busy** target gets it parked in a per-session bus inbox (`$CC_BUS_DIR/inbox/<session-id>/`, `internal/localbus`) that the target's **PostToolUse** hook drains as `additionalContext` at the next tool boundary — surfacing the message inside the running turn without interrupting it — with a **Stop** hook as the turn-end backstop. One `cc-handoff bus-hook` binary serves both Claude Code and Codex (identical hook contract); `cc-handoff bus-hook install` (run on app start) idempotently wires the hooks into `~/.claude/settings.json` and `~/.codex/hooks.json`. The hook command self-gates on `$CC_BUS_DIR`, so it's a sub-millisecond no-op in any session the app didn't spawn — the user's other Claude/Codex sessions are untouched.

### Fixed

- Local-bus subagent hooks no longer steal the parent session's inbox.
- Switching sessions refreshes that session's usage chip immediately (no longer frozen at the previous turn boundary).
- Windows terminal fixes — Chinese IME input (vendored + patched `flutter_pty`), Chinese-path launch failures, and a missing `SystemRoot`/environment on `cmd.exe`.
- `pasteText` auto-submit gains a fallback resend.

## [0.3.0] - 2026-06-05

### Added

- Multi-tenant relay — the relay grows user **accounts + password login + roles + projects** so one shared instance can serve many teams. The bearer-auth middleware becomes a `Resolver` that accepts, in order, a **UI login session**, a **DB-minted machine token**, or the legacy **`tokens.json`** — all resolving to one identity, so the existing CLI / watch / MCP data plane is unchanged and a relay can run with no tokens file at all. New schema (all `CREATE TABLE IF NOT EXISTS`, idempotent in-place upgrade): `users` (bcrypt password, `is_admin`, `disabled`), `sessions`, `machine_tokens`, `projects`, `project_repos` (a repo belongs to one project), `project_members` (role `owner`/`member`/`viewer`). Adds `golang.org/x/crypto` (pure-Go bcrypt; `CGO_ENABLED=0` preserved).
- Accounts & sessions — `POST /v1/login` (issues a session token used as a normal Bearer), `/v1/logout`, `GET /v1/me` (identity + admin flag + project roles), `POST /v1/password`. Admins manage accounts via `GET/POST /v1/users` and `POST /v1/users/{id}/admin|disable|reset-password` (generated passwords shown once). First-admin bootstrap is the `cc-relay useradd --identity <id> --admin [--password P]` host subcommand; operator-seeded admins come from `-admins` / `RELAY_ADMINS` (effective admin = seed ∪ `users.is_admin`, so an operator can't be locked out).
- Projects & self-service — any signed-in user `POST /v1/projects` (becomes `owner`) and manages their own project's repos + members via `PATCH/DELETE /v1/projects/{id}`, `.../repos`, `.../members`; admins manage all. `GET /v1/projects` returns your projects (all for admins).
- Project-scoped read authorization — a single `canViewPackage` gate (admin ‖ legacy participant ‖ member of the project owning the handoff's repo) now backs `GET /v1/handoffs/{id}`, `/status` (de-duping its previously-inlined check), `/prompt`, `/comments`; project members see every handoff in their projects via `GET /v1/handoffs?scope=project[&project=<id>]` (or `?scope=all` for admins). Comment-posting widens to owner/member (not `viewer`); ack / retract / reassign stay restricted to the actual recipient/sender. All additive — a relay with no projects behaves exactly as before.
- Self-service machine tokens — `GET/POST/DELETE /v1/tokens` let any user mint (raw value shown once) and revoke their own bearer tokens for CLI / watch / MCP, replacing hand-edited `tokens.json` entries (which still work). Revocation is owner-scoped.
- Relay Web UI — password login (replacing the paste-a-token form; machine-token paste kept as an advanced option) + sign-out, and role-aware tabs driven by `/v1/me`: **Projects** (create + manage members/repos, browse a project's handoffs), **Account** (change password, mint/revoke machine tokens), **Admin** (account management, admins only). Requires HTTPS (passwords/sessions). See `docs/deployment.md` §1.5.

## [0.2.0] - 2026-06-03

### Added

- Workspace launcher — `cc-handoff workspace create/add/list/open` (alias `ws`) turns a root dir holding one or more git repos into one-click resume targets, so after SSH-ing back you no longer hand-`cd` into projects. A purely local concept driven by the user-level config: top-level `workspace_root` (auto-carve base, defaults to `~/cc-handoff-workspaces`) plus `[[workspace]]` blocks (`name` / `path` / `pre_launch` / `editor` / `agent`) and nested `[[workspace.project]]` (`name` / `path` / `github`). The project list is the union of repos found by scanning the root one level deep and the projects explicitly recorded in config, so a repo cloned into the dir shows up automatically. `cc-handoff desktop` gains a **Workspaces** tab listing each project with a「复制启动命令」copy-to-clipboard button (hidden in a plain browser, which has no local paths to resolve). See `docs/workspaces.md`.
- Branch worktrees — `cc-handoff worktree add/list/open/remove` (alias `wt`) lets each project spawn multiple branch worktrees for parallel agent sessions without collisions. `add` makes the branch from `--start REF` or HEAD (or attaches an existing one); `--open [--window]` jumps straight in; `--workspace NAME` disambiguates a project name shared across workspaces; `remove --force` drops one with uncommitted changes; `remove --prune-merged --base main` sweeps every worktree whose branch is already merged. Worktrees live at `<project>/.worktrees/<branch>` (slashes → `-`), read live from `git worktree list` (nothing persisted), and `workspace list` shows each project's worktrees indented under it (`↳`).
- Project launch execution — `workspace open` / `worktree open` now actually launch instead of only printing the command. The default **in-place** path `exec`s `$SHELL -i -c <command>` so the terminal you're already in becomes the agent session (SSH-friendly, does not return); `--window` opens a new terminal (macOS Terminal.app/iTerm2 per the repo's `[triggers]`, Windows terminal/PowerShell), unavailable over plain SSH. `config.BuildLaunchCommand` (`cd` + `pre_launch` + `editor` + agent) is the single source of truth shared by both the printed command and `open`, so they never diverge; the cmd-layer `launchProject` picks the exec-vs-window strategy.
- `cc-handoff pickup <id> --worktree [--open [--window]]` — integrate a handoff on an isolated branch instead of your main checkout, so parallel handoffs don't collide. Carves a worktree at `<repo>/.worktrees/h_<shortid>_<senderBranch>` (the branch from the handoff's `Repo.Branch`; `h_<shortid>` when unknown) and materializes the inbox **inside** it. The `pickup_handoff` MCP tool takes the same `worktree: true` argument but only creates + materializes — it never launches an agent (no terminal to exec into from a headless MCP server).
- Multi-repo receiving — `cc-handoff pickup --repo PATH` materializes a package into any repo without `cd`-ing, and `cc-handoff watch --no-materialize` makes watch notify-only (no auto-landing on the receiver side), so one identity can route handoffs across multiple receiver repos that share the same `identity.me`. `cc-handoff desktop` auto-discovers the current repo as the default target, so the Web UI pickup button materializes there without manual `--repo`.
- Relay Web UI handoff actions — the inbox detail view gains a **转交** dialog (pick a target user + reason; shown only for pending `bug`-kind handoffs), an **接收并物化** button (pickup + materialize in one click; in `desktop` mode it calls the local pickup directly), a **Prompt** panel that previews the receiver prompt with **复制 Prompt** / **复制 CLI** buttons, and the bug-only **reassign** button — so a bug can be picked up, reassigned, or handed on without leaving the browser.
- Log triage — per-project log source + `cc-handoff logs <project>`. A `[workspace.project.log]` block (`host` / `command` / optional `grep` / `context`) tells cc-handoff how to pull a project's logs: with `host` it runs `ssh <host> <command>`, without it runs `command` locally (kubectl/docker/file). The captured stdout is extracted **locally** — the last line matching the error pattern plus N context lines (no match → trailing `--lines`) — and written to `<project>/.cc-handoff/logs/<ts>.md` as a triage prompt. Default prints the path; `--open` launches the agent one-shot in the project to analyze (`--window` for a new terminal), reusing the `workspace open` launch path. See `docs/logs.md`.
- Push log alerts — server-side error hooks forward alerts to a teammate's `watch`: `POST /v1/alerts` (bearer-auth, fans out a new `log.alert` SSE event to the recipient) plus the `cc-handoff alert --to <id> --project <name> [--message TEXT | --file PATH] [--level LVL] [--grade]` sender that calls it (servers without cc-handoff can `curl` the endpoint). On receipt, `watch` writes the alert as a triage prompt into the named project and pops a desktop notification; the new `[triggers].auto_launch_on_alert` (default `false`) opts into auto-launching the agent in a new terminal window to start triaging. A project that can't be resolved locally degrades to notify-only.
- Local-AI severity grading — an optional user-level `grade_command` (e.g. `ollama run llama3.2`, or a cloud wrapper reading stdin) lets `cc-handoff logs` rate each error `critical`/`high`/`medium`/`low`, recorded in the triage file header. cc-handoff pipes a one-word-answer prompt + the excerpt to the command's stdin and parses the level from stdout (chatty replies tolerated; failures are best-effort and just omit the level). `cc-handoff logs --no-grade` skips it; `cc-handoff alert --grade` reuses the same grader to fill an alert's level.
- Log triage dedup — triage files are now named by a normalized fingerprint of the matched error line instead of a timestamp, so the same failure recurring with a different timestamp / id / `0x…` address / UUID / line number is backed up only once. A repeat reports `duplicate error, already backed up` and leaves the existing file untouched (still `--open`-able); the same dedup applies to pushed `log.alert`s.
- `cc-handoff logs config <project>` — interactively set up (or edit) a project's `[workspace.project.log]` block instead of hand-editing the user config. Prompts for host / command / grep / context (pre-filled with current values when editing), reusing the same config-write path as `workspace add`; an auto-discovered project is pinned to an explicit `[[workspace.project]]` entry on first config.
- `cc-handoff desktop` subcommand — opens the existing Web UI in a native-feeling Chromium app window via [Lorca](https://github.com/zserge/lorca). Pure Go, no CGO, so the main CLI's `CGO_ENABLED=0` Linux/Windows cross-compile path is preserved. Auto-injects the relay token from user config into `localStorage` and sets `:root[data-mode="desktop"]` so the auth panel hides — no token paste required. Probes Chrome → Edge → Brave → Chromium and honors `--chrome PATH` for explicit overrides; falls back with a clear message that points to `cc-handoff ui --open` when no Chromium-based browser is installed.

### Changed

- Web UI visual refresh in `internal/relay/ui/styles.css`: indigo accent palette, system font stack with antialiasing, dark-mode support via `prefers-color-scheme`, dedicated status-badge colors (pending/picked/retracted/expired/reassigned/urgent), distinct kind-badge colors (delivery/request/bug), card hover lift, tighter design tokens (CSS variables for radii / spacing / shadows). Same markup, no JS changes — improvements apply to both the browser UI and the new `cc-handoff desktop` window.

## [0.1.2] - 2026-05-20

### Added

- `[integrations.linear]` config block in `.cc-handoff.toml` (fields: `enabled`, `team_key`, `default_labels`, `mcp_prefix`, `sync_on_submit`, `sync_on_pickup`, `sync_on_comment`, `sync_on_retract`). Disabled by default; when enabled, the five operation MCP tools (`submit_handoff`, `submit_request`, `pickup_handoff`, `comment_handoff`, `retract_handoff`) append a `## 同步到 Linear` section at the end of their result instructing the agent which `mcp__linear__*` calls to make next. cc-handoff itself never calls the Linear API — authentication and HTTP are delegated to whichever Linear MCP server the user already has configured. `mcp_prefix` overrides the wire-name prefix (default `linear`) for installs that namespace their Linear MCP tools differently.
- `cc-handoff link-linear --handoff <id> --issue <ENG-XXX> [--url URL]` CLI subcommand and `mcp__cc-handoff__link_linear` MCP tool. Both record the handoff↔Linear-issue binding to `<inbox-dir>/sent/<handoff>/linear.json` using atomic tmp+rename write. The MCP tool is the loop-closer Claude calls after creating the Linear issue, so the entire Linear outbound flow stays in MCP without dropping to Bash.
- `/handoff-from-linear <issue-id>` slash command — reads a Linear issue via Linear MCP (`mcp__linear__get_issue`), composes a cc-handoff request summary preserving title / description / acceptance / source URL, sends it via `submit_request`, then appends a `<!-- cc-handoff: <id> -->` anchor to the Linear issue description so the binding is recoverable later. Inbound counterpart to the outbound sync block.
- `inbox.LinearLink` struct and `inbox.WriteLinearLink(inboxDir, handoffID, identifier, url) (string, error)` — shared atomic writer used by both the CLI subcommand and the MCP handler. Same tmp+rename pattern as `inbox.SaveCursor`.
- `mcp.CCHandoffMCPPrefix = "mcp__cc-handoff__"` constant and `mcp.ToolLinkLinear = "link_linear"` constant in the tool registry. The prompt template composes the wire name from these instead of hardcoding it, so renaming a tool only requires updating its constant.
- MCP tool count: 12 → 13. Integration test `TestMCPEndToEnd` now compares against `len(mcp.DefaultTools())` instead of a hardcoded literal, so future tool additions don't require updating the assertion.
- Codex workflow skills for the command templates: `cc-handoff init --agent codex --with-commands` now turns each `internal/setup/templates/commands/*.md` workflow into a user-level Codex skill under `$CODEX_HOME/skills/cc-handoff-*/SKILL.md` (`cc-handoff-handoff`, `cc-handoff-pickup`, `cc-handoff-request`, etc.). The actual cc-handoff integration remains MCP-based; the skills are natural-language workflow entry points that instruct Codex to call the cc-handoff MCP tools.

### Changed

- Codex command install no longer generates a repo-local `.codex` plugin marketplace or runs `codex plugin marketplace add` / `codex plugin add`. This avoids relying on unsupported custom slash-command behavior in current Codex CLI versions.
- Non-interactive Codex workflow-skill installs now refresh older stamped skills automatically on binary upgrade, while still skipping newer on-disk versions.
- Upgrades from the previous single `$CODEX_HOME/skills/cc-handoff/` Codex skill remove that legacy stamped skill so Codex does not keep discovering stale catch-all workflow prompts. Unstamped user-authored `cc-handoff` skills are left untouched.
- Codex documentation now describes the stable MCP + workflow-skill path instead of promising `/` slash command visibility.
- `submit_bug` now resolves role aliases such as `frontend`, `backend`, and `both` against configured real identities before submitting. This prevents bug reports from being sent to a literal role name like `frontend` when `.cc-handoff.toml` actually names `alex@frontend`.

## [0.1.1] - 2026-05-08

### Added

- `prd` parameter on `submit_handoff` / `submit_request` MCP tools, `--prd` flag on `cc-handoff submit`, and `BuildOptions.Prd` → `Package.PrdMD` (`prd_md` JSON field, `omitempty`). Carries upstream product-requirement / design-intent markdown as background reference. Renders to receiver prompt as `## 📋 产品需求 / 设计意图 (背景参考)` section between the responds-to banner and the summary; **not** required to be addressed line-by-line in INTEGRATION.md (the distinction vs. `note`, which renders as `(必读)` and is). Slash commands `/handoff`, `/handoff-module`, `/request` ask the user once for PRD before the existing note step, accepting three input modalities: file path, pasted text, verbal description (Claude organizes faithfully without inventing). Backward-compatible: `omitempty` keeps old envelopes byte-identical, and all renderers gate the section on `strings.TrimSpace(p.PrdMD) != ""` so empty/whitespace PRDs are skipped uniformly.
- `/request` slash command and MCP tool `submit_request` — reverse flow for the receiver (typically frontend) to ask the partner (typically backend) to add a missing field / endpoint / capability. Summary IS the request body; no git diff or swagger delta is collected. Picked up via the existing `/pickup`; the materialized prompt switches to a request-specific template (doc mode writes `docs/requests/<id>.md`; direct mode modifies code).
- `responds_to` parameter on `submit_handoff` MCP tool / `BuildOptions.RespondsTo` — when the backend's reply handoff carries it, the receiver prompt and `summary.md` render an "↩️ 回应 r_xxx" banner so frontend can trace the loop back to the original request.
- `handoffschema.Kind` (`KindDelivery` / `KindRequest`) on `Package` and `ListItem`; new `kind` column in the `handoffs` SQLite table (idempotent migration on relay startup). Empty kind on legacy payloads is treated as `KindDelivery` via `Package.EffectiveKind()`.
- `[REQUEST]` / `[handoff]` tag in `list_inbox` / `list_sent` output so the receiver can tell at a glance what's pending.
- `[triggers].auto_launch_normal` option in `.cc-handoff.toml` — when `true` alongside `auto_launch=true`, normal-priority handoffs/requests also spawn a terminal (default `false`: only `urgent` ones do, preserving prior behavior).
- Presence broadcast — relay fans out `user.online` / `user.offline` SSE events to every other connected identity when an identity's first watch session attaches or its last one drops. The receiver's `cc-handoff watch` shows a desktop notification. Reconnect blips can produce offline-then-online; opt out with `[triggers].mute_user_presence = true`.
- Auto-launch options in `[triggers]`: `pre_launch` (shell snippet inserted between `cd <repo>` and the agent invocation — for multi-account OAuth like `clset 6` or env activation), `launch_interactive` (start the agent without `-p`, then inject the prompt body via the terminal app's API after the REPL is ready; bracketed-paste markers preserve multi-line content; macOS only), `launch_mode` (`"window"` default, `"split"` for iTerm2 split-pane / Terminal.app new tab fallback). `Agent.POSIXPromptCmd` / `PowerShellPromptCmd` signatures gained `preLaunch` and `interactive` parameters as a result.

- `[triggers].ack_on_launch` option (`"never"` default / `"after_exit"` / `"on_launch"` / `"slash_pickup"`) wires `/pickup`-equivalent ack into the auto-launch flow. `after_exit` chains `cc-handoff pickup <id>` after the agent exits cleanly (one-shot mode) or appends a postlude line to the injected prompt body asking the agent to call `pickup_handoff` MCP before completing (interactive mode). `on_launch` chains pickup ahead of the agent invocation in a brace group so pickup failure doesn't block the launch — refused with `launch_interactive=true`. `slash_pickup` starts the agent interactively and injects `/pickup` as the first user input so the agent runs the slash-command template (which calls `pickup_handoff` MCP itself) — requires `launch_interactive=true` and Claude (slash commands aren't a Codex feature); macOS only. `ack_on_launch="never"` (the default) preserves the prior behavior of manual `/pickup`.
- `cc-handoff status <id>` and MCP tool `status_handoff` — sender-side visibility into recipient state (pending / picked / retracted), picked_at, comment count, last comment summary.
- `cc-handoff sent [--limit N]` and MCP tool `list_sent` — list handoffs you've sent recently with state.
- `cc-handoff retract <id> [--reason TEXT]` and MCP tool `retract_handoff` — sender-only cancellation of still-pending handoffs. Recipient watch surfaces a `RETRACTED.md` marker + desktop notification via the new `handoff.retracted` SSE event.
- `cc-handoff inbox [--json]` and MCP tool `list_local_inbox` — list handoffs already materialized into the local repo's inbox dir, with retract / comment flags.
- `cc-handoff open <id> [--dry]` — re-launch the configured agent on a previously picked handoff (useful when the auto-launched terminal was closed or the machine rebooted).
- Relay endpoints: `GET /v1/handoffs/{id}/status`, `POST /v1/handoffs/{id}/retract`, `GET /v1/handoffs?as=sender`.
- `handoffschema.StateRetracted` and `RetractEvent` schema additions; `ListItem` gains optional `recipient` field for sender-side listings.

### Changed

- `cc-handoff init` finish message now branches sender vs receiver next steps explicitly instead of a single generic line.
- `cc-handoff pickup` final output points at the new `cc-handoff open <id>` command rather than vague "feed it to your agent session".
- "Summary is empty" error from `submit` now includes a Markdown template the user can paste in.
- `transport.Client` typed errors `ErrNotImplemented` / `ErrConflict`; CLI surfaces "your relay is too old, run `make deploy`" when calling new endpoints against an unupgraded relay.

## [0.1.0] - 2026-04-30

First tagged release. Cuts a baseline before iteration so the MCP server version embedded at build time is no longer hard-coded `"0.1.0"` but driven by `VERSION` + ldflags.

### Added

- `cc-handoff version` subcommand prints the embedded semver, vcs revision, dirty flag, and build time. Helps users compare a long-running MCP process against the binary on disk.
- `cc-handoff-mcp` logs `cc-handoff <ver> (<sha>) built <time>` to stderr at startup, and embeds the same version string in its MCP `serverInfo`.
- Stale-binary detection: when the on-disk `cc-handoff-mcp` binary mtime moves forward after the process started, every tool result is prefixed with a warning telling the user to `/mcp` reconnect.
- `Makefile` targets: `cli`, `mcp`, `relay`, `install`, `version`, `release-tag`. All builds inject the version via `-ldflags`.
- `internal/version` package exposes `Version` (ldflags-overridable) and `Full()` (formatted with vcs metadata).
- `/handoff-module` slash command: composes a self-contained module API brief and submits it via `submit_handoff`'s `module_paths` parameter.

### Changed

- `internal/inbox/materialize.go` `renderPromptMD` detects module-brief mode by content shape (`p.Git == nil`) instead of relying solely on `p.ModulePaths`. An older receiver MCP that strips the `module_paths` JSON field still gets the right prompt template.
- Step 0 of the receiver prompt no longer references "API delta" when there is no api-delta to consume (module mode).
- `internal/rules/engine.go` `Apply` performs a second-pass dedup on `(SuggestEdit, SuggestCreate)`. In module mode where many handler/dto files in the same module route to the same client target, 14 redundant hints collapse to one with `(and N other paths in module)` annotation.

[Unreleased]: https://github.com/gmslll/cc-collaboration/compare/v0.6.11...HEAD
[0.6.11]: https://github.com/gmslll/cc-collaboration/compare/v0.6.10...v0.6.11
[0.6.10]: https://github.com/gmslll/cc-collaboration/compare/v0.6.9...v0.6.10
[0.6.9]: https://github.com/gmslll/cc-collaboration/compare/v0.6.8...v0.6.9
[0.6.8]: https://github.com/gmslll/cc-collaboration/compare/v0.6.7...v0.6.8
[0.6.7]: https://github.com/gmslll/cc-collaboration/compare/v0.6.6...v0.6.7
[0.6.6]: https://github.com/gmslll/cc-collaboration/compare/v0.6.5...v0.6.6
[0.6.5]: https://github.com/gmslll/cc-collaboration/compare/v0.6.4...v0.6.5
[0.6.4]: https://github.com/gmslll/cc-collaboration/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/gmslll/cc-collaboration/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/gmslll/cc-collaboration/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/gmslll/cc-collaboration/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/gmslll/cc-collaboration/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/gmslll/cc-collaboration/compare/v0.3.0...v0.5.0
[0.3.0]: https://github.com/gmslll/cc-collaboration/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/gmslll/cc-collaboration/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/gmslll/cc-collaboration/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/gmslll/cc-collaboration/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/gmslll/cc-collaboration/releases/tag/v0.1.0
