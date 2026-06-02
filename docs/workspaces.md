# Workspace launcher

A **workspace** is a one-click launch target for resuming work: a root
directory holding one or more **projects**. After SSH-ing back into your local
machine you no longer have to remember where a project lives and `cd` into it
by hand — `cc-handoff workspace list` prints a ready-to-paste launch command for
each project.

It is a purely **local** concept. The relay (which runs on a shared VPS) never
sees workspace paths, so all of this lives in your user-level config
(`~/.config/cc-handoff/config.toml`) and is driven by the local CLI.

## Model

```
workspace (a root dir)
├── project          ← discovered by scanning the root for git repos
├── project          ← added via `workspace add` (a local path)
└── project          ← added via `workspace add <github-url>` (git clone'd in)
```

The project list is the **union** of:

- git repos found by scanning the workspace root one level deep, and
- the projects explicitly recorded in config (the ones you added/cloned).

So once you clone a repo into a workspace dir, it shows up automatically.

## CLI

```sh
# Register a workspace and create its root dir (default: <workspace_root>/<name>).
cc-handoff workspace create kunlun
cc-handoff workspace create kunlun --path ~/code/kunlun

# Add a project. A git URL is cloned into the workspace dir; a local path is
# just registered (not copied). The workspace is created on demand if missing.
cc-handoff workspace add kunlun git@github.com:org/kunlun-backend.git
cc-handoff workspace add kunlun ~/code/existing-frontend

# List workspaces, their projects, and the launch command to copy.
cc-handoff workspace list
```

`cc-handoff ws ...` is an alias for `cc-handoff workspace ...`.

### Desktop UI

`cc-handoff desktop` shows a **Workspaces** tab listing every project with a
「复制启动命令」button (same copy-to-clipboard flow as pickup). The list is
injected by the local desktop process — in a plain browser (`cc-handoff ui
--open`) there are no local paths to resolve, so the tab is hidden. Like the
CLI, the button only copies the command; it does not auto-start anything.

### What gets executed

The **only** real action is `git clone` (run when you `add` a git URL).
Starting the agent is **not** automated: `workspace list` / `add` print a launch
command like

```sh
cd '/Users/me/code/kunlun/kunlun-backend' && nvm use && code . && claude
```

for you to copy and run. The `pre_launch`, `editor`, and `agent` fields control
how that command is assembled.

## Config

Workspaces live at user level so they span projects:

```toml
# Base dir for auto-carved workspace dirs. Empty → ~/cc-handoff-workspaces.
workspace_root = "~/cc-handoff-workspaces"

[[workspace]]
name       = "kunlun"
path       = "~/cc-handoff-workspaces/kunlun"  # optional; default <root>/<name>
pre_launch = "nvm use"                          # optional: run before the agent
editor     = "code ."                           # optional: also open an editor
agent      = "claude"                           # optional: overrides top-level agent

  [[workspace.project]]
  name   = "kunlun-backend"
  path   = "~/cc-handoff-workspaces/kunlun/kunlun-backend"
  github = "git@github.com:org/kunlun-backend.git"  # set when added via clone
```

You can also edit this file by hand; the CLI just reads and writes it.

## Worktrees

Each project can spawn multiple **branch worktrees** so you can run parallel
agent sessions on different branches without stepping on each other. A worktree
is itself a launchable directory.

```sh
# Create a worktree. Makes the branch if it doesn't exist (from --start or
# HEAD), else attaches the existing branch.
cc-handoff worktree add kunlun-backend feature/login
cc-handoff worktree add kunlun-backend hotfix --start origin/main

# List a project's worktrees with their launch commands.
cc-handoff worktree list kunlun-backend

# Remove one (use --force if it has uncommitted changes).
cc-handoff worktree remove kunlun-backend feature/login
```

`cc-handoff wt ...` is an alias. Pass `--workspace NAME` when a project name
exists in more than one workspace.

**Layout.** Worktrees live at `<project>/.worktrees/<branch>/` (slashes in the
branch become `-`, so `feature/login` → `.worktrees/feature-login`). This keeps
them owned by the project and out of the workspace root. Because a worktree's
`.git` is a *file* nested two levels deep, `workspace list`'s one-level scan
never mistakes a worktree for a top-level project.

**Source of truth.** The worktree list is read live from `git worktree list`;
nothing is persisted to config. `cc-handoff workspace list` shows each project's
worktrees indented under it (`↳`).

**What gets executed.** `worktree add`/`remove` run real `git worktree`
commands. Starting the agent is still copy-the-command, using the same
`BuildLaunchCommand` shape as projects.

## Future extension point

`config.BuildLaunchCommand` is the single source of truth for the launch
command shape. `config.LaunchProject` is a reserved hook for *actually* spawning
the agent (open a terminal, `cd`, run `pre_launch`, start the agent); it is
intentionally unimplemented in this version and returns a not-implemented error.
Wiring up auto-launch later means feeding the fields `BuildLaunchCommand`
already resolves into the terminal-launch path — a localized change.
