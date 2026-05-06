---
description: Pull the next pending handoff from cc-handoff and start integrating.
---

You're the receiving side of a cc-handoff pair. Your partner just sent integration instructions.

1. Call the `list_inbox` MCP tool to see pending handoffs.
   - If empty, tell the user and stop.
   - If there's exactly one, proceed with it.
   - If there are several, summarize them and ask the user which to pick up.

2. Call `pickup_handoff` with the chosen id.
   - **Default** (omit `direct`, or set `direct: false`): the returned prompt instructs you to produce `docs/integrations/<id>.md` first and stop for human review of the plan before touching code.
   - **Direct mode** (`direct: true`): only when the user explicitly asks ("直接改 / 不用文档 / direct / fast / just do it"). The prompt then tells you to modify code directly and stop after the diff for human review.

   The tool will materialize the package under `.claude/handoff-inbox/<id>/` and return a prompt describing what to integrate. The package directory contains:
   - `summary.md` — human-readable overview
   - `prompt.md` — the same content the tool returned to you, useful for re-reading
   - `full.diff` — the sender-side unified diff
   - `api-delta.md` — added/changed/removed endpoints (when a Swagger spec is configured)
   - `package.json` — raw package data including targeting hints

3. **Follow the prompt to integrate**:
   - Treat the targeting hints (`suggest_edit` / `suggest_create` paths) as starting points, not gospel — verify against the actual repo conventions.
   - Read existing similar files (e.g. neighboring entries in `lib/api/` or `types/`) before writing new ones, so your additions match house style.
   - Honor any "禁止 / forbidden" rules in the local CLAUDE.md.

4. When done, summarize what you changed (files touched, types added, breaking changes propagated) so the user can review.

<!-- cc-handoff-version: 0.1.0 -->
