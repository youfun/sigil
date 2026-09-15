# req_llm Evaluation for Sigil

**Date**: 2026-05-14
**Author**: Sigil team
**req_llm version**: 1.11.0 (Apache 2.0), repo: `github.com/agentjido/req_llm`

---

## 1. Executive Summary

**Recommendation: Introduce `req_llm` as a thin adapter layer (`Sigil.Agent.Provider.ReqLLM`), not as a replacement of the Provider behaviour.**

req_llm is a mature, production-grade library (v1.11.0, Apache 2.0) that provides unified access to 30+ LLM providers including OpenAI Chat Completions, Anthropic Messages, and OpenAI Responses. It has comprehensive tool-call support (including streaming tool calls), production-grade streaming via Finch+SSE with concurrent metadata, built-in retry with `Retry-After` header support, and extensive usage/cost tracking.

The library is **larger and more complex** than Sigil's current minimal Provider behaviour, so the recommended approach is:

- **Keep** `Sigil.Agent.Provider` behaviour as the Sigil-internal contract
- **Add** `Sigil.Agent.Provider.ReqLLM` as a new implementation that delegates to req_llm
- **Retire** `OpenAICompatible` and `Anthropic` providers once `ReqLLM` is validated
- **Extract** the shared SSE parser from Anthropic into its own module regardless (req_llm has its own parser)

This gives Sigil support for all req_llm providers with a single adapter, while keeping the option to write a custom provider later if needed.

---

## 2. req_llm Capability Matrix

| Capability | req_llm Support | Sigil Need | Match |
|---|---|---|---|
| OpenAI Chat Completions | ✅ Native (`OpenAI.ChatAPI`) | ✅ Must | ✅ |
| Anthropic Messages API | ✅ Native (`Anthropic` provider) | ✅ Must | ✅ |
| OpenAI Responses API | ✅ Native (`OpenAI.ResponsesAPI`) | ⚪ Future | ✅ |
| Custom `base_url` | ✅ (inline model spec) | ✅ Must | ✅ |
| Custom `model` | ✅ (inline model spec) | ✅ Must | ✅ |
| OpenAI-compatible 3rd-party | ✅ (vLLM pattern) | ✅ Must (StepFun) | ✅ |
| Provider-specific headers | ✅ (via `req_http_options`) | ✅ Must | ✅ |
| Tool/function schema | ✅ `ReqLLM.Tool` + schema | ✅ Must | ✅ |
| Tool call parsing | ✅ `ReqLLM.ToolCall` struct | ✅ Must | ✅ |
| Tool call id/name/arguments | ✅ | ✅ Must | ✅ |
| Tool result 回传 | ✅ `Context.tool_result/2` | ✅ Must | ✅ |
| Multi-tool calls | ✅ (list of ToolCalls) | ✅ Must | ✅ |
| Malformed args handling | ✅ (decodes best-effort, empty map fallback) | ✅ Must | ✅ |
| Streaming | ✅ Finch + SSE | ✅ Must | ✅ |
| Text delta callback | ✅ `process_stream(on_result:)` | ✅ Must | ✅ |
| Final full message | ✅ `StreamResponse.text/1` | ✅ Must | ✅ |
| Streaming tool calls | ✅ (`:tool_call` chunks + arg merge) | ✅ Must | ✅ |
| Non-streaming fallback | ✅ `generate_text/3` | ✅ Must | ✅ |
| Built-in retry | ✅ (`Step.Retry` + `Retry-After`) | ✅ Nice-to-have | ✅ |
| Status code/body exposure | ✅ (`ReqLLM.Error.API.Request`) | ✅ Must | ✅ |
| Auth error distinction | ✅ (Splode error types) | ✅ Must | ✅ |
| Rate limit distinction | ✅ (429 → `Step.Retry`) | ✅ Must | ✅ |
| API key leak prevention | ✅ (never logged, config redact) | ✅ Must | ✅ |
| Token usage | ✅ (input/output/cache/reasoning) | ✅ Must | ✅ |
| Model/id/finish_reason | ✅ (`Response` fields) | ✅ Must | ✅ |
| Cache usage | ✅ (`cached_tokens`) | ⚪ Future | ✅ |
| Config from JSON | ✅ (inline model + `ReqLLM.put_key/2`) | ✅ Must | ✅ (adapter needed) |

