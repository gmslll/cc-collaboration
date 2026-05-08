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

## 3. Compose the brief (Markdown, 中文)

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

## 4. 询问产品需求 / 设计意图 (PRD)

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

## 5. 询问跨端需求 / 约束

调 `submit_handoff` 之前,明确问用户一次:

> 有要给前端备注的需求或约束吗?例如错误码对照、字段大小写规则、分页默认值、UI 上不能合并的请求、特定字段的展示格式等。没有就回 `没有` 或 `n`。

**例外**:如果用户在原始 `/handoff-module` 指令里已经写明了备注(例如 `/handoff-module internal/module/oms/order 备注:分页默认 50 条`),跳过这一问,直接采用用户那段话作为备注,不要再确认。

## 6. Submit

调 `submit_handoff` MCP 工具:
- `summary`: 第 3 步的完整 brief Markdown(始终传 — 不依赖磁盘 draft)
- `module_paths`: 用户给的模块路径数组,与磁盘上一致
- `prd`: 第 4 步的产品需求(用户回 `没有` / `n` 就不传)
- `note`: 第 5 步的需求备注(用户回 `没有` / `n` 就不传)
- `urgent: true`:仅当用户明确说紧急时

## 7. Report back

打印:handoff id、recipient、包含的模块、targeting_hints 数量。

Do **not** invent endpoints you couldn't ground in real route registrations. If the brief feels thin, that's a signal you need to read more files, not a signal to fill in plausible-looking content. **Do not invent requirements or product intent either** — `没有` 就是没有,note 和 prd 都不要伪造。

<!-- cc-handoff-version: 0.1.1 -->
