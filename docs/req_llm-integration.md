# ReqLLM Provider 接入总结

> Sigil Agent Provider 层的 req_llm 统一适配器实现与踩坑记录

## 概述

将 [req_llm](../req_llm/) 接入 Sigil 作为统一的 LLM provider 适配层。req_llm 提供多 provider（OpenAI、Anthropic、StepFun 等）的统一接口，Sigil 通过新增的 `Sigil.Agent.Provider.ReqLLM` 模块桥接两边的消息/响应格式。

## 最终文件变更

| 文件 | 变更 |
|------|------|
| `lib/sigil/agent/provider/req_llm.ex` | **新增** 完整实现：7 个函数，~260 行 |
| `test/sigil/agent/provider/req_llm_test.exs` | **修复** mock stream metadata 跨进程访问 |
| `lib/sigil_web/live/workspace_live.ex` | **修改** 移除硬编码 `OpenAICompatible` provider |
| `models.json` | **新增** StepFun Anthropic 配置 |

## 架构与链路

```
models.json
  └─ ModelConfig.provider_config()
       └─ %{api: :anthropic, base_url: "...", api_key: "...", model: "step-router-v1"}
            └─ Config.from_opts(provider_config: pc)
                 └─ resolve_provider_from_api(:anthropic)
                      └─ Sigil.Agent.Provider.ReqLLM
                           ├─ build_model/1    → LLMDB.Model{provider: :anthropic, ...}
                           ├─ to_context/2     → ReqLLM.Context
                           ├─ to_tools/1        → [ReqLLM.Tool]
                           ├─ build_generate_opts → [api_key:, base_url:, tools:]
                           │
                           ├─ complete/3        → ReqLLM.generate_text(model, context, opts)
                           │    └─ from_req_llm_response/1 → Sigil completion_response
                           │
                           └─ stream/4          → ReqLLM.stream_text(model, context, opts)
                                └─ StreamResponse.process_stream(on_result: on_chunk)
                                     └─ from_req_llm_response/1
```

## 关键映射

### 消息格式

| Sigil 格式 | req_llm 格式 |
|------------|-------------|
| `%Message{role: :user, content: "Hello"}` | `%ReqLLM.Message{role: :user, content: [ContentPart.text("Hello")]}` |
| `%Message{role: :assistant, content: [%{"type"=>"tool_use","id"=>...,"name"=>...,"input"=>...}]}` | `%ReqLLM.Message{role: :assistant, tool_calls: [ToolCall.new(id, name, json)]}` |
| `%Message{role: :tool_result, content: %{"type"=>"tool_result","tool_use_id"=>...,"content"=>...,"is_error"=>...}}` | `%ReqLLM.Message{role: :tool, tool_call_id: ..., content: [...], metadata: %{is_error: ...}}` |

### 响应

| req_llm Response | Sigil completion_response |
|-----------------|--------------------------|
| `finish_reason: :stop` | `stop_reason: :end_turn` |
| `finish_reason: :tool_calls` | `stop_reason: :tool_use` |
| `message.tool_calls[]` | `content: [%{"type" => "tool_use", "id" => ...}]` |
| `message.content[text]` | `content: "text..."` |
| `usage.input_tokens` / `usage.output_tokens` | `usage.input_tokens` / `usage.output_tokens` |
| `id` / `model` | `response_metadata.id` / `response_metadata.model` |

### 边界处理

| 场景 | 处理 |
|------|------|
| tool_use 的 `input` 为 `nil` | `Jason.encode!(%{})` → 空 map |
| ToolCall `args_map` 解析失败 | `|| %{}` 兜底 |
| tool_result 的 `is_error` | 存入 `metadata[:is_error]` |
| 缺少 `api_key` | 返回 `{:error, "api_key is required in config"}` |
| 空 tool_defs | `build_generate_opts` 不传 `:tools` key |

## 踩坑记录

### 1. `base_url` 必须通过 opts 传入，不能只放 model struct

**表象**：请求打到 `api.anthropic.com` 而不是自定义 URL，返回 404。

**根因**：req_llm 的 `Provider.Defaults.prepare_chat_request` 使用 `inject_base_url_from_registry` 解析 base_url，该函数只查：