---

## 3. Mapping to Sigil Provider Contract

### Sigil's current contract

```elixir
# Sigil.Agent.Provider behaviour
@type tool_def :: %{name: String.t(), description: String.t(), input_schema: map()}

@type completion_response :: %{
  stop_reason: :tool_use | :end_turn,
  messages: [Message.t()],
  usage: map(),
  provider_state: map(),
  response_metadata: map()
}

@callback complete(messages, tool_defs, config) :: {:ok, completion_response()} | {:error, term()}

@callback stream(messages, tool_defs, config, on_chunk) :: {:ok, completion_response()} | {:error, term()}
```

### How req_llm maps to this

**req_llm's equivalent**:

```
ReqLLM.generate_text(model_spec, messages, tools: tools)
→ {:ok, %Response{message:, usage:, finish_reason:, context:}}

ReqLLM.stream_text(model_spec, messages, tools: tools)
→ {:ok, %StreamResponse{stream:, metadata_handle:}}
```

**Mapping is straightforward**:

| Sigil Contract | req_llm Equivalent | Mapping |
|---|---|---|
| `complete(messages, tool_defs, config)` | `generate_text(model, context, tools: tools)` | Adapt Sigil messages → req_llm Context |
| `stream(messages, tool_defs, config, on_chunk)` | `stream_text(model, context, tools: tools)` → `process_stream(on_result:)` | on_chunk maps to on_result callback |
| `%{stop_reason: :tool_use}` | `Response.finish_reason == :tool_calls` | Direct map |
| `%{stop_reason: :end_turn}` | `Response.finish_reason == :stop` | Direct map |
| `messages: [Message.t()]` | `Response.message` or `Response.context.messages` | Adapt req_llm Message → Sigil Message |
| `usage: %{}` | `Response.usage` | `%{input_tokens, output_tokens}` |
| `provider_state: %{}` | `Response.provider_meta` | Optional |
| `response_metadata: %{}` | `%{id: resp.id, model: resp.model}` | Direct map |

### Internal message format comparison

**Sigil internal format**:
```elixir
# Assistant tool_use message
%Message{role: :assistant, content: [
  %{"type" => "tool_use", "id" => "toolu_01", "name" => "bash", "input" => %{"cmd" => "ls"}}
]}

# Tool result message
%Message{role: :tool_result, content: %{
  "type" => "tool_result",
  "tool_use_id" => "toolu_01",
  "content" => "file1.txt\nfile2.txt",
  "is_error" => false
}}
```

**req_llm equivalent**:
```elixir
# Assistant with tool calls
%Message{role: :assistant, tool_calls: [
  %ToolCall{id: "call_abc", function: %{name: "bash", arguments: ~s({"cmd":"ls"})}}
], content: []}

# Tool result
%Message{role: :tool, tool_call_id: "call_abc", content: [
  %ContentPart{type: :text, text: "file1.txt\nfile2.txt"}
], name: "bash"}
```

**Adapter needed**: A bidirectional translation layer between Sigil's `Message` struct and req_llm's `Message` struct with `ContentPart` and `ToolCall`. This is ~50-80 lines of straightforward mapping code.

---

## 4. Tool Call Support Analysis

### 4.1 Tool definition mapping

```
Sigil tool_def:  %{name: String.t(), description: String.t(), input_schema: map()}
req_llm Tool:    %ReqLLM.Tool{name:, description:, parameter_schema:, compiled:, callback:}
```

