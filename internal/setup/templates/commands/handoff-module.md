---
description: Compose a self-contained API brief for one or more existing backend modules and hand it off to the frontend partner.
---

You are pushing a frontend-integration brief for already-merged backend modules — there's no recent diff to read. The user names one or more module paths; you read the module(s) and produce a complete API contract document, then hand it off via cc-handoff in module mode.

The user's invocation may look like:
- `/handoff-module internal/module/oms/order`
- `/handoff-module internal/module/oms/order internal/module/tracking`
- `/handoff-module internal/module/oms/order 备注:分页默认 50 条`

## 1. Confirm module paths

Parse the user's message for one or more relative paths under the repo root. For each:
- Verify it exists (Read on the directory). If a path doesn't exist, ask the user to correct it. Do not guess.
- Verify it looks like a backend module (contains some of `handler/` `dto/` `service/` `routes.go` etc). If unsure, ask the user to confirm before proceeding.

If the user gave nothing, ask: 「要为哪个模块生成 API brief?例如 `internal/module/oms/order`。多个模块用空格分隔。」

## 2. Read the module(s)

For each module path, methodically read:
- All `routes.go` / route registration files in `<module>/handler/` — these enumerate the endpoints (method + path + handler func).
- The `HTTPHandler` / handler struct file(s) — these reveal request binding, auth middleware, response shape.
- All files under `<module>/dto/` — request/response DTOs, including JSON tags and validation tags.
- If `docs/swagger.yaml` (or whatever `paths.swagger` is configured to) exists in this repo, search it for paths that belong to this module and read those entries to cross-check.

**Don't read every file.** Service / repository / aggregator layers are usually overkill for an API brief — but skim if a route handler delegates business logic that affects the response shape (computed fields, side effects worth flagging).

**Anti-hallucination guardrails**:
- Every endpoint you list must be backed by a real route registration you read. If you can't find it, don't list it.
- Every field in a request/response shape must come from a DTO you read. If a field's semantics are unclear, mark it `// TODO: confirm with backend` rather than inventing.
- Method + path must match exactly what the handler registers. No "probably POST" guesses.

## 3. 契约自检 — 反推前端疑问（关键）

读完模块后、动手写 brief 前，逐条过下面的清单。这是从「前端会怎么用这个模块」回看你的契约描述是否完整。每条都要么能直接从代码 / swagger 答上来，要么去补读代码答上来，要么在写 brief 时显式标出「未确认」并问用户。**不要凭直觉跳过**——前端拿到 brief 后最多的来回问就来自这几个点：

- **每个 endpoint 的字段必填性**：每个字段是必填还是可选？类型是什么？看 DTO 的 `validate` tag 和 JSON tag 的 `omitempty`，不要靠猜。
- **错误码**：handler 里实际会返回哪些 HTTP code + 业务 code？每个对前端 UI 的预期是什么（toast / 表单内联 / 跳登录 / 全局 banner / 静默重试）？业务码如果是数字，**列出实际值**。
- **endpoint 之间的关系**：模块里多个 endpoint 之间有没有「次序约束」（必须先调 A 再调 B）、「替代关系」（新版替代旧版）、「资源链」（A 返回 ID 给 B 用）？前端是要全调还是按需调？
- **跨模块依赖**：如果一个 endpoint 返回的 ID / 引用指向另一个模块，明确说出来（例如「`order.customer_id` 对应 `internal/module/customer` 的 ID 体系」），别让前端自己猜。
- **分页 / 排序 / 过滤**：默认值是什么？上下限？cursor 还是 offset？空集时返回什么？排序键有哪些？
- **字段命名 / 类型可能的冲突**：列出 2-3 个最容易被前端误用的字段（金额单位是分还是元？时间是 RFC3339 string 还是 Unix ms？ID 是 uuid 还是数据库自增？大小写？）。
- **副作用与时序**：调用这个 endpoint 之后，是否会触发异步任务、消息推送、缓存失效？前端是要轮询还是接 webhook 还是直接展示乐观更新？
- **多租户 / 权限隔离**：同一个 endpoint 在不同租户 / 角色下返回的字段集合是否一致？

把答案合并进下一步的 brief —— 字段必填性进 **请求体 / 响应**，错误码进 **响应**，关系与跨模块依赖进 **集成提示**，命名冲突也进 **集成提示**。**不要单独写一份独立自检文档**。

## 4. Compose the brief (Markdown, 中文)

Structure (one `# 模块 API Brief: <name>` block per module — do not merge endpoint tables across modules):

