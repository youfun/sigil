# Sigil 接入 OpenAI Codex Responses API 可行性分析

> 基于 `pi-codex-conversion` 的架构对比与 Sigil 落地建议

---

## 一、现状：Sigil 的 Provider 架构

Sigil 当前通过 `Provider` 协议抽象模型调用，核心模块：

```
lib/sigil/agent/
├── provider.ex          # 行为定义（complete/stream/embed）
├── providers/           # 各 provider 实现
│   ├── openai.ex        # OpenAI (Chat Completions API)
│   ├── anthropic.ex     # Anthropic (Messages API)
│   ├── xai.ex           # xAI (Chat Completions API)
│   ├── custom_openai.ex # 自定义 OpenAI（兼容第三方端点）
│   └── ...
└── streaming/           # 流式中间件
    └── openai.ex
```

**关键发现**：
- `OpenAI` provider 调用的是 **Chat Completions API**（`/v1/chat/completions`）
- `CustomOpenAI` 同样基于 Chat Completions 格式
- **没有 Responses API 支持**
- 流式解析走 `OpenAI.Streaming`，只处理 `delta` 事件
- 没有 `reasoning` / `thinking` / `text_signature` 概念
- 没有 `function_call_output` 格式
- **没有 WebSocket 传输层**

---

## 二、Responses API 与 Chat Completions 的核心差异

| 维度 | Chat Completions | Responses API |
|------|-----------------|---------------|
| **端点** | `POST /v1/chat/completions` | `POST /v1/responses` |
| **流式** | SSE（`/v1/chat/completions`） | SSE（`/v1/responses`）**+ WebSocket** |
| **Reasoning** | `thinking` extension（部分模型） | 原生 `reasoning` item type |
| **Tool Call** | `tool_calls`（message item） | `function_call` item（独立 item） |
| **Tool Result** | `tool_message` role | `function_call_output` item |
| **Image** | `image_url` / base64 content | `image_generation_call` item |
| **Web Search** | `web_search` extension | 原生 `web_search` tool + output items |
| **Continuation** | N/A（每轮独立） | `previous_response_id` 续传 |
| **Codex CLI 集成** | ❌ | ✅（Codex 格式原生支持） |

**结论**：要支持 Codex CLI 格式的推理产物、原生工具调用、WebSocket 流，必须实现 Responses API 适配。

---

## 三、Sigil 架构优势 vs pi-codex-conversion

| 对比维度 | pi-codex-conversion | Sigil |
|---------|---------------------|-------|
| **状态管理** | Pi 的内部 session（黑盒） | Agent Runtime（完整的 Agent Loop + State + Session） |
| **中间件层** | ❌（Pi hook 点有限） | ✅ `Middleware` 协议，可插入任意处理逻辑 |
| **权限控制** | ❌ | ✅ `ToolGuard` + `WorkspacePermissions` |
| **MCP 生态** | ❌ | ✅ MCP Runtime + Plugin Bridge |
| **审计/追踪** | ❌ | ✅ `EventRecorder` + `TranscriptPersistence` |
| **语言** | TypeScript（单文件 ~700 行 provider） | Elixir/BEAM（结构化、OTP 监督树） |
| **错误处理** | 局部 try-catch | Supervisor 重启 + Circuit Breaker + 降级 |
| **测试** | 有，但无 E2E 覆盖 | `mix test` + ExUnit + LiveView 集成测试 |

**核心洞察**：Sigil 的 Agent Runtime 是 pi-codex-conversion 没有的。Responses API 适配器可以挂在现有 Provider 协议后面，享受完整的中间件、权限、审计、MCP 能力。

---

## 四、建议的落地路径

### Phase 1：Codex Responses Provider（核心）

**目标**：新增 `Sigil.Providers.CodexResponses`，支持 Responses API 的流式调用。

```
lib/sigil/agent/providers/
├── openai_responses.ex      # 新增：Responses API Provider
├── openai_responses/
│   ├── transformer.ex       # Pi messages → Responses API items
│   ├── stream_parser.ex     # SSE + WebSocket 流事件解析
│   ├── reasoning_handler.ex # reasoning / thinking / text_signature
│   └── tool_call_handler.ex # function_call / function_call_output 转换
```

**关键改动点**：

1. **消息转换**（`transformer.ex`）
   - `user/assistant` 消息 → `message` item（含 `role`, `content`）
   - `thinking` block → `reasoning` item（含 `text_signature` 编码）
   - `tool_calls` → `function_call` item（`call_id` + `id` 分离）
   - `tool_result` → `function_call_output` item
   - 图片 → `image_generation_call` item

