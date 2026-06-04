# Log triage

Give each workspace project a **log source** and `cc-handoff logs <project>`
pulls its latest error (plus surrounding context) off the server, writes it
into the project, and — with `--open` — launches the agent right there to
troubleshoot. There's also a **push** path: a server-side hook forwards an
alert to your `watch`, which writes the same triage file and (optionally)
auto-launches the agent.

Like the [workspace launcher](workspaces.md), the log source is a purely
**local** concept driven by user config — the relay only relays the push
alerts, it never sees your log commands or paths.

## Configure a log source

Hang a `[log]` block off any `[[workspace.project]]` in your user config
(`~/.config/cc-handoff/config.toml`):

```toml
[[workspace]]
name = "kunlun"

  [[workspace.project]]
  name = "kunlun-backend"
  path = "kunlun-backend"

    [workspace.project.log]
    host    = "deploy@10.0.0.5"                       # ssh target; omit to run command locally
    command = "tail -n 2000 /var/log/app/error.log"   # its stdout is the raw log stream
    grep    = "(?i)(error|panic|fatal)"               # optional; default matches error/panic/fatal/traceback/exception
    context = 20                                       # optional; lines kept on each side of the latest match
```

- **`host`** — ssh target. With it set, cc-handoff runs `ssh <host> <command>`.
  Leave it empty to run `command` through your local shell, so
  `kubectl logs …`, `docker logs …`, or a local file all work as written.
- **`command`** — anything that prints the log stream to stdout. The "latest
  error + context" extraction happens **locally** on the captured output, so
  you don't have to splice `grep`/`tail` into a remote one-liner.

Prefer not to hand-edit the TOML? `cc-handoff logs config <project>` walks you
through host / command / grep / context interactively and writes the block for
you (it pre-fills the current values, so the same command edits an existing
source). The project just has to exist in a workspace first; an auto-discovered
one gets pinned to an explicit entry on first config.

## Pull and triage

```sh
# Fetch the latest error + context, write it into the project, print the path.
cc-handoff logs kunlun-backend

# …and immediately launch the agent in the project to analyze it.
cc-handoff logs kunlun-backend --open            # in-place: replaces this shell (SSH-friendly)
cc-handoff logs kunlun-backend --open --window   # …in a new terminal window instead

# Tweak the extraction for this run.
cc-handoff logs kunlun-backend --grep "(?i)timeout" --context 40
```

Flags: `--workspace NAME` (disambiguate a project shared across workspaces),
`--grep RE` and `--context N` (override the source's settings), `--lines N`
(trailing lines kept when nothing matches the pattern), `--no-grade` (skip
severity grading for this run), `--open` / `--window`.

The excerpt is written to `<project>/.cc-handoff/logs/<fingerprint>.md` as a
ready-to-use triage prompt (provenance header + fenced log + a "find the root
cause and fix it" task). `--open` feeds that file to the agent one-shot
(`claude -p "$(cat …)"`) in the project dir, reusing the same launch path as
`workspace open`. Without `--open` you just get the file path and a hint — copy
it, open it, or run `--open` when ready.

## Grade severity with a local AI

Configure a `grade_command` at the top of your user config and `cc-handoff logs`
asks a local model to rate each error `critical` / `high` / `medium` / `low`,
recording it in the triage file header (`- 严重等级: high`):

```toml
# ~/.config/cc-handoff/config.toml
grade_command = "ollama run llama3.2"   # local; or a cloud wrapper / `claude -p` reading stdin
```

cc-handoff pipes a short "rate this error's severity, reply with one word"
prompt plus the excerpt to the command's stdin and reads the level back from its
stdout (chatty replies are fine — the first level word wins). It's best-effort:
a missing or failing grader just omits the level, never blocks the triage. Pass
`--no-grade` to skip it for one run; leave `grade_command` unset to disable it.

The same grader powers `cc-handoff alert --grade`, which rates the message and
sends it as the alert's `--level` (see below).

## Dedup: one backup per unique error

Triage files are named by a **fingerprint** of the matched error line, not a
timestamp, so the same failure recurring with a different timestamp / id / hex
address / line number maps to one file — it's backed up only once. A repeat run
reports `duplicate error, already backed up — <path>` and leaves the existing
file untouched (you can still `--open` it). The fingerprint normalizes the
volatile parts (digits, `0x…` addresses, UUIDs) before hashing. The same dedup
applies to pushed alerts, so a flapping server error doesn't pile up files.

## Push: forward server alerts to your watch

Instead of polling, let the server push. A backend error hook forwards an alert
to the relay; your running `cc-handoff watch` receives a `log.alert` event,
writes the triage file into the target project, pops a desktop notification,
and — when you've opted in — launches the agent to start triaging.

**Send (server side).** With cc-handoff installed, an error hook / cron calls:

```sh
cc-handoff alert --to you@backend --project kunlun-backend --level error \
  --message "$(tail -n 200 /var/log/app/error.log)"
# --grade rates the severity with the local grader and sends it as --level:
cc-handoff alert --to you@backend --project kunlun-backend --grade \
  --message "$(tail -n 200 /var/log/app/error.log)"
# or read the body from a file / stdin:
cc-handoff alert --to you@backend --project kunlun-backend --file /var/log/app/error.log
```

It uses your configured `relay_url` + `token` and targets your own identity, so
the alert lands on your machine. A server without cc-handoff can POST the same
payload directly:

```sh
curl -sS -X POST "$RELAY_URL/v1/alerts" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"recipient":"you@backend","project":"kunlun-backend","level":"error","message":"…log body…"}'
```

**Receive (your machine).** `cc-handoff watch` already handles it. Auto-launch
is **off by default** (it only notifies + writes the file); turn it on in the
receiving repo's `.cc-handoff.toml`:

```toml
[triggers]
auto_launch_on_alert = true
```

When on, the agent is launched in a **new terminal window** (never in-place — it
mustn't replace the watch daemon). A project name the receiver can't resolve to
a local workspace project degrades gracefully to notify-only.
