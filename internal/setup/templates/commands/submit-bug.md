---
description: Report a bug from the test/QA side to one or both engineering sides via cc-handoff; receivers walk a decision tree (fix / reassign / discuss).
---

You're the tester end. You found a bug while testing the product. Send it to backend, frontend, or both at once; the receivers will judge ownership and either fix it directly or call `reassign_bug` to forward it to the other side. Comments stay synced across the bug group so you don't have to relay messages by hand.

This command is different from `/handoff` (sender just finished work) and `/request` (sender needs a feature). `/submit-bug` is "**something is broken, figure out which side and fix it**".

1. **Pin down the symptom**. Don't just say "it's broken" — describe **what page / endpoint / flow** and **what you saw vs. what you expected**.

2. **Compose the bug summary in Markdown**:
   - **Symptom** — the visible/observable problem in one or two sentences.
   - **Reproduction** — numbered steps the receiver can follow verbatim. Include URL/env/account if relevant.
   - **Expected** — what should happen.
   - **Actual** — what does happen. Include the literal error message / wrong value if applicable.
   - **Suspected ownership** (optional) — if you have a hunch ("`createdAt` is camelCase from the API but the frontend mapper looks for `created_at`"), write it. **It's a hunch, not a verdict** — the receivers will read code and decide.

3. **决定发给谁**。问用户一次:
   > 这个 bug 你觉得发给谁?
   > - 不确定/可能是两边 → `both`(同时发给 backend 和 frontend,先到的判定归属再决定修/转)
   > - 明确是后端 → `backend`
   > - 明确是前端 → `frontend`
   > - 其他 → 直接写身份名(对应 `.cc-handoff.toml` 里 `identity.partners` 配的那些)

   **例外**:用户在原始 `/submit-bug` 指令里已经写了 `to:backend` / `to:both` 之类的就跳过这一问。

   把结果转成数组传给 `to` 参数:`both` → `["backend", "frontend"]`,单边 → `["<side>"]`。如果用户回"用默认",省略 `to` 参数(MCP 工具会自动用 `identity.partners`)。

4. **询问验收标准 / 测试备注**。在调 `submit_bug` 之前问一次:
   > 有要给开发的验收标准或硬约束吗?例如「修完后这个 case 必须通过自动化用例」「不要顺手改 X 模块」「字段不能改名(影响别的调用方)」。没有就回 `没有` 或 `n`。

   **例外**:如果用户在原始 `/submit-bug` 指令里已经写明了备注,跳过这一问,直接采用用户那段话作为备注。

   把用户给的备注(如有)按原文整理成 Markdown,作为 `note` 参数传给 `submit_bug`。备注会以「⚠️ 测试备注 / 验收标准 (必读)」段渲染到接收端 prompt,被要求逐条响应。

5. **询问产品需求 / 设计意图 (可选 PRD)**。仅当用户在原始指令里提到产品文档,或这个 bug 涉及到产品意图理解(不只是技术 bug)时才问:
   > 有产品需求文档或设计意图要带过去吗?能帮接收端判断这个 bug 的优先级和影响面。三种方式都行:
   > - **文件路径**(如 `docs/prd/feature-x.md`)
   > - **直接粘贴文本**
   > - **口头描述** —— 我帮你整理成 markdown

   没有就跳过。处理方式跟 `/request` 一致:不要伪造、不要扩写。

6. **询问附件**。在调 `submit_bug` 之前问一次:
   > 有截图 / HAR / 控制台日志 / 录屏 想随 bug 带过去吗?给我文件路径(绝对路径或相对当前 cwd 都行),用逗号或换行分开多个。没有就回 `没有` 或 `n`。

   **例外**:如果用户在原始 `/submit-bug` 指令里写明了截图路径(例如 `attach:~/Desktop/x.png`),直接采用,不要再问。

   把路径数组传给 `attachment_paths` 参数。MCP 工具会读取文件并随 handoff 上传,接收端 pickup 时文件落到 `.cc-handoff/inbox/<id>/attachments/`,prompt 顶部「📎 附件」段会列出来,指引接收端 AI 用 Read 工具打开它们辅助判定归属。**不要伪造路径** —— 用户说没有就是没有。

7. 调 `submit_bug` MCP 工具:
   - `summary`: 第 2 步的 Markdown 总结
   - `to`: 第 3 步的数组(没指定就省略,用默认)
   - `note`: 第 4 步的备注(没有就不传)
   - `prd`: 第 5 步的产品需求(没有就不传)
   - `attachment_paths`: 第 6 步的路径数组(没有就不传)
   - `urgent: true`:仅当用户明确说"现在就要修"/"阻塞了线上"时

8. Report back the bug id, the recipients, and remind the user:
   - 每个收件人 `/pickup` 后会看到归属判断决策树(修 / reassign / 协商)+ 你贴的附件
   - 整个 bug_group 内的评论会自动同步给三方,不需要人肉中转
   - 用 `status_handoff <id>` 看每端 pickup 状态(谁还没读 / 谁已读 / 谁已转交)
   - 用 `list_sent` 看你发出的所有 bug 的当前状态

Do **not** propose root causes or fixes —— that's the receivers' job after they read code。Stick to "what I saw, how to reproduce, what I expected"。And **do not invent reproduction steps, error messages, or acceptance criteria the user didn't actually give you** —— 用户说没有就是没有,note 和 prd 都不要伪造。