2. **流式解析**（`stream_parser.ex`）
   - 先做 **SSE 流式**（兼容性优先），后续加 WebSocket
   - 响应事件类型：`response.created` / `response.output_item.added` / `text.delta` / `function_call_arguments.delta` / `response.done`
   - 基于 `Agent.Streaming` 中间件适配

3. **Reasoning 处理**（`reasoning_handler.ex`）
   - `reasoning` item → 存入 `Agent.Turn.reasoning` 字段
   - `text_signature` → 用于后续消息签名验证
   - `effort` / `budget_tokens` 参数透传

### Phase 2：Adapter 层（Codex 风格切换）

**目标**：检测到 Codex 模型时，自动启用 Codex 工具集 + Responses API。

```
lib/sigil/agent/
├── adapter/
│   ├── codex_model.ex           # is_codex_like_model? 检测
│   ├── tool_set.ex              # tool 映射表
│   └── adapter_switch.ex        # 模型切换时切换 provider/toolset
```

**切换逻辑**：

```elixir
# 当模型是 Codex-like 时
# 1. Provider: OpenAI → OpenAIResponses
# 2. Tool: bash/edit/write → exec_command/write_stdin/apply_patch
# 3. System prompt: 注入 Codex Guidelines + Shell info
# 4. 离开时恢复用户原有配置
```

### Phase 3：Codex 风格工具集

**目标**：实现 pi-codex-conversion 的四个核心工具。

| 工具 | 对应 Pi 工具 | Sigil 实现建议 |
|------|-------------|---------------|
| `exec_command` | `bash` | `BashTool` 扩展 PTY + 会话复用 + yield 轮询 |
| `write_stdin` | — | 新增 `WriteStdinTool`，关联 exec session |
| `apply_patch` | `edit`/`write` | 复用 `EditTool`，新增 `*** Begin Patch` 格式支持 |
| `web_search` | — | 新增 `WebSearchTool`，仅在 Codex provider 可用 |

**exec_command 架构**：

```elixir
# lib/sigil/tool/builtin/exec/
├── command.ex         # exec_command 工具定义
├── session_manager.ex # Port/PTY 会话管理
└── session_store.ex   # GenServer 存储活跃会话（可复用、可中断）
```

- **pipe 模式**：`Port.open/2` + `Port.command/2` + `Port.read/2`
- **PTY 模式**：：`Erlang` open_port `{:pty, true}`（无需依赖 node-pty）
- **会话复用**：GenServer 维护 `session_id → Port` 映射
- **中断**：`Port.close/1` + `AbortSignal`（复用 Sigil 现有机制）
- **输出限流**：按 token 数截断（复用 `tokenizer.ex`）

### Phase 4：Apply Patch 格式

**目标**：在 `EditTool` / `WriteTool` 中支持 Codex patch 格式。

```
lib/sigil/tool/builtin/edit/
├── edit.ex            # 现有
├── patch_format.ex    # 新增：*** Begin Patch 解析器
└── partial_failure.ex # 部分失败恢复机制
```

**Patch 格式**（与 pi-codex-conversion 兼容）：

```
*** Begin Patch
*** Add File: path/to/file
+line of code
*** End Patch
```

- Elixir 实现解析器（直接、无 Rust 依赖）
- `partial_failure`：文件级失败不阻断整体执行
- `mustReadFiles` / `mustNotReadFiles`：失败后的恢复指令

### Phase 5：Shell 解析 + System Prompt

**目标**：shell 感知 + Codex Guidelines 注入。

```elixir
# lib/sigil/agent/adapter/
├── shell_detector.ex    # 检测当前 shell（fish → bash fallback）
├── shell_parser.ex      # tree-sitter 等效解析（Erlang 实现）
└── system_prompt_builder.ex  # 重组 system prompt
```

**Shell 解析**（树形简化版）：
- Elixir 版不需要树形完整 AST，只需要命令分类（read/list/search/run）
- 用 `String.split/2` + `Enum.take_while/2` 实现基础版
- 后续可引入 Erlang `sh` lexer 或 NIF

**System Prompt 注入点**：
- `Agent.Config.build_system_prompt/2` 中检测到 Codex 模型时
- 注入 Current Shell + Codex Guidelines（不重复 Pi 现有 guidelines）

### Phase 6：WebSocket 流式（进阶）

**目标**：在 SSE 基础上支持 WebSocket 传输。

```elixir
# lib/sigil/agent/providers/openai_responses/
├── ws_client.ex         # WebSocket 客户端（Phoenix.Channel / Mint）
├── session_cache.ex     # WS 会话缓存（5 分钟 TTL）
└── continuation.ex      # previous_response_id 续传
```

- Phoenix `Mint` + `WebSocket` 实现
- 或复用 Sigil 的 LiveView Channel 机制
- 幂等性：`prompt_cache_key` + `previous_response_id`