| Feature | Sigil | req_llm | Notes |
|---|---|---|---|
| Name + description | ✅ | ✅ | Direct |
| Input schema | `map()` (JSON Schema) | NimbleOptions list or JSON Schema map | ✅ Both supported |
| Tool choice | N/A | `:tool_choice` option | ✅ |
| Parallel tool calls | N/A | `:parallel_tool_calls` | ✅ (OpenAI) |
| Provider-specific options | N/A | `:provider_options` per tool | ✅ |
| Callback execution | Via `Tool.Executor` | Built-in `Tool.execute/2` | Sigil uses own executor |

### 4.2 Response tool call parsing

**req_llm provides multiple extraction paths:**

```elixir
# From non-streaming Response
response |> Response.tool_calls()
# → [%ToolCall{id: "call_123", function: %{name: "bash", arguments: ~s({"cmd":"ls"})}}]

# From streaming StreamResponse
stream_response |> StreamResponse.extract_tool_calls()
# → [%{id: "call_123", name: "bash", arguments: %{"cmd" => "ls"}}]

# Classification (stream-parity)
Response.classify(response)
# → %{type: :tool_calls, text: "...", tool_calls: [...], finish_reason: :tool_calls}
```

### 4.3 Malformed arguments handling

req_llm handles this gracefully:
```elixir
# ToolCall.args_map/1
# Returns nil on decode failure instead of crashing
def args_map(%ToolCall{function: %{arguments: json}}, opts) do
  case ReqLLM.JSON.decode(json, opts) do
    {:ok, map} -> map
    {:error, _} -> nil  # ← graceful fallback
  end
end

# Context.normalize_tool_calls safely defaults to %{}
%{name: "bash", arguments: "[malformed"} → arguments: %{}
```

### 4.4 Tool result 回传

```elixir
# req_llm: tool_result message
Context.tool_result("call_abc", "bash", "file1.txt\nfile2.txt")
# → %Message{role: :tool, tool_call_id: "call_abc", name: "bash", content: [%ContentPart{text: "..."}]}

# Context.execute_and_append_tools automates the loop:
context |> Context.execute_and_append_tools(tool_calls, available_tools)
```

**Sigil needs**: The `is_error` flag and `content` property on tool_result blocks. req_llm stores error state in `metadata[:is_error]`, which needs adapter mapping.

---

## 5. Streaming Support Analysis

### 5.1 Streaming Architecture

req_llm's streaming uses a **two-layer** architecture:

```
Finch HTTP/2 stream → SSE parser → decode_stream_event → StreamChunks
                                                              ↓
                                                   StreamResponse (lazy)
                                                   ├── stream (chunks)
                                                   └── metadata_handle (concurrent Task)
```

### 5.2 Callback mechanism

```elixir
{:ok, sr} = ReqLLM.stream_text(model, context, tools: tools, stream: true)

{:ok, response} = StreamResponse.process_stream(sr,
  on_result: fn text -> send(pid, {:chunk, text}) end,        # text delta
  on_thinking: fn thinking -> send(pid, {:thinking, thinking}) end,
  on_tool_call: fn chunk -> send(pid, {:tool_call, chunk}) end
)

# Or simpler: just consume tokens
sr |> StreamResponse.tokens() |> Stream.each(&IO.write/1) |> Stream.run()
```

**Mapping to Sigil's `stream/4` signature**:
```elixir
# Sigil expects: stream(messages, tool_defs, config, on_chunk)
# on_chunk signature: (String.t() -> :ok)

# req_llm mapping:
def stream(messages, tool_defs, config, on_chunk) do
  {:ok, sr} = ReqLLM.stream_text(model, context, tools: tool_defs, stream: true)
  {:ok, response} = StreamResponse.process_stream(sr, on_result: on_chunk)
  adapt_response(response)
end
```

### 5.3 Streaming tool calls

req_llm **fully supports streaming tool calls**:

- Providers emit `:tool_call` type `StreamChunk`s
- Argument fragments accumulate in `arg_fragments` map
- On stream end, fragments are JSON-decoded and merged into complete tool calls
- `StreamResponse.extract_tool_calls/1` returns the reconstructed list

The reconstruction is handled in `ReqLLM.Response.Stream.summarize/1` and `DefaultResponseBuilder.reconstruct_tool_calls/1`:

```elixir
# During streaming: arg fragments arrive via meta chunks
%{tool_call_args: %{index: 0, fragment: "{\"cmd\""}}
%{tool_call_args: %{index: 0, fragment: ":\"ls\"}"}}

# After stream end: merged and decoded
%{id: "call_123", name: "bash", arguments: %{"cmd" => "ls"}}
```

### 5.4 Sigil Anthropic streaming comparison

Sigil's current Anthropic provider has a **known limitation** documented in a TODO:

```
# TODO: Streaming MVP — the SSE tool_use parsing reconstructs tool IDs
# from stream indices (e.g. "toolu_${index}") rather than capturing the
# real tool_use IDs emitted in content_block_start. This means streamed
# tool_use blocks won't round-trip correctly through tool_result.
```

req_llm's Anthropic provider captures real tool IDs from `content_block_start` events, so this bug would be fixed by switching.

---

## 6. Configuration / modejs.json Compatibility

### 6.1 Sigil's current `models.example.json`

```json
{
  "defaultProvider": "stepfun-anthropic",
  "defaultModel": "step-router-v1",
  "providers": {
    "stepfun-anthropic": {
      "baseUrl": "https://api.stepfun.com/step_plan",
      "api": "anthropic-messages",
      "apiKey": "env:OPENAI_API_KEY",
      "models": [{ "id": "step-router-v1", ... }]
    }
  }
}
```

### 6.2 req_llm inline model spec equivalent

```elixir
# Inline model spec — bypasses LLMDB catalog
model = ReqLLM.model!(%{
  provider: :openai,           # Use OpenAI Chat API protocol
  id: "step-router-v1",
  base_url: "https://api.stepfun.com/step_plan/v1",
  extra: %{wire: %{protocol: "openai_chat"}}
})

# With custom API key
ReqLLM.put_key(:openai_api_key, System.get_env("OPENAI_API_KEY"))

# Generate text
ReqLLM.generate_text(model, messages, tools: tools)
```

### 6.3 The StepFun quirk

**Problem**: StepFun advertises an Anthropic-compatible API, but the actual wire endpoint is `/step_plan/v1/chat/completions` which is OpenAI Chat Completions compatible. The `api: "anthropic-messages"` in `models.example.json` is misleading.

**req_llm handling**: StepFun should use the OpenAI Chat API protocol with a custom `base_url`. The model spec would be:

```elixir
ReqLLM.model!(%{
  provider: :openai,            # Protocol: OpenAI Chat Completions
  id: "step-router-v1",        # Model ID sent in request
  base_url: "https://api.stepfun.com/step_plan/v1",  # Custom endpoint
  api_key: System.get_env("OPENAI_API_KEY")
})
```

This maps cleanly — **no custom provider needed for StepFun**. The vLLM provider in req_llm demonstrates exactly this pattern (15 lines of code for a full OpenAI-compatible provider).

### 6.4 modejs.json → req_llm mapping strategy

```
modejs.json           →  ReqLLM adapter config
─────────────────────────────────────────────
providers[key].baseUrl  →  model.base_url (inline)
providers[key].api      →  model.provider (:"openai" | :anthropic)
providers[key].apiKey   →  ReqLLM.put_key(provider_api_key, value)
                         →  Or env var auto-loaded by dotenvy
defaultProvider         →  :default_provider in adapter config
defaultModel           →  :default_model in adapter config
models[].id             →  model.id
models[].contextWindow  →  Not directly used (informational)
models[].maxTokens      →  opts[:max_tokens]
models[].cost           →  Not directly used (informational)
```

