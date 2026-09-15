# LLM Agent Reasoning Level Implementation Plan

> Date: 2026-05-16
> Status: Design plan
> Related research: `docs/llm-agent-reasoning-level-research.md`

## Goal

Add a unified reasoning level feature to Sigil so users can choose a provider-neutral
thinking/reasoning level from the UI and have Sigil map it to the correct provider
API parameters.

The shared abstraction follows pi:

| Level | Meaning | Typical use |
| --- | --- | --- |
| `off` | Disable reasoning | Simple Q&A, translation |
| `minimal` | Minimal reasoning | Small edits, short completions |
| `low` | Light reasoning | Routine code edits |
| `medium` | Balanced reasoning | Normal coding tasks |
| `high` | Deep reasoning | Complex refactors, design |
| `xhigh` | Maximum reasoning | Very complex tasks, when supported |

## Non-Goals

- Do not add Shift+Tab or other keyboard shortcuts in the first implementation.
- Do not persist per-conversation reasoning preference yet.
- Do not build a custom model dropdown yet.
- Do not expose provider-specific raw parameters in the UI.
- Do not implement OpenAI encrypted reasoning item replay in this phase.

## User Experience

Place a compact reasoning selector beside the model selector in the composer toolbar:

```text
[ Step Router v1 (StepFun) v ] [ Reasoning: medium v ] [ Send ]
```

Rules:

- Hide the reasoning selector when the selected model does not support reasoning.
- Always allow `off` when reasoning is supported.
- When switching models:
  - keep the current reasoning level if the new model supports it;
  - otherwise use the model's `defaultReasoning`;
  - otherwise use `medium`;
  - otherwise use the first available level.
- The selector should be compact and should not reintroduce the removed Provider/Model
  metadata panel.

## Configuration Model

Extend model entries in `~/.sigil/models.json`:

```json
{
  "id": "step-router-v1",
  "name": "Step Router v1 (StepFun)",
  "reasoning": true,
  "defaultReasoning": "medium",
  "thinkingLevelMap": {
    "minimal": "low",
    "low": "low",
    "medium": "medium",
    "high": "high",
    "xhigh": "high"
  }
}
```

Field meanings:

- `reasoning`: enables the reasoning selector for the model when `true`.
- `defaultReasoning`: optional default level for model selection.
- `thinkingLevelMap`: optional per-level provider mapping.
- `thinkingLevelMap[level] = null`: level is unsupported and should be hidden.
- `thinkingLevelMap[level] = "max"`: send `"max"` or provider-specific equivalent.

`off` is a Sigil-level control and does not need to appear in `thinkingLevelMap`.

## Internal Data Model

Create `Sigil.Agent.Reasoning`.

Responsibilities:

- Define valid levels.
- Validate and normalize user input.
- Determine supported levels for a model.
- Resolve a selected level to provider-specific request options.
- Clamp `xhigh` to `high` unless the model map explicitly supports another value.

Suggested API:

```elixir
defmodule Sigil.Agent.Reasoning do
  @levels ["off", "minimal", "low", "medium", "high", "xhigh"]

  def levels, do: @levels
  def valid?(level)
  def normalize(level)
  def supported_levels(model_entry)
  def default_level(model_entry)
  def resolve(model_entry, selected_level)
  def apply_provider_options(provider_config, model_entry, selected_level)
end
```

Default provider effort mapping:

| Sigil level | Provider effort |
| --- | --- |
| `minimal` | `low` |
| `low` | `low` |
| `medium` | `medium` |
| `high` | `high` |
| `xhigh` | `high` |

## ModelConfig Changes

Update `Sigil.Agent.ModelConfig`:

- `model_summary/1` should include:
  - `:default_reasoning`
  - `:thinking_level_map`
- `extract_all_models/1` should include the same fields.
- `provider_config_for/2` should return selected provider config only; model-specific
  reasoning data should stay on the selected model entry.
- Add helper if useful:

```elixir
def find_model_for_workspace(workspace_root, composite_id)
```

This avoids re-searching model entries in LiveView.

## LiveView Changes

Update `SigilWeb.WorkspaceLive` assigns:

```elixir
:selected_reasoning_level
:available_reasoning_levels
```

Mount:

- Select default model as today.
- Derive reasoning levels from the selected model.
- Pick default reasoning level using `Sigil.Agent.Reasoning.default_level/1`.

Events:

```elixir
handle_event("select_reasoning", %{"reasoning" => level}, socket)
```

Model switch:

- Existing `select_model` should recalculate reasoning levels.
- Preserve current selected reasoning level when possible.
- Update status if status bar will show reasoning in the future.

Send message:

- Resolve selected model as today.
- Inject reasoning options into `provider_config`.
- Pass the selected `reasoning_level` through `Coordinator.add_message/3`.

## Agent Runtime Changes

Update `Sigil.Agent.Config`:

```elixir
defstruct [
  ...
  :reasoning_level,
  ...
]
```