```
# 模块 API Brief: <module name>

## 模块概览
1-3 段说清这个模块做什么、归属什么业务域、有什么前置依赖(如认证模式、租户隔离、特殊 header)。

## 鉴权 / 通用约束
- 鉴权方式(哪个 middleware)
- 通用错误码 / 响应包装格式
- 分页 / 排序 / 过滤约定(如有)

## API 列表
快速索引:方法 + 路径 + 一句话说明。

## Endpoint 契约
每个 endpoint 一个 H3:

### POST /api/v1/orders
- **作用**:...
- **鉴权**:...
- **Path / Query 参数**:每个参数 name、类型、必填、说明
- **请求体**:每个字段 name、JSON 类型、必填、约束(来自 validate tag)、说明
- **响应**:成功 shape;典型错误码及 message
- **后端文件**:`internal/module/oms/order/handler/http.go:NewOrderRoutes`、`internal/module/oms/order/dto/request.go:CreateOrderRequest`(让前端能溯源)

## 集成提示 (面向前端)
非显然的对接注意点。例如:「列表接口分页基于 cursor 而不是 offset」「金额单位是分」「时间字段是 RFC3339 string」「同一个 endpoint 在不同租户下返回字段集合不同」等。
```

## 5. 询问产品需求 / 设计意图 (PRD)

在询问 note 之前先问一次:

> 有产品需求文档或设计意图想一起带过去吗?前端拿到这层 why 集成会更准。三种方式都行:
> - **文件路径**(如 `docs/prd/feature-x.md`)—— 我用 Read 读完整内容
> - **直接粘贴文本** —— 你把内容贴进来
> - **口头描述** —— 你用自然语言说,我帮你整理成 markdown
>
> 没有就回 `没有` / `n`。

**例外**:如果用户在原始 `/handoff-module` 指令里已经写明 PRD 来源(例如 `/handoff-module internal/module/oms/order prd:docs/prd/order.md`),跳过这一问,按用户给的来源直接处理。

处理方式:
- 文件路径:用 Read 读取完整内容;路径不存在让用户确认,**不要伪造**
- 粘贴文本:直接采用用户原文
- 口头描述:整理成结构化 markdown,但**忠实复述**用户表达,不要替产品扩写需求或加入用户没说的细节

把结果作为 `prd` 参数传给 `submit_handoff`。PRD 会以「📋 产品需求 / 设计意图 (背景参考)」段渲染到接收端 prompt,**作为背景参考阅读,不要求逐条响应** —— 这是它和 note 的区别:note 是硬约束必读,prd 是 why 参考。

## 6. 询问跨端需求 / 约束

调 `submit_handoff` 之前,明确问用户一次:

> 有要给前端备注的需求或约束吗?例如错误码对照、字段大小写规则、分页默认值、UI 上不能合并的请求、特定字段的展示格式等。没有就回 `没有` 或 `n`。

**例外**:如果用户在原始 `/handoff-module` 指令里已经写明了备注(例如 `/handoff-module internal/module/oms/order 备注:分页默认 50 条`),跳过这一问,直接采用用户那段话作为备注,不要再确认。

## 7. 判断是不是「修正交付」

如果本次 brief 是对**之前已经发过的某次模块 handoff** 的修正(模块里有 endpoint 改了字段 / 类型 / 错误码,或者前端那边的整合方案需要重做),需要带 `amends` 参数告诉前端「这是补丁,不是新交付」。

- 怎么知道有没有上次?跑 `list_sent` MCP 工具看自己最近发出的 handoff id;或者用户在 `/handoff-module` 指令里直接给了上次的 id(例如 `/handoff-module internal/module/oms/order amends:h_20260507_ABCD1234`)。
- 如果是首次为某模块出 brief,**不传**这个参数。`amends` 不是默认值。
- 区别于 `responds_to`:`responds_to` 是「我在回应你之前发的 request」,`amends` 是「我之前发过的 handoff 这次要改」。

## 8. Submit

调 `submit_handoff` MCP 工具:
- `summary`: 第 4 步的完整 brief Markdown(已经把第 3 步自检的产物吸收进契约 / 集成提示;始终传 — 不依赖磁盘 draft)
- `module_paths`: 用户给的模块路径数组,与磁盘上一致
- 默认发给配置里的 partner；如果用户明确要求「发给项目/团队/所有相关成员」，传 `project`（cc-handoff 项目 id）或 `org`（组织 id），不要再传 `to`；如果用户明确指定团队里的某个人，同时传 `member`（真实 identity）
- `prd`: 第 5 步的产品需求(用户回 `没有` / `n` 就不传)
- `note`: 第 6 步的需求备注(用户回 `没有` / `n` 就不传)
- `amends`: 第 7 步判断的上次 handoff id(只在确实是修正交付时传)
- `urgent: true`:仅当用户明确说紧急时

## 9. Report back

打印:handoff id、recipient、包含的模块、targeting_hints 数量。

Do **not** invent endpoints you couldn't ground in real route registrations. If the brief feels thin, that's a signal you need to read more files, not a signal to fill in plausible-looking content. **Do not invent requirements or product intent either** — `没有` 就是没有,note 和 prd 都不要伪造。
