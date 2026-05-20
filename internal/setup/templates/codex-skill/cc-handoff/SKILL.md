---
name: cc-handoff
description: Use when the user wants to send, receive, request, or triage cc-handoff work in Codex; triggers include handoff, pickup, request, submit-bug, handoff-from-linear, API handoff, integration handoff, or cross-agent collaboration.
---

# cc-handoff

Use this skill to run cc-handoff workflows from Codex. The stable integration path is the `cc-handoff` MCP server tools, not Codex slash commands.

## Workflow Selection

- For sending current backend/API work to a partner, follow `references/handoff.md`.
- For sending an already-merged module/API contract brief, follow `references/handoff-module.md`.
- For picking up a pending partner handoff, follow `references/pickup.md`.
- For requesting a missing field/endpoint/capability from a partner, follow `references/request.md`.
- For turning a Linear issue into a partner request, follow `references/handoff-from-linear.md`.
- For reporting a QA/test bug to one or more engineering sides, follow `references/submit-bug.md`.

## Rules

- Read only the relevant reference file for the requested workflow before acting.
- Use the `cc-handoff` MCP tools directly: `submit_handoff`, `pickup_handoff`, `submit_request`, `submit_bug`, `reassign_bug`, `comment_handoff`, `status_handoff`, `list_sent`, `list_inbox`, `check_drift`, and related tools.
- Do not invent API contracts, product intent, recipients, attachments, or Linear bindings. Ask when the selected workflow requires user input.
- If the user uses old slash-command wording in natural language, such as "run handoff" or "do pickup", map it to the matching reference workflow.

<!-- cc-handoff-version: dev -->
