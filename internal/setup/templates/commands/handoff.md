---
description: Package the current branch's work and send it to the configured partner via cc-handoff.
---

You just finished writing or modifying an API. Hand it off to the frontend partner.

1. Read recent diffs and your conversation context to understand what changed: routes added/modified, request/response shapes, error codes, gotchas, things the partner needs to know to integrate.

2. Compose a Markdown summary containing:
   - **What changed** — bullet list of endpoints added/modified/removed
   - **Contract** — for each new endpoint: method, path, query/body params, response shape, error codes
   - **Notes** — non-obvious behavior, migration steps, deadlines, breaking changes

3. **询问产品需求 / 设计意图 (PRD)**。在询问 note 之前先问一次：
   > 有产品需求文档或设计意图想一起带过去吗？前端拿到这层 why 集成会更准。三种方式都行：
   > - **文件路径**（如 `docs/prd/feature-x.md`）—— 我用 Read 读完整内容
   > - **直接粘贴文本** —— 你把内容贴进来
   > - **口头描述** —— 你用自然语言说，我帮你整理成 markdown
   >
   > 没有就回 `没有` / `n`。

   **例外**：如果用户在原始 `/handoff` 指令里已经写明 PRD 来源（例如 `/handoff prd:docs/prd/feat-x.md` 或 `/handoff prd:"产品要求 ..."`），跳过这一问，按用户给的来源直接处理。

   处理方式：
   - 文件路径：用 Read 读取完整内容；路径不存在让用户确认，**不要伪造**
   - 粘贴文本：直接采用用户原文
   - 口头描述：整理成结构化 markdown，但**忠实复述**用户表达，不要替产品扩写需求或加入用户没说的细节

   把结果作为 `prd` 参数传给 `submit_handoff`。PRD 会以「📋 产品需求 / 设计意图 (背景参考)」段渲染到接收端 prompt，**作为背景参考阅读，不要求逐条响应** —— 这是它和 note 的区别：note 是硬约束必读，prd 是 why 参考。

4. **询问跨端需求 / 约束**。在调 `submit_handoff` 之前，明确问用户一次：
   > 有要给前端备注的需求或约束吗？例如错误码对照、字段大小写规则、分页默认值、UI 上不能合并的请求、特定字段的展示格式等。没有就回 `没有` 或 `n`。

   **例外**：如果用户在原始 `/handoff` 指令里已经写明了备注（例如 `/handoff 备注：分页默认 20 条不可改` 或 `/handoff 提醒前端字段必须大写`），跳过这一问，直接采用用户那段话作为备注，不要再确认。

   把用户给的备注（如有）按原文整理成 Markdown，作为 `note` 参数传给 `submit_handoff`。备注会以「⚠️ 后端备注 / 需求 (必读)」段渲染到接收端 prompt，并被强制要求 INTEGRATION.md 逐条响应。

5. 调 `submit_handoff` MCP 工具：
   - `summary`: 第 2 步的 Markdown 总结
   - `prd`: 第 3 步的产品需求（没有就不传）
   - `note`: 第 4 步的需求备注（没有就不传）
   - `urgent: true`：仅当用户明确说紧急 / 「让对方现在就开始」时

6. Report back the handoff id, recipient, and the targeting hints / api_delta counts shown in the tool's response.

Do **not** invent endpoints you didn't actually implement. Use only what's in git diff and your session memory. **Do not invent requirements or product intent either** — if the user said "没有" / "n"，就不传 note；PRD 同理，没有就不传 prd。
