# Handoff: 实现 Sigil.Agent.Provider.ReqLLM（req_llm 接入）

## 背景

Sigil 决定引入 req_llm 作为 LLM provider 统一适配层。前置评估和 TDD 已完成，现在需要实现真正的 Provider 代码。

评估文档：`sigil/docs/req_llm-evaluation.md`

## 当前状态

### 已完成的 TDD 测试（待变绿）

| 测试文件 | 测试数 | 当前状态 |
|---|---|---|
| `test/sigil/agent/provider/req_llm_test.exs` | 34 tests | 30 红 / 4 绿 |
| `test/sigil/agent/model_config_test.exs` | 29 tests | 全绿 ✅（api 字段已实现） |

### 已实现的桩模块

`lib/sigil/agent/provider/req_llm.ex` — 只有函数签名和 `raise "TODO"`，等待实现：

- `complete/3` — 返回 `{:error, "TODO"}`
- `stream/4` — 返回 `{:error, "TODO"}`
- `build_model/1` — `raise "TODO"`
- `to_context/2` — `raise "TODO"`
- `to_tools/1` — `raise "TODO"`
- `from_req_llm_response/1` — `raise "TODO"`
- `sigil_to_req_llm_message/1` — `raise "TODO"`

### 已实现的前置依赖

- `Sigil.Agent.ModelConfig.provider_config/1` 已返回 `:api` 字段（`:openai` | `:anthropic`）
- `Sigil.Agent.Config.from_opts/1` 已通过 `resolve_provider_from_api/1` 路由到 `Sigil.Agent.Provider.ReqLLM`
- `mix.exs` 已添加 `{:req_llm, path: "../req_llm"}`

## 目标任务

实现 `Sigil.Agent.Provider.ReqLLM` 的所有函数，让 TDD 测试全绿。

### 核心约束

1. 不破坏现有测试（当前 baseline: `mix test` 全绿，排除了已存在的 SSE flaky 和 ReqLLM 测试）
2. 不写入任何真实 API key
3. 测试用 `MockReqLLM` mock（已定义在 test 文件中），通过 config `:req_llm_module` 注入

### 实现顺序建议

```
纯函数（无外部依赖）：
1. build_model/1      → %{api:, model:, base_url:, api_key:, system_prompt:} → %LLMDB.Model{}
2. to_tools/1         → [Sigil tool_def] → [ReqLLM.Tool]
3. sigil_to_req_llm_message/1 → Sigil.Message → ReqLLM.Message
4. to_context/2       → [Sigil.Message] → ReqLLM.Context (+ system_prompt 注入)
5. from_req_llm_response/1 → ReqLLM.Response → Sigil completion_response

集成（调用 mock ReqLLM）：
6. complete/3  → 构建 model/context/tools → 调 req_llm_module.generate_text → from_req_llm_response
7. stream/4    → 构建 model/context → 调 req_llm_module.stream_text → process_stream(on_chunk) → from_req_llm_response
```

### 关键映射关系

```
Sigil 内部格式:
  %Message{role: :user, content: "Hello"}
  %Message{role: :assistant, content: [%{"type"=>"tool_use","id"=>...,"name"=>...,"input"=>...}]}
  %Message{role: :tool_result, content: %{"type"=>"tool_result","tool_use_id"=>...,"content"=>...,"is_error"=>...}}

req_llm 格式:
  %ReqLLM.Message{role: :user, content: [%ContentPart{type: :text, text: "Hello"}]}
  %ReqLLM.Message{role: :assistant, tool_calls: [%ToolCall{id:, function: %{name:, arguments:}}]}
  %ReqLLM.Message{role: :tool, tool_call_id: ..., content: [%ContentPart{type: :text, ...}], metadata: %{is_error: ...}}
```

```
Sigil completion_response:
  %{stop_reason: :tool_use | :end_turn, messages: [Sigil.Message], usage: %{input_tokens, output_tokens}, provider_state: %{}, response_metadata: %{id, model}}

req_llm Response:
  %ReqLLM.Response{id, model, message: %ReqLLM.Message, finish_reason: :stop | :tool_calls, usage: %{input_tokens, output_tokens}, ...}
```

### 测试 mock 机制

测试文件 `req_llm_test.exs` 中已定义 `MockReqLLM` 模块，通过 process dictionary 注入：

```elixir
# 设置 mock 响应
Process.put(:mock_req_llm_response, {:ok, build_req_llm_text_response("Hello")})

# 调用 adapter（config 中 req_llm_module: MockReqLLM）
{:ok, resp} = Provider.ReqLLM.complete([user_msg()], [], config)

# 验证
assert resp.stop_reason == :end_turn
assert hd(resp.messages).content == "Hello"
```

### 验收标准

```
mix test test/sigil/agent/provider/req_llm_test.exs  # 34 tests, 0 failures
mix test                                              # 全量回归，无新增失败
```

### 参考代码

| 文件 | 作用 |
|---|---|
| `lib/sigil/agent/provider.ex` | Provider behaviour 签名 |
| `test/sigil/agent/provider/req_llm_test.exs` | **TDD 测试（实现目标）** |
| `lib/sigil/agent/provider/req_llm.ex` | **桩模块（需要实现）** |
| `lib/sigil/agent/provider/openai_compatible.ex` | 参考：消息映射、响应解析模式 |
| `lib/sigil/agent/message.ex` | Sigil 内部 Message 定义 |
| `../../../req_llm/lib/req_llm.ex` | req_llm API 参考（generate_text、stream_text） |
| `../../../req_llm/lib/req_llm/response.ex` | req_llm Response 和 ToolCall 结构 |
| `../../../req_llm/lib/req_llm/context.ex` | req_llm Context 构建（user/assistant/system/tool_result helpers） |
| `../../../req_llm/lib/req_llm/stream_response.ex` | StreamResponse.process_stream/2 用法 |

### 注意

- `sigil_to_req_llm_message/1` 处理 tool_result 时，`is_error` 应存入 `metadata[:is_error]`
- tool_use 的 `input` 可能是 `nil` → 映射为空 map
- `from_req_llm_response/1` 中 tool_call 的 arguments 解析失败时默认空 map（ToolCall.args_map 会处理）
- stream/4 中 `process_stream/2` 用 `on_result:` 回调驱动 `on_chunk`
- config 中取 `req_llm_module` 默认为 `ReqLLM`：`Map.get(config, :req_llm_module, ReqLLM)`
