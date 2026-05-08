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

3. **询问产品需求 / 设计意图 (PRD)**。在询问 note 之前先问一次：
   > 有产品给前端的需求文档或设计意图想一起带过去吗？后端拿到这层 why 设计会更贴产品意图。三种方式都行：
   > - **文件路径**（如 `docs/prd/feature-x.md`）—— 我用 Read 读完整内容
   > - **直接粘贴文本** —— 你把内容贴进来
   > - **口头描述** —— 你用自然语言说，我帮你整理成 markdown
   >
   > 没有就回 `没有` / `n`。

   **例外**：如果用户在原始 `/request` 指令里已经写明 PRD 来源（例如 `/request prd:docs/prd/feat-x.md`），跳过这一问。

   处理方式：
   - 文件路径：用 Read 读取完整内容；路径不存在让用户确认，**不要伪造**
   - 粘贴文本：直接采用用户原文
   - 口头描述：整理成结构化 markdown，但**忠实复述**用户表达，不要替产品扩写需求或加入用户没说的细节

   把结果作为 `prd` 参数传给 `submit_request`。PRD 会以「📋 产品需求 / 设计意图 (背景参考)」段渲染到接收端 prompt，**作为背景参考阅读，不要求逐条响应**（区别于 note 的「必读 / 逐条响应」语义）。

4. **询问跨端约束**。在调 `submit_request` 之前，明确问用户一次：
   > 有要给后端备注的约束或前提吗？例如「不要破坏现有调用方」「字段命名跟 X 一致」「兼容现存数据」「不要顺手重构 module Y」。没有就回 `没有` 或 `n`。

   **例外**：如果用户在原始 `/request` 指令里已经写明了备注，跳过这一问，直接采用用户那段话作为备注。

   把用户给的备注（如有）按原文整理成 Markdown，作为 `note` 参数传给 `submit_request`。备注会以「⚠️ 发起方备注 / 跨端约束 (必读)」段渲染到接收端 prompt，被要求逐条响应。

5. 调 `submit_request` MCP 工具：
   - `summary`: 第 2 步的 Markdown 总结
   - `prd`: 第 3 步的产品需求（没有就不传）
   - `note`: 第 4 步的备注（没有就不传）
   - `urgent: true`：仅当用户明确说紧急 / 「让对方现在就开始」时

6. Report back the request id and recipient. Tell the user the partner will pick this up via `/pickup` and the eventual delivery will carry `responds_to=<this id>`.

Do **not** propose backend implementation details — that's the receiving Claude's job after pickup. Stick to "what I need and why"; let them figure out "how". And **do not invent fields, endpoints, or product intent the user didn't actually give you** — 用户说没有就是没有，note 和 prd 都不要伪造。

<!-- cc-handoff-version: 0.1.1 -->