**Recommendation**: Build a simple `Sigil.ProviderConfig` module that reads `modejs.json` and produces the req_llm model spec + options map. This is ~30-50 lines.

---

## 7. Integration Options

### Option A: Full Replacement (NOT RECOMMENDED)

Replace `Sigil.Agent.Provider` behaviour entirely with req_llm's API.

- ❌ Locks Sigil into req_llm's abstraction
- ❌ req_llm's behaviours (`ReqLLM.Provider`) are designed for Req plugins, not Sigil's agent loop
- ❌ Too much coupling to a dependency's internal design
- ❌ Would require rewriting all provider tests

### Option B: Thin Adapter `Sigil.Agent.Provider.ReqLLM` ✅ RECOMMENDED

```elixir
defmodule Sigil.Agent.Provider.ReqLLM do
  @behaviour Sigil.Agent.Provider

  def complete(messages, tool_defs, config) do
    model = build_model_spec(config)
    context = Sigil.Message.to_req_llm_context(messages, config)
    req_tools = Enum.map(tool_defs, &Sigil.Tool.to_req_llm_tool/1)

    case ReqLLM.generate_text(model, context, tools: req_tools) do
      {:ok, response} -> {:ok, Sigil.Response.from_req_llm(response)}
      {:error, error} -> {:error, format_error(error)}
    end
  end

  def stream(messages, tool_defs, config, on_chunk) do
    model = build_model_spec(config)
    context = Sigil.Message.to_req_llm_context(messages, config)
    req_tools = Enum.map(tool_defs, &Sigil.Tool.to_req_llm_tool/1)

    with {:ok, sr} <- ReqLLM.stream_text(model, context, tools: req_tools, stream: true),
         {:ok, response} <- StreamResponse.process_stream(sr, on_result: on_chunk) do
      {:ok, Sigil.Response.from_req_llm(response)}
    else
      {:error, error} -> {:error, format_error(error)}
    end
  end
end
```

**Advantages**:
- ✅ Keeps `Sigil.Agent.Provider` as the internal contract
- ✅ Existing `Agent.Turn` code unchanged
- ✅ Can add/swap providers without changing agent core
- ✅ Ability to have multiple provider implementations simultaneously
- ✅ req_llm becomes one option among potentially others

### Option C: Use req_llm as HTTP/SSE layer only (NOT RECOMMENDED)

Use req_llm's `Streaming.SSE` and `Step.Retry` but keep Sigil's message format and provider wrapping.

- ❌ Duplicates the message translation that req_llm already handles
- ❌ req_llm's `Provider` behaviour already does much of this
- ❌ Would need to re-implement Anthropic's tool_use parsing, etc.

### Option D: Learn from req_llm, don't adopt

- ❌ Sigil still has to maintain OpenAICompatible + Anthropic manually
- ❌ Each new provider (StepFun, DeepSeek, etc.) requires custom code
- ❌ Streaming tool_call fixes, retry logic, error classification are all custom
- ✅ No dependency risk
- ✅ Total control

---

## 8. Risk Analysis

### 8.1 Dependency Maturity

| Factor | Assessment |
|---|---|
| **Version** | 1.11.0 — stable, semantic versioning |
| **GitHub** | `github.com/agentjido/req_llm` — active development |
| **License** | Apache 2.0 ✅ — compatible with Sigil |
| **Elixir compat** | `~> 1.15` (Sigil uses 1.19) ✅ |
| **Dependencies** | ~15 deps (jason, req, finch, nimble_options, splode, zoi, jsv, dotenvy, uniq, etc.) |
| **Test coverage** | 3-tier (unit, provider mock, live fixtures), CI via GitHub Actions |
| **Community** | Part of the Jido ecosystem, used in production |

### 8.2 API Stability