```
1. opts[:base_url]              ← 调用时传入
2. Application config
3. provider_mod.default_base_url()
```

**不查 `LLMDB.Model.base_url` 字段**。`effective_base_url/3` 虽然查 model.base_url，但只被 Mistral/Minimax/Google 等定制 provider 调用。

**修复**：在 `build_generate_opts` 中将 `config[:base_url]` 写入 opts：

```elixir
Keyword.put(opts, :base_url, config[:base_url])
```

### 2. `api_key` 同样必须通过 opts 传入

**表象**：`Invalid parameter: :api_key option, config :req_llm, anthropic_api_key, or ANTHROPIC_API_KEY env var`

**根因**：`ReqLLM.Keys.get!` 从 opts `:api_key` 取，不查 model struct。

**修复**：同上，`build_generate_opts` 传入 `api_key`。

### 3. Mock stream metadata 跨进程访问

**表象**：stream 测试中 usage 始终为 0。

**根因**：`build_stream_response` 中 `MetadataHandle.start_link` 创建的 GenServer 与测试进程隔离，GenServer 内 `Process.get(:mock_stream_metadata)` 读到空字典。

**修复**：在创建 GenServer 前捕获 mock_metadata 值，闭包捕获后传入：

```elixir
mock_metadata = Process.get(:mock_stream_metadata, %{})
{:ok, metadata_handle} =
  ReqLLM.StreamResponse.MetadataHandle.start_link(fn -> mock_metadata end)
```

### 4. LiveView 硬编码 provider

**表象**：`models.json` 配置了 `api: "anthropic-messages"` 但请求还是走 OpenAI 路径。

**根因**：`WorkspaceLive` 调用 `Sigil.Agent.run` 时硬编码了 `provider: Sigil.Agent.Provider.OpenAICompatible`，导致 `Config.from_opts` 中的 `resolve_provider_from_api` 被绕过。

**修复**：移除硬编码的 `provider:` 参数，让 `Config.from_opts` 根据 `provider_config[:api]` 自动路由。

## 配置示例 (models.json)

```json
{
  "defaultProvider": "stepfun-anthropic",
  "defaultModel": "step-router-v1",
  "providers": {
    "stepfun-anthropic": {
      "baseUrl": "https://api.stepfun.com/step_plan",
      "api": "anthropic-messages",
      "apiKey": "env:OPENAI_API_KEY",
      "models": [
        {
          "id": "step-router-v1",
          "name": "Step Router v1 (Anthropic)",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 256000,
          "maxTokens": 256000
        }
      ]
    }
  }
}
```

`api` 字段取值与路由：

| `api` 值 | `api_to_atom` | `resolve_provider_from_api` |
|----------|---------------|-----------------------------|
| `"openai-chat-completions"` | `:openai` | `Sigil.Agent.Provider.ReqLLM` |
| `"anthropic-messages"` | `:anthropic` | `Sigil.Agent.Provider.ReqLLM` |
| 其他/缺失 | `:openai` | `Sigil.Agent.Provider.ReqLLM` |

`baseUrl` 特殊处理：`api` 为 `"anthropic-messages"` 且 URL 包含 `/step_plan` 时，`ModelConfig.normalize_base_url` 自动追加 `/v1`。

## 测试覆盖

```
mix test test/sigil/agent/provider/req_llm_test.exs   # 34 tests, 0 failures
mix test test/sigil/agent/model_config_test.exs       # 29 tests, 0 failures
```

| 测试分组 | 数量 | 说明 |
|----------|------|------|
| `build_model/1` | 6 | 内联 model spec 构建，api/default/api_key/system_prompt |
| `to_context/2` | 8 | user/assistant/tool_use/tool_result 映射 + system prompt 注入 |
| `to_tools/1` | 2 | tool_defs → Tool struct |
| `from_req_llm_response/1` | 5 | end_turn/tool_calls/多工具/空内容/解析失败 |
| `complete/3` integration | 6 | 文本/工具调用/错误处理/缺失 api_key |
| `stream/4` integration | 4 | on_chunk 回调/文本组装/usage/错误 |
| behaviour compliance | 1 | 导出 complete/3 和 stream/4 |