---

## 五、优先级排序

| 阶段 | 内容 | 优先级 | 预估工作量 |
|------|------|--------|-----------|
| **P0** | Responses API Provider（SSE + 消息转换） | 🔴 最高 | 3-5 天 |
| **P1** | Adapter 切换 + Codex 工具集（exec_command/apply_patch） | 🔴 高 | 2-3 天 |
| **P2** | PTY + WebSocket | 🟡 中 | 3-5 天 |
| **P3** | Shell 解析 + System Prompt 注入 | 🟡 中 | 1-2 天 |
| **P4** | web_search / image_generation 适配 | 🟢 低 | 2-3 天 |

---

## 六、Sigil 独有的增值点

pi-codex-conversion 没有但 Sigil 天然具备：

| 能力 | pi-codex-conversion | Sigil |
|------|---------------------|-------|
| **权限审批** | ❌ | ✅ ToolGuard + ApprovalMode |
| **中断/降级** | ❌ | ✅ Agent State + InterruptData |
| **审计日志** | ❌ | ✅ EventRecorder JSONL |
| **MCP 工具桥** | ❌ | ✅ MCP Runtime + Plugin Bridge |
| **LiveView 投影** | ❌ | ✅ PubSub Session → LiveView |
| **多 Agent 协同** | ❌ | ✅ Coordinator + RunSupervisor |
| **记忆系统** | ❌ | ✅ mem_recall/learn/reinforce/associate |

**这意味着**：Responses API 适配器可以享受完整的 Sigil 基础设施——审批、权限、审计、记忆、MCP——这是任何单一 CLI 工具做不到的。

---

## 七、具体代码建议

### 7.1 Provider 注册

在 `config/config.exs` 新增 Codex 模型映射：

```elixir
config :sigil, Sigil.Providers.CodexResponses,
  api_url: System.get_env("OPENAI_API_URL", "https://api.openai.com"),
  api_key: System.get_env("OPENAI_API_KEY")
```

### 7.2 Provider 行为兼容

`OpenAIResponses` 实现现有 `Provider` 行为：

```elixir
defmodule Sigil.Providers.OpenAIResponses do
  @behaviour Sigil.Agent.Provider

  @impl true
  def complete(messages, config, opts) do
    items = Transformer.to_response_items(messages)
    http_post("/v1/responses", %{model: config.model, input: items, stream: true}, opts)
  end
  # ...
end
```

### 7.3 复用现有中间件

`Agent.Streaming` 已经处理流分块、token 统计、 yielding，不需要重写——只需要在 `OpenAIResponses` 的流回调中把 Responses API 事件格式翻译成 Pi 的 `turn_delta` 事件：

```elixir
def handle_stream_event(%{"type" => "response.output_item.added", "item" => %{"type" => "function_call"}}, acc) do
  # function_call 开始 → emit tool_call_start
end
```

### 7.4 零成本 fallback

如果 Responses API 失败（模型不支持 / 网络错误），在 Adapter 层 fallback 回 Chat Completions：

```elixir
defp call_with_fallback(messages, config) do
  with {:ok, result} <- OpenAIResponses.complete(messages, config) do
    result
  else
    _ -> OpenAI.complete(messages, config)  # 降级到 Chat Completions
  end
end
```

---

## 八、风险与注意事项

1. **API 稳定性**：Responses API 仍在迭代，字段可能变更。需要适配器版本检测。
2. **Reasoning 签名**：`text_signature` 是 OpenAI 内部的完整性校验，Elixir 端无需生成，只需要存储和透传。
3. **Patch 格式歧义**：`*** Begin Patch` 与 Git diff 可能冲突，需要安全防护（禁止在 Patch 中包含 git diff）。
4. **PTY 安全**：交互式 PTY 有安全风险，必须通过 ToolGuard 和白名单控制。
5. **WebSocket 缩放**：大量 WebSocket 连接需要 Phoenix Presence 管理，避免内存泄漏。

---

## 九、总结

Sigil 的架构比 pi-codex-conversion **更强大**：OTP 并发模型、中间件栈、权限系统、MCP 生态、审计追踪——这些是 CLI 工具天然不具备的。实现 Responses API 适配器不需要从零开始，而是**在现有 Provider 协议上扩展一个新实现**。

**最短可行路径**：
1. `OpenAIResponses` provider（SSE 流式 + 消息转换）
2. `CodexAdapter`（模型检测 + 工具集切换）
3. `ExecCommand` tool（pipe 模式）
4. `ApplyPatch` tool（基础 patch 格式）

4 个模块，P0 + P1 约 5-8 天可落地 MVP。后续 PTY、WebSocket、Shell 解析逐步增强。
