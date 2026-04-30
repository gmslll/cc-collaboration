package agent

// instructionsSnippet is the cross-agent usage block claude/codex agents
// append to their respective project-level instructions file (CLAUDE.md /
// AGENTS.md). Idempotent appends are handled by setup.AppendSnippet, which
// detects the "## cc-handoff" heading and skips when already present.
//
// Keep this terse — large instructions files reduce per-tool effectiveness
// (the AGENTS.md best-practice guidance is "under 500 lines total").
const instructionsSnippet = `## cc-handoff (cross-machine handoff)

This repo uses cc-handoff to ship API changes between machines / agents.
Available MCP tools (registered as the ` + "`cc-handoff`" + ` server):

- ` + "`submit_handoff`" + ` — package this branch's changes and send to a partner
- ` + "`list_inbox`" + ` — list pending handoffs addressed to me
- ` + "`pickup_handoff`" + ` — fetch by id, materialize files, return integration prompt
- ` + "`comment_handoff`" + ` — back-channel chat between sender and receiver

Materialized inbox lives at ` + "`.cc-handoff/inbox/<id>/`" + ` (or legacy ` + "`.claude/handoff-inbox/<id>/`" + ` on older repos), with files: ` + "`prompt.md`" + `, ` + "`summary.md`" + `, ` + "`full.diff`" + `, ` + "`api-delta.md`" + `, ` + "`package.json`" + `, ` + "`comments.md`" + `.

Repo-level config lives at ` + "`.cc-handoff.toml`" + `; user-level config at ` + "`~/.config/cc-handoff/config.toml`" + ` (Linux/macOS) or ` + "`%AppData%\\cc-handoff\\config.toml`" + ` (Windows). Run ` + "`cc-handoff --help`" + ` for the CLI surface.
`
