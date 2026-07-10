---
description: Package the current branch's work and send it to the current team project via cc-handoff.
---

You just finished writing or modifying an API. Hand it off to the frontend partner.

1. Read recent diffs and your conversation context to understand what changed: routes added/modified, request/response shapes, error codes, gotchas, things the partner needs to know to integrate.

2. **契约自检（关键）** —— 在动手写 summary 前，逐条过下面的清单。每条都要么能直接从 diff / 代码答上来，要么去补读代码答上来，要么在最后的 summary 里明确标 `TODO: 待确认` 并在调 `submit_handoff` 之前问用户。**不要凭直觉跳过**——前端拿到 handoff 后最多的来回问就来自这几个点：

   - **每个新增 / 修改的字段**：是必填还是可选？类型是什么？旧客户端不传它的兜底是什么？老字段被改类型 / 改语义了吗？
   - **每个新增 / 修改的 endpoint**：它是替代了某个旧 endpoint 吗？如果是，旧的还能调多久（deprecation 窗口）？
   - **错误码**：HTTP code + 业务 code，每个对前端 UI 的预期是什么（toast / 表单内联 / 跳登录 / 全局 banner / 静默重试）？
   - **分页 / 排序 / 过滤**：默认值是什么？上下限？cursor 还是 offset？空集时返回什么？
   - **字段命名 / 类型可能的冲突**：列出 2-3 个最可能跟前端已有 TS 类型同名但语义不同的字段（金额单位、时间格式、ID 长度等）。
   - **副作用与时序**：调用这个 endpoint 之后，前端是否要重新拉别的数据？有没有需要前端处理的竞态？

   答案直接合并进下一步的 summary 的 **Contract** 与 **Notes** 段；硬性跨端约束塞进步骤 5 的 note。**不要单独写一份独立自检文档**。

3. Compose a Markdown summary containing:
   - **What changed** — bullet list of endpoints added/modified/removed
   - **Contract** — for each new endpoint: method, path, query/body params, response shape, error codes
   - **Notes** — non-obvious behavior, migration steps, deadlines, breaking changes

4. **询问产品需求 / 设计意图 (PRD)**。在询问 note 之前先问一次：
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

5. **询问跨端需求 / 约束**。在调 `submit_handoff` 之前，明确问用户一次：
   > 有要给前端备注的需求或约束吗？例如错误码对照、字段大小写规则、分页默认值、UI 上不能合并的请求、特定字段的展示格式等。没有就回 `没有` 或 `n`。

   **例外**：如果用户在原始 `/handoff` 指令里已经写明了备注（例如 `/handoff 备注：分页默认 20 条不可改` 或 `/handoff 提醒前端字段必须大写`），跳过这一问，直接采用用户那段话作为备注，不要再确认。

   把用户给的备注（如有）按原文整理成 Markdown，作为 `note` 参数传给 `submit_handoff`。备注会以「⚠️ 后端备注 / 需求 (必读)」段渲染到接收端 prompt，并被强制要求 INTEGRATION.md 逐条响应。

6. **判断是不是「修正交付」**:如果本次改动是对**之前已经发过的某次 handoff** 的接口做修正(改了之前送出的 endpoint 的字段 / 类型 / 错误码,或者整合方案需要前端重做),需要带 `amends` 参数告诉前端「这是补丁,不是新交付」。

   - 怎么知道有没有上次?跑 `list_sent` MCP 工具看自己最近发出的 handoff id;或者用户在 `/handoff` 指令里直接告诉了上次的 id(例如 `/handoff amends:h_20260507_ABCD1234`)。
   - 如果不确定或者明显是全新 endpoint,**不传**这个参数。`amends` 不是默认值。
   - 区别于 `responds_to`:`responds_to` 是「我在回应你之前发的 request」,`amends` 是「我之前发过的 handoff 这次要改」。

7. **询问附件 (可选)**:如果这次交付想随包带 UI 截图 / 设计稿 / 错误响应截图等给前端,问用户一次:
   > 有 UI 截图 / 设计稿 / 任何想随交付带过去的文件吗?给我路径(绝对或相对 cwd 都行),用逗号或换行分开多个。没有就回 `没有` 或 `n`。

   把路径数组传给 `attachment_paths` 参数。**不要伪造路径** —— 用户说没有就不传。

8. 调 `submit_handoff` MCP 工具：
   - `summary`: 第 3 步的 Markdown 总结（已经把第 2 步自检的产物吸收进 Contract / Notes 段）
   - 默认发给当前 workspace/repo 绑定的团队项目；如果用户明确要求「发给项目/团队/所有相关成员」，传 `project`（cc-handoff 项目 id）或 `org`（组织 id），不要再传 `to`；如果用户明确指定团队里的某个人，同时传 `member`（真实 identity）。只有用户明确要求旧点对点发送时才传 `to`
   - `prd`: 第 4 步的产品需求（没有就不传）
   - `note`: 第 5 步的需求备注（没有就不传）
   - `amends`: 第 6 步判断的上次 handoff id(只在确实是修正交付时传)
   - `attachment_paths`: 第 7 步的路径数组(没有就不传)
   - `urgent: true`：仅当用户明确说紧急 / 「让对方现在就开始」时

9. Report back the handoff id, recipient, and the targeting hints / api_delta counts shown in the tool's response.

Do **not** invent endpoints you didn't actually implement. Use only what's in git diff and your session memory. **Do not invent requirements or product intent either** — if the user said "没有" / "n"，就不传 note；PRD 同理，没有就不传 prd。
