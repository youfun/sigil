# LLM Agent 推理等级 (Thinking/Reasoning Level) 设置机制研究

> 研究日期: 2026-05-16
> 范围: pi CLI (Node.js) + pi-agent-core + pi-ai provider 适配层 + Sigil (Elixir)

---

## 一、整体架构

```
pi CLI (--thinking high)
  │
  ▼
Agent State (thinkingLevel: "high")
  │
  ▼
Agent Loop Config (reasoning: "high")
  │
  ▼
pi-ai Provider Adapter
  ├── Anthropic: adaptive effort / budget_tokens
  ├── OpenAI: reasoning_effort / enable_thinking
  ├── DeepSeek: thinking.type + reasoning_effort
  ├── Z.AI: enable_thinking
  ├── Qwen: chat_template_kwargs.enable_thinking
  └── OpenRouter: reasoning.effort
```

---

## 二、6 级推理等级

pi 定义了统一的 6 级抽象，跨所有 provider：

| 等级 | 含义 | 典型使用场景 |
|------|------|-------------|
| `off` | 不启用推理 | 简单问答、翻译 |
| `minimal` | 最小推理 | 简单代码补全 |
| `low` | 轻度推理 | 日常编辑任务 |
| `medium` | 中等推理 | 中等复杂度重构 |
| `high` | 深度推理 | 复杂算法、架构设计 |
| `xhigh` | 极限推理 | 极复杂问题（部分模型支持） |

---

## 三、用户入口层

用户可以通过 **5 种方式** 设置推理等级：

### 1. CLI flag

```bash
pi --thinking high "solve this complex problem"
```

优先级最高。

### 2. 模型简写（Model Shorthand）

```bash
pi --model sonnet:high          # Anthropic Claude Sonnet + high reasoning
pi --model openai/gpt-5.4:medium # OpenAI GPT-5.4 + medium reasoning
```

pi 解析 `:` 后缀，将最后一段作为 thinking level，前面作为模型 pattern。

### 3. settings.json

```json
{
  "defaultThinkingLevel": "medium",
  "thinkingBudgets": {
    "minimal": 1024,
    "low": 4096,
    "medium": 10240,
    "high": 32768
  }
}
```

### 4. 交互快捷键

在 pi 编辑器内按 `Shift+Tab` 循环切换当前会话的推理等级。

### 5. 模型切换时的继承

通过 `Ctrl+P` 切换模型时，每个 scoped model 都可以预设 thinking level，切换时自动应用。

---

## 四、Agent Core 层

代码路径: `@earendil-works/pi-agent-core/dist/agent.js`

```typescript
// AgentState 存储当前 think level
interface AgentState {
  thinkingLevel: ThinkingLevel;  // "off" | "minimal" | "low" | "medium" | "high" | "xhigh"
}

// 构建 loop config 时传递
createLoopConfig() {
  return {
    reasoning: this._state.thinkingLevel === "off" ? undefined : this._state.thinkingLevel,
    thinkingBudgets: this.thinkingBudgets,
    // ...
  };
}
```

关键逻辑：`"off"` 时传 `undefined`（不启用），其余等级原样传递字符串。

---

## 五、Provider 适配层 — 核心映射

代码路径: `@earendil-works/pi-ai/dist/providers/`

### 5.1 Anthropic Provider

Anthropic 根据模型代际采用不同策略：

#### A. 新模型 — 自适应思考 (Adaptive Thinking)

适用模型: **Opus 4.6, Opus 4.7, Sonnet 4.6**

```js
// anthropic.js: streamSimpleAnthropic()
if (supportsAdaptiveThinking(model.id)) {
    const effort = mapThinkingLevelToEffort(model, options.reasoning);
    // → API body:
    // {
    //   thinking: { type: "adaptive", display: "summarized" },
    //   output_config: { effort: "high" }
    // }
}
```

**默认 effort 映射** (`mapThinkingLevelToEffort`):

| pi 等级 | Anthropic effort |
|---------|:---:|
| `minimal` | `low` |
| `low` | `low` |
| `medium` | `medium` |
| `high` | `high` |
| `xhigh` | `high` |