`from_opts/1` should read:

```elixir
reasoning_level: Keyword.get(opts, :reasoning_level, "off")
```

Reasoning provider options can either be merged before `Config.from_opts/1` or inside it.
Preferred first implementation: merge into `provider_config` in LiveView/Coordinator after
model resolution, because model metadata is available there.

## Provider Mapping

### OpenAI Responses

File: `lib/sigil/agent/provider/openai.ex`

Add request body support:

```json
{
  "reasoning": { "effort": "medium" }
}
```

`off` sends nothing.

### OpenAI-Compatible Chat Completions

File: `lib/sigil/agent/provider/openai_compat.ex`

Default mapping:

```elixir
reasoning_effort: "medium"
```

`off` sends nothing.

### DeepSeek

DeepSeek-compatible config should send:

```elixir
thinking: %{type: "enabled"},
reasoning_effort: "high"
```

For `off`, send:

```elixir
thinking: %{type: "disabled"}
```

DeepSeek official supported reasoning effort values are `high` and `max`; clamp unsupported
Sigil levels accordingly unless the model config overrides them.

### Anthropic

File: `lib/sigil/agent/provider/anthropic.ex`

Support adaptive thinking for newer models:

```json
{
  "thinking": { "type": "adaptive" },
  "output_config": { "effort": "high" }
}
```

Keep existing manual budget compatibility:

```json
{
  "thinking": { "type": "enabled", "budget_tokens": 8192 }
}
```

Default budget fallback:

| Sigil level | Budget tokens |
| --- | ---: |
| `minimal` | 1024 |
| `low` | 2048 |
| `medium` | 8192 |
| `high` | 16384 |
| `xhigh` | 16384 |

### StepFun

File: `lib/sigil/agent/provider/stepfun.ex`

The default `Sigil.Agent.Provider.StepFun` path uses OpenAI Chat Completions
(delegating to `OpenAICompat`). Send `reasoning_effort` and optional `thinking`
based on provider/model config.

`stepfun-anthropic` (`api: "anthropic-messages"`) remains on the Anthropic
Messages path and can use Anthropic-style thinking fields.

## Implementation Phases

### Phase 1: Pure Reasoning Module

- Add `Sigil.Agent.Reasoning`.
- Add unit tests for:
  - valid levels;
  - default mapping;
  - `xhigh` clamping;
  - `thinkingLevelMap` overrides;
  - unsupported levels hidden by `null`;
  - `off` behavior.

### Phase 2: Model Config Parsing

- Extend `model_summary/1`.
- Extend `extract_all_models/1`.
- Add tests that model entries preserve `defaultReasoning` and `thinkingLevelMap`.

### Phase 3: UI State and Selector

- Add LiveView assigns.
- Render compact `select#reasoning-picker`.
- Add `select_reasoning` event.
- Update `select_model` to recalculate supported levels.
- Add LiveView tests for:
  - selector appears for reasoning-capable models;
  - selector hides for non-reasoning models;
  - selecting a reasoning level updates assign/rendered value.

### Phase 4: Runtime Wiring

- Pass `reasoning_level` through `Coordinator.add_message/3`.
- Merge provider options after model resolution.
- Add Coordinator/LiveView tests that selected reasoning reaches `Sigil.Agent.run/2`
  options or provider config.

### Phase 5: Provider Body Support

- OpenAI Responses: add `reasoning.effort`.
- OpenAICompat: use existing `reasoning_effort` path.
- DeepSeek: ensure `thinking.type` behavior.
- Anthropic: add adaptive thinking and `output_config`.
- StepFun: add Anthropic-style thinking fields.
- Add provider tests by capturing request bodies.

## Test Commands

Targeted:

```bash
mix test test/sigil/agent/model_config_test.exs
mix test test/sigil/agent/reasoning_test.exs
mix test test/sigil_web/live/workspace_live_test.exs
mix test test/sigil/agent/provider/openai_test.exs
mix test test/sigil/agent/provider/openai_compatible_test.exs
mix test test/sigil/agent/provider/deepseek_test.exs
mix test test/sigil/agent/provider/anthropic_test.exs
mix test test/sigil/agent/provider/stepfun_test.exs
```

Full check:

```bash
mix test
```

## Risks

- Provider APIs differ in small but important ways; keep mappings centralized in
  `Sigil.Agent.Reasoning`.
- Some OpenAI-compatible providers may reject `reasoning_effort`; only send it when the
  selected model declares `reasoning: true`.
- Anthropic adaptive thinking support is model-dependent; use explicit model config rather
  than guessing solely from model names where possible.
- Existing `extended_thinking` should keep working for direct API callers.

## Open Questions

- Should Sigil persist the selected reasoning level per conversation or per workspace?
- Should `models.json` support provider-level default reasoning?
- Should status bar show the current reasoning level beside the model?
- Should `xhigh` be visible by default, or only when `thinkingLevelMap` explicitly declares it?