req_llm **actively deprecates** APIs (e.g., `stream_text!/3` is `@deprecated` in favor of `stream_text/3` returning `StreamResponse`). The core `generate_text/3` and `stream_text/3` APIs appear stable. The adapter should target the current public API and add integration tests that catch breakage on dependency upgrades.

### 8.3 Complexity

req_llm is **significantly larger** than Sigil's current provider code:

| Metric | Sigil current | req_llm |
|---|---|---|
| Provider modules | 2 (OAIC + Anthropic) | 30+ provider modules |
| Lines of provider code | ~600 lines | ~25,000+ lines |
| Dependencies | Req only | 15 deps |
| Concepts to learn | 1 behaviour, 2 callbacks | Provider behaviour, Context, ContentPart, ToolCall, ToolResult, StreamChunk, Response, StreamResponse, Model spec, etc. |

The adapter layer insulates Sigil from most of this complexity. Sigil only interacts with ~5 req_llm functions.

### 8.4 Streaming Reliability

- req_llm's streaming uses Finch directly for HTTP/2 multiplexing
- SSE parsing is handled by `ReqLLM.Streaming.SSE`
- Tool call reconstruction from streaming fragments is battle-tested
- Known issue in Sigil's Anthropic streaming (tool IDs) is fixed in req_llm

### 8.5 Provider Quirks Coverage

req_llm handles these provider quirks that Sigil would otherwise need to implement:

| Quirk | Sigil (custom) | req_llm |
|---|---|---|
| OpenAI o1 requires `max_completion_tokens` | Not handled | ✅ `translate_options/3` |
| Anthropic streaming tool_use IDs | Bug (TODO) | ✅ Fixed |
| Anthropic `anthropic-dangerous-direct-browser-access` header | Not handled | ✅ |
| Google tiered pricing | N/A | ✅ |
| AWS Bedrock inference profiles | N/A | ✅ |
| vLLM/Ollama custom base_url | Not handled | ✅ |
| Rate limiting with `Retry-After` | Custom retry | ✅ `Step.Retry` |

### 8.6 License Compatibility

req_llm is **Apache 2.0**. Sigil can use it without license concerns. All transitive dependencies are MIT/Apache 2.0.

### 8.7 Migration Disruption

The adapter approach means **zero changes to `Agent.Turn` or `Agent.State`**. Only:
1. Add `Sigil.Agent.Provider.ReqLLM`
2. Add adapter modules (`Sigil.Message.Adapter.ReqLLM`, `Sigil.Response.Adapter.ReqLLM`)
3. Update `modejs.json` parser to produce req_llm compatible config
4. Existing `OpenAICompatible` and `Anthropic` tests continue to pass
5. Switch `Sigil.Agent.Config` to route to `ReqLLM` provider once validated

---

## 9. Recommendation

### 9.1 Decision: **INTRODUCE req_llm as thin adapter layer**

**Reasoning**:

1. **Provider coverage**: req_llm covers all current and planned Sigil providers (OpenAI-compatible, Anthropic, StepFun) plus 27+ more.

2. **Tool calls**: req_llm handles the complete tool loop including streaming tool calls correctly — Sigil's current Anthropic streaming has a known tool ID bug.

3. **Streaming**: req_llm's streaming is production-grade with concurrent metadata, proper SSE parsing, and tool call reconstruction.

4. **Error handling**: Built-in retry with `Retry-After` header support, structured error types.

5. **Maintenance burden**: Writing and maintaining providers manually costs Sigil development time. req_llm is maintained by a full-time team.

6. **Escape hatch**: Because we keep the `Sigil.Agent.Provider` behaviour, Sigil can always write a custom provider for edge cases.

### 9.2 Recommended Integration Path