**通过 `thinkingLevelMap` 可覆盖**。例如 DeepSeek V4 Pro 定义：

```json
{
  "thinkingLevelMap": {
    "xhigh": "max"
  }
}
```

#### B. 旧模型 — 预算制 (Budget Tokens)

适用模型: **Opus 4.5 及之前, Sonnet 4.5 及之前, Haiku 全系列**

```js
// simple-options.js: adjustMaxTokensForThinking()
const defaultBudgets = {
    minimal: 1024,
    low: 2048,
    medium: 8192,
    high: 16384,
};
```

| pi 等级 | 默认 budget_tokens |
|---------|:---:|
| `minimal` | 1024 |
| `low` | 2048 |
| `medium` | 8192 |
| `high` | 16384 |

发送的 API 参数：

```json
{
  "thinking": {
    "type": "enabled",
    "budget_tokens": 16384
  }
}
```

> `max_tokens` 会被自动调整为 `baseMaxTokens + thinkingBudget`，确保总 token 预算覆盖思考 + 输出。

#### C. Thinking Display 控制

Anthropic 响应中的 thinking 内容可通过 display 参数控制：

| display 值 | 行为 |
|-----------|------|
| `"summarized"` (默认) | 返回总结后的思考内容 |
| `"omitted"` | 思考块为空，仅保留签名。减少延迟 |

---

### 5.2 OpenAI Completions Provider

根据 `compat.thinkingFormat` 生成不同的 API 参数：

```js
// openai-completions.js: streamSimpleOpenAICompletions()
const reasoningEffort = clampedReasoning === "off" ? undefined : clampedReasoning;
```

#### 各格式映射

| thinkingFormat | API 参数 | 示例 |
|---------------|---------|------|
| (默认) | `reasoning_effort: "high"` | 标准 OpenAI API |
| `"deepseek"` | `thinking: {type: "enabled"}, reasoning_effort: "high"` | DeepSeek API |
| `"zai"` | `enable_thinking: true` | Z.AI / GLM |
| `"qwen"` | `enable_thinking: true` (顶层) | Qwen 官方 API |
| `"qwen-chat-template"` | `chat_template_kwargs: { enable_thinking: true }` | 本地 Qwen 兼容 |
| `"openrouter"` | `reasoning: { effort: "high" }` | OpenRouter 路由 |

同样支持 `thinkingLevelMap` 按模型覆盖。

---

### 5.3 辅助函数：等级钳制

```js
// simple-options.js
export function clampReasoning(effort) {
    return effort === "xhigh" ? "high" : effort;
}
```

`xhigh` 默认被钳制为 `high`，除非模型通过 `thinkingLevelMap` 显式声明支持 `xhigh` → `"max"` 或其他值。

---

## 六、模型级 thinkingLevelMap 配置

在 `~/.pi/agent/models.json` 或通过 extension API 注册模型时，可设置每个模型的 thinking 支持：

```json
{
  "id": "custom-model",
  "reasoning": true,
  "thinkingLevelMap": {
    "minimal": null,       // 不支持 → UI 隐藏此级别
    "low": null,           // 不支持 → UI 隐藏此级别
    "medium": null,        // 不支持 → UI 隐藏此级别
    "high": "high",        // 支持, 映射到 "high"
    "xhigh": "max"         // 支持, 映射到 "max"
  }
}
```

`thinkingLevelMap` 的值含义：

| 值 | 含义 |
|----|------|
| 省略 (不写) | 该级别支持，使用 provider 默认映射 |
| `"string"` | 该级别支持，将字符串值传给 provider |
| `null` | 该级别不支持，UI 隐藏/跳过/钳制 |

---

## 七、Sigil (Elixir) — 简化直通

Sigil 不走抽象等级，直接暴露 Anthropic 原始参数：

```elixir
# lib/sigil/agent/provider/anthropic.ex
Sigil.Agent.run("prompt",
  provider: {Sigil.Agent.Provider.Anthropic, [
    extended_thinking: [budget_tokens: 5000]
  ]}
)
# → API body: { "thinking": { "type": "enabled", "budget_tokens": 5000 } }
```

