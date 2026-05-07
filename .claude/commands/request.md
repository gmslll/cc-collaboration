---
description: Send a feature/field/endpoint request from this side to the configured partner via cc-handoff.
---

You found something the partner needs to add or change — a missing field, a missing endpoint, a broken response shape, an ability that's not exposed. Compose the request and send it.

This command is the **reverse** of `/handoff`. There's no diff to ship; the summary IS the request body. The partner picks it up via `/pickup`, designs/implements, then handoffs back to you with `responds_to=<this id>` so you can close the loop.

1. Read the relevant local code (component / hook / API client / call site) to understand exactly what's missing or wrong, and **be specific to the endpoint and field**. Don't guess at the partner's implementation.

2. Compose a Markdown summary containing:
   - **What's needed** — endpoint + field-level specifics. e.g. "`GET /api/v1/orders` is missing `customer_phone` (string, optional) on each row" not "we need phone info".
   - **Why** — what you're trying to do with it; why the current contract is insufficient.
   - **Acceptance** — what "done" looks like from your side: response schema, status codes, error handling expectations.

3. **询问跨端约束**。在调 `submit_request` 之前，明确问用户一次：
   > 有要给后端备注的约束或前提吗？例如「不要破坏现有调用方」「字段命名跟 X 一致」「兼容现存数据」「不要顺手重构 module Y」。没有就回 `没有` 或 `n`。

   **例外**：如果用户在原始 `/request` 指令里已经写明了备注，跳过这一问，直接采用用户那段话作为备注。

   把用户给的备注（如有）按原文整理成 Markdown，作为 `note` 参数传给 `submit_request`。备注会以「⚠️ 发起方备注 / 跨端约束 (必读)」段渲染到接收端 prompt，被要求逐条响应。

4. 调 `submit_request` MCP 工具：
   - `summary`: 第 2 步的 Markdown 总结
   - `note`: 第 3 步的备注（没有就不传）
   - `urgent: true`：仅当用户明确说紧急 / 「让对方现在就开始」时

5. Report back the request id and recipient. Tell the user the partner will pick this up via `/pickup` and the eventual delivery will carry `responds_to=<this id>`.

Do **not** propose backend implementation details — that's the receiving Claude's job after pickup. Stick to "what I need and why"; let them figure out "how". And **do not invent fields or endpoints the user didn't actually ask for** — if the user said "没有" / "n" 没回复约束，就不传 note。

<!-- cc-handoff-version: 0.1.0 -->