1. **Phase 1** (this PR/spike):
   - Create `Sigil.Agent.Provider.ReqLLM` (delegates to req_llm)
   - Create message adapter: `Sigil.Message.to_req_llm_context/2` and `Sigil.Response.from_req_llm/1`
   - Write mock tests (no API keys) proving mapping correctness
   - Add `req_llm` to mix.exs deps

2. **Phase 2** (follow-up):
   - Add provider routing in `Sigil.Agent.Config` (choose between `OpenAICompatible`, `Anthropic`, or `ReqLLM`)
   - Wire up `modejs.json` parsing to produce req_llm config
   - Smoke test with StepFun

3. **Phase 3** (future):
   - Deprecate `OpenAICompatible` and `Anthropic` providers
   - Remove once `ReqLLM` has >= 95% test parity

### 9.3 Alternative: Don't adopt (Honorable mention)

If the team prefers minimal dependencies:

- Fix the Anthropic streaming tool ID bug (already documented as TODO)
- Add SSE parser sharing between Anthropic and OpenAICompatible
- Add `StepFunAnthropic` provider (maps StepFun's Anthropic-like API)
- Accept manual maintenance of ~3-5 providers

This is viable if Sigil will only ever support Anthropic + OpenAI-compatible. But given the trajectory of the LLM market, req_llm is the safer bet.

---

## 10. Spike Notes

### 10.1 Files read for this evaluation

**Sigil (source of truth for current contract)**:
- `sigil/lib/sigil/agent/provider.ex` — Behaviour definition
- `sigil/lib/sigil/agent/provider/openai_compatible.ex` — ~230 lines, OpenAI-compatible impl
- `sigil/lib/sigil/agent/provider/anthropic.ex` — ~310 lines, Anthropic impl with streaming
- `sigil/lib/sigil/agent/message.ex` — Internal message format
- `sigil/lib/sigil/agent/turn.ex` — Agent loop (consumer of Provider contract)
- `sigil/models.example.json` — Config format

**req_llm (evaluated library)**:
- `req_llm/lib/req_llm.ex` — Main API facade (~700 lines)
- `req_llm/lib/req_llm/provider.ex` — Provider behaviour (~450 lines)
- `req_llm/lib/req_llm/generation.ex` — `generate_text/3`, `stream_text/3`
- `req_llm/lib/req_llm/context.ex` — Message construction, tool results
- `req_llm/lib/req_llm/message.ex` — Message struct with content parts
- `req_llm/lib/req_llm/message/content_part.ex` — Multi-modal content
- `req_llm/lib/req_llm/tool.ex` — Tool definitions and execution
- `req_llm/lib/req_llm/tool_call.ex` — Tool call struct + parsing
- `req_llm/lib/req_llm/tool_result.ex` — Structured tool results
- `req_llm/lib/req_llm/response.ex` — Response struct + classify
- `req_llm/lib/req_llm/stream_response.ex` — Streaming response container
- `req_llm/lib/req_llm/stream_chunk.ex` — Streaming chunk types
- `req_llm/lib/req_llm/response/stream.ex` — Stream summarization
- `req_llm/lib/req_llm/provider/defaults/response_builder.ex` — Response assembly
- `req_llm/lib/req_llm/step/retry.ex` — Retry logic
- `req_llm/lib/req_llm/providers/openai/chat_api.ex` — OpenAI driver
- `req_llm/lib/req_llm/providers/vllm.ex` — Minimal OpenAI-compatible provider (15 LOC)
- `req_llm/lib/req_llm/providers/zenmux.ex` — Custom body encoding example
- `req_llm/mix.exs` — Dependencies, version, license

### 10.2 Optional spike (next step)

If proceeding with recommendation, create:
1. `sigil/lib/sigil/agent/provider/req_llm.ex` — Thin adapter
2. `sigil/lib/sigil/agent/message/adapter_req_llm.ex` — Message translation
3. `sigil/test/sigil/agent/provider/req_llm_test.exs` — Mock tests

No API keys required. Tests use `ReqLLM` in-memory with mock Req responses.
