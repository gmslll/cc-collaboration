---
description: Turn a Linear issue into a cc-handoff request and send it to the partner.
---

You're starting from a Linear issue (the user gave you an issue identifier like `ENG-123`) and want to materialize it as a cc-handoff `request` so the partner (typically backend) picks it up via `/pickup` and implements.

This is the **inbound** half of the Linear integration:
- The user already created the issue in Linear with the product context.
- You're going to read it, convert it into a properly structured cc-handoff request, and back-link the resulting handoff_id into the Linear issue so future events can sync.

**Prerequisites** (don't proceed unless these are true; tell the user and stop):
- A Linear MCP server is configured for this Claude Code install (you can see `mcp__linear__*` tools, or whatever prefix `integrations.linear.mcp_prefix` is set to). If you can't find the Linear MCP tools, ask the user to install/configure their Linear MCP server first.
- The cc-handoff MCP server is configured (you can see `mcp__cc-handoff__*` tools).
- `.cc-handoff.toml` has `[integrations.linear]` with `enabled = true`.

## Steps

1. **Parse the input.** The user typed something like `/handoff-from-linear ENG-123` or `/handoff-from-linear https://linear.app/team/issue/ENG-123/...`. Extract the issue identifier (`ENG-123` form). If the user didn't supply one, ask for it.

2. **Read the Linear issue.** Use `mcp__linear__get_issue` (or the equivalent under the configured prefix) to fetch:
   - title
   - description (markdown body)
   - state
   - labels
   - priority
   - the most recent ~5 comments (they often carry product clarifications)
   - URL

   If the issue is already in a "Done" / "Cancelled" state, ask the user to confirm they still want to send a handoff (probably stale).

3. **Check for existing binding.** Scan the issue description for an HTML comment of the form `<!-- cc-handoff: h_YYYYMMDD_XXXXXXXX -->`. If found, this issue **already has** an associated handoff. Tell the user, show the existing handoff_id, and ask whether they want to:
   - (a) abort — the existing request still stands
   - (b) send a follow-up using `responds_to=<existing-id>` (amendment / clarification)
   - (c) force-create a new one anyway (they explicitly say so)

   Default to (a). Only proceed past this step if the user picks (b) or (c).

4. **Compose the cc-handoff request summary.** Build a Markdown body containing:
   - **What's needed** — extracted from issue title + description, written in cc-handoff request style (endpoint + field-level specifics, not vague). Cite the Linear issue URL at the top.
   - **Why** — the product/business context from the description and PRD section (if any).
   - **Acceptance** — what "done" looks like; pull from "Acceptance Criteria" section of the issue if present, else derive from the description.
   - **Source** — at the very end, a line: `Linear: <ENG-123> · <URL>` so future readers can trace back.

   Do **not** invent acceptance criteria the issue didn't actually contain. If the issue is vague, say so explicitly in the summary instead of filling in details.

5. **Ask about PRD and note.** Same as `/request`:
   - Ask whether there's a separate PRD doc to attach as `prd`. Often the Linear issue description IS the PRD — if so, skip this question.
   - Ask whether there are cross-end constraints to add as `note` (e.g. "don't break existing callers", "field naming follows X convention"). Default no.

6. **Submit the request.** Call `mcp__cc-handoff__submit_request` with:
   - `summary`: the markdown from step 4
   - `prd`: from step 5 if user provided one
   - `note`: from step 5 if user provided one
   - `urgent: true`: only if the Linear issue is `Urgent` priority AND the user confirms (don't auto-promote based on priority alone)

   Capture the returned `handoff_id` (looks like `h_20260512_ABCD1234`).

7. **Back-link into Linear.** Update the issue so the binding is recoverable:
   - Use `mcp__linear__update_issue` to append to the issue description:
     ```

     <!-- cc-handoff: <handoff_id> -->
     ```
     (Two newlines + the HTML comment. Don't rewrite the existing description — append only.)
   - Use `mcp__linear__create_comment` to post:
     ```
     Sent to partner via cc-handoff: `<handoff_id>`. Partner will pick this up and respond.
     ```

8. **Record locally.** Call `mcp__cc-handoff__link_linear` with:
   - `handoff`: the returned handoff_id from step 6
   - `issue`: the Linear issue identifier (e.g. `ENG-123`)
   - `url`: the Linear issue URL from step 2

   This writes the binding to `<inbox-dir>/sent/<handoff_id>/linear.json` so `status_handoff` and future sync prompts can read it without round-tripping Linear.

9. **Report back.** Tell the user:
   - The new handoff id
   - The Linear issue it's linked to
   - That the partner will pick it up via `/pickup` and the eventual delivery will carry `responds_to=<this id>`

Stop after step 9. Don't try to do anything else (don't implement, don't speculate about the partner's implementation).

<!-- cc-handoff-version: 0.1.1 -->