- 无 `off/minimal/low/...` 抽象层
- 直接传 Anthropic 原生 `budget_tokens`
- 不支持 adaptive thinking（Opus 4.6+）
- StepFun provider 类似，继承 Anthropic 格式

---

## 八、对比总结

```
┌─────────────────────────────────────────────────────────────────────┐
│                          pi (Node.js)                                │
│                                                                     │
│  User: --thinking high / Shift+Tab / settings.json                  │
│         │                                                           │
│  Agent: thinkingLevel: "high"                                       │
│         │                                                           │
│  Adapter:                                                           │
│    Anthropic 新 → { type: "adaptive", effort: "high" }              │
│    Anthropic 旧 → { type: "enabled", budget_tokens: 16384 }         │
│    OpenAI       → { reasoning_effort: "high" }                      │
│    DeepSeek     → { reasoning_effort: "high", thinking: enabled }   │
│    Qwen         → { enable_thinking: true }                         │
│    Z.AI         → { enable_thinking: true }                         │
│                                                                     │
│  6级抽象 + per-model thinkingLevelMap + custom thinkingBudgets      │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                          Sigil (Elixir)                              │
│                                                                     │
│  User: extended_thinking: [budget_tokens: 5000]                     │
│         │                                                           │
│  No abstraction layer                                               │
│         │                                                           │
│  Adapter:                                                           │
│    Anthropic → { type: "enabled", budget_tokens: 5000 }             │
│    StepFun   → same Anthropic format                                │
│                                                                     │
│  直接传 raw Anthropic 参数，无等级抽象                               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 九、Anthropic 官方 Extended Thinking 参考

来源: [Building with extended thinking - Claude API Docs](https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking)

### 两种模式

| 模式 | API 参数 | 适用模型 | 状态 |
|------|---------|---------|------|
| **Adaptive** | `thinking: {type: "adaptive"}, output_config: {effort}` | Opus 4.6+, Sonnet 4.6+ | 推荐 |
| **Manual** | `thinking: {type: "enabled", budget_tokens: N}` | 旧模型 | 弃用中 |

### Effort 值 (Adaptive)

- `low` — 最小思考
- `medium` — 中等思考
- `high` — 深度思考
- `xhigh` / `max` — 极限思考 (仅部分模型)

### 关键行为

1. **Interleaved thinking** — 新模型自动支持 tool call 之间的交错思考
2. **Summarized thinking** — 返回的思考内容为摘要（非原始 token）
3. **Thinking block preservation** — Opus 4.5+/Sonnet 4.6+ 默认保留全部历史思考块
4. **Display control** — `"summarized"` 或 `"omitted"` 控制返回内容的可见性
5. **Pricing** — 思考 token 按输出 token 计费，但可见内容可能少于计费 token

---

## 十、文件索引

| 文件 | 作用 |
|------|------|
| `@earendil-works/pi-agent-core/dist/agent.js` | Agent state 存储 thinkingLevel |
| `@earendil-works/pi-agent-core/dist/types.d.ts` | `ThinkingLevel` 类型定义 |
| `@earendil-works/pi-ai/dist/providers/anthropic.js` | Anthropic thinking 映射逻辑 |
| `@earendil-works/pi-ai/dist/providers/openai-completions.js` | OpenAI thinking 映射逻辑 |
| `@earendil-works/pi-ai/dist/providers/simple-options.js` | budget 计算 & clamp 逻辑 |
| `pi-coding-agent/dist/core/model-registry.js` | thinkingLevelMap schema |
| `pi-coding-agent/dist/core/model-resolver.js` | 模型选择时的 thinking 解析 |
| `pi-coding-agent/docs/models.md` | thinkingLevelMap 配置文档 |
| `pi-coding-agent/docs/settings.md` | thinkingBudgets 配置文档 |
| `sigil/lib/sigil/agent/provider/anthropic.ex` | Sigil Anthropic extended_thinking 实现 |
| `sigil/lib/sigil/agent/provider/stepfun.ex` | Sigil StepFun provider |
