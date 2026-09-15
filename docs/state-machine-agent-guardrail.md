# State Machine Agent Guardrail — 架构分析

> 把 [Statewright](https://github.com/statewright/statewright) 的状态机护栏思想用 Elixir 原生方式落到 Sigil 内核中。

---

## 1. 问题陈述

AI Agent 在执行复杂任务时常见退化模式：

| 退化模式 | 表现 | 根因 |
|---------|------|------|
| **循环读取** | 同一文件读 5 遍不动手 | 工具集太宽，模型选择瘫痪 |
| **过早修改** | 没读完理解就开始写代码 | edit/write 工具对所有 turn 可用 |
| **跳过验证** | 改完不跑测试就声称完成 | 没有强制验证阶段 |
| **权限滥用** | 规划阶段就跑 bash 装依赖 | 工具无阶段约束 |

**核心洞察**：模型不需要在所有时刻看到所有工具。按阶段收缩可用工具集 → 减少决策空间 → 提高成功率。

---

## 2. Sigil vs Statewright：架构对比

```
Statewright（外挂式）                   Sigil 可做（内建式）
─────────────────────                   ──────────────────
CLI wrapper 拦截工具调用                Turn 层 tool_defs 过滤
JSON 配置文件定义状态机                 GenStateMachine OTP behaviour
外部进程管理生命周期                    原生 State struct 携带 phase
```yaml
                                       ┌──────────────────────────┐
                                       │     State Machine        │
                                       │  ┌──────┐  ┌──────────┐ │
                                       │  │Plan  │→ │Implement │ │
                                       │  │read  │  │read/edit │ │
                                       │  │grep  │  │write/bash│ │
                                       │  └──────┘  └──────────┘ │
                                       │       ↓          ↓      │
                                       │  ┌──────────┐  ┌──────┐ │
                                       │  │ Verify   │← │Done  │ │
                                       │  │bash/test │  │(none)│ │
                                       │  │read      │  └──────┘ │
                                       │  └──────────┘           │
                                       └──────────────────────────┘
```

**关键区别**：Sigil 不需要外部 wrapper——状态机直接嵌入 Agent loop 内部，在 `Turn.do_turn/2` 每次调用 provider 前动态过滤 `tool_defs`。

---

## 3. 现有架构的天然接缝

### 接缝 1：Tool Registry 已有分层概念

```elixir
# lib/sigil/tool/registry.ex:127
def register_beam_tools(level \\ :all) do
  allowed = case level do
    :safe_only -> Map.drop(@beam_tools, [:eval, :process_info, :session_steer])
    :all       -> @beam_tools
  end
end
```

`@beam_tools` 按安全等级分类的模式可直接泛化为 Phase→Tools 映射。

### 接缝 2：Turn 层每次从 Registry 拉 tool_defs

```elixir
# lib/sigil/agent/turn.ex:235
tool_defs = Sigil.Tool.Registry.tool_defs()
```

这是**唯一注入点**——在此行之后插入过滤逻辑即可控制每个 turn 可用的工具。

### 接缝 3：State 已有 status + tool_guard 字段

```elixir
# lib/sigil/agent/state.ex:29-30
@type status :: :running | :completed | :error | :max_turns | ...
# state.ex:25 — tool_guard_denied_calls
tool_guard_denied_calls: [map()]
```

添加 `phase` 字段、复用 `tool_guard` 机制，改动最小。

### 接缝 4：Middleware pipeline 已存在

```elixir
# lib/sigil/agent/config.ex:293-298
defp default_middleware do
  [Sigil.Agent.Middleware.Logger,
   Sigil.Agent.Middleware.Security,
   Sigil.Agent.Middleware.ToolGuard]
end
```

新 middleware `PhaseGuard` 可以插入 pipeline，在 `:after_tool_request` 和 `:before_provider_call` 钩子中执行阶段转换和工具过滤。

---

## 4. 设计方案

### 4.1 数据结构

```elixir
# lib/sigil/agent/phase_machine.ex

defmodule Sigil.Agent.PhaseMachine do
  @moduledoc """
  定义 Agent 执行阶段及各阶段可用工具集。

  阶段定义：
    - :understanding  — 理解任务，收集信息（工具最少）
    - :planning       — 制定方案（只读 + 分析工具）
    - :implementing   — 执行修改（全部工具开放）
    - :verifying      — 验证结果（测试 + 只读）
    - :completed      — 完成，拒绝工具调用

  阶段推进由规则引擎驱动（非 LLM self-report），
  基于最近 N 个 turn 的工具调用序列自动判定。
  """

  @phases [:understanding, :planning, :implementing, :verifying, :completed]

  # 各阶段允许的工具名称列表
  @phase_tools %{
    understanding: ~w(read grep file_search mcp__cog__code_query mcp__cog__code_explore
                      mem_recall ext__beam__docs ext__beam__source ext__beam__schemas),
    planning:      ~w(read grep file_search mcp__cog__code_query mcp__cog__code_explore
                      mem_recall ext__beam__docs ext__beam__source ext__beam__schemas
                      ext__beam__sql ext__beam__sup_tree),
    implementing:  :all,        # 所有工具开放
    verifying:     ~w(read bash grep file_search ext__beam__docs),
    completed:     []           # 无工具可用
  }

  @doc "Return the list of tool names allowed in the given phase."
  @spec tools_for(atom()) :: :all | [String.t()]
  def tools_for(phase), do: Map.get(@phase_tools, phase, [])

  @doc """
  Determine the next phase based on tool usage history.

  规则（优先级从高到低）：
    1. 若最近一次 tool_call 是 bash + test 命令 → :verifying
    2. 若最近 3 个 turn 内出现了 edit/write → :implementing
    3. 若累计 read/grep 超过 3 次且无 edit/write → :planning
    4. 默认 → :understanding
  """
  @spec evaluate([map()], atom()) :: atom()
  def evaluate(tool_call_history, current_phase)

  # ... 实现细节
end
```

### 4.2 注入 Turn 层（唯一修改点）

```elixir
# lib/sigil/agent/turn.ex — 在 :do_turn 函数中，line 235 之后

# 当前代码：
tool_defs = Sigil.Tool.Registry.tool_defs()

# 改为：
all_tool_defs = Sigil.Tool.Registry.tool_defs()
phase = State.get_phase(state)  # 从 state 中读取当前阶段
tool_defs = PhaseMachine.filter_tool_defs(all_tool_defs, phase)

# 若当前阶段无可用工具且模型请求了 tool_use → 强制 end_turn
```

### 4.3 Middleware 集成

```elixir
# lib/sigil/agent/middleware/phase_guard.ex

defmodule Sigil.Agent.Middleware.PhaseGuard do
  @behaviour Sigil.Agent.Middleware

  @impl true
  def run(:before_provider_call, state, _opts) do
    # 基于 state.tool_calls 历史评估是否需要阶段转换
    new_phase = Sigil.Agent.PhaseMachine.evaluate(
      state.tool_calls, State.get_phase(state)
    )
    state = State.put_phase(state, new_phase)
    {:ok, state}
  end

  @impl true
  def run(:after_tool_request, state, _opts) do
    # 工具调用后重新评估阶段
    new_phase = Sigil.Agent.PhaseMachine.evaluate(
      state.tool_calls, State.get_phase(state)
    )
    state = State.put_phase(state, new_phase)
    {:ok, state}
  end

  # 其他钩子透传
  def run(_hook, state, _opts), do: {:ok, state}
end
```

### 4.4 配置集成（settings.jsonc）

```jsonc
// .sigil/settings.jsonc
{
  "phase_guard": {
    "enabled": true,               // 总开关
    "mode": "auto",                // "auto" | "manual" | "off"
    "phases": {
      "understanding": {
        "tools": ["read", "grep", "file_search", "mem_recall"],
        "max_turns": 5,            // 超时自动升级到 planning
        "auto_advance": true
      },
      "implementing": {
        "require_plan": true       // 必须在 planning 阶段产出了 plan 才能进入
      }
    },
    "overrides": {                 // 按工作区或 task 覆盖
      "workspace:critical": { "enabled": false }
    }
  }
}
```

### 4.5 工具分类标注

```elixir
# 在 Tool behaviour 中增加可选的 phase_hint/0 callback
defmodule Sigil.Agent.Tool do
  @callback phase_hint() :: atom() | nil
  # :read_only | :analysis | :mutation | :verification | nil
  # nil = 由 PhaseMachine 的 @phase_tools 映射决定
end
```

各工具标注示例：

| 工具 | phase_hint |
|------|-----------|
| read | `:read_only` |
| grep | `:read_only` |
| file_search | `:read_only` |
| edit | `:mutation` |
| write | `:mutation` |
| bash | 上下文决定（测试命令 = `:verification`，其他 = `:mutation`） |
| mem_recall | `:analysis` |
| mem_learn | `:analysis` |

---

## 5. 与 Statewright 的关键差异

| 维度 | Statewright | Sigil 方案 |
|------|-------------|------------|
| **运行方式** | 外挂 CLI wrapper | 内核级 Middleware |
| **状态定义** | JSON/YAML 配置文件 | Elixir 模块（编译时检查 + 热更新） |
| **阶段推进** | LLM self-report（不靠谱） | 规则引擎自动判定（工具序列模式匹配） |
| **工具过滤** | 进程级拦截 | Registry 层 `tool_defs` 过滤 |
| **调试可见性** | 外部日志 | `:telemetry` + ETS + LiveView 实时展示 |
| **语言** | TypeScript | Elixir（与 Sigil 同栈） |

### 为什么规则引擎优于 LLM self-report

Statewright 让 LLM 自己报告当前阶段，这是最薄弱的一环：
- 模型可能撒谎（"我已经完成了验证" 实际上没跑测试）
- 模型可能误判（刚读完一个文件就声称 "implementing"）

Sigil 方案用**工具调用序列模式**自动判定：
```
连续 3 次 read/grep 且无 edit/write → 自动从 understanding → planning
出现 edit 或 write → 自动从 planning → implementing
出现 bash + "test" → 自动从 implementing → verifying
连续 2 次 read 且无 edit/write/bash → 自动从 verifying → completed
```

这不依赖 LLM 的自我报告，对模型是透明的。

---

## 6. 实现优先级

| Phase | 内容 | 影响范围 | 预计 |
|-------|------|---------|------|
| **P0** | PhaseMachine 模块（阶段定义 + 工具映射 + 评估规则） | 新增 1 文件 | 半天 |
| **P1** | PhaseGuard Middleware | 新增 1 文件 | 半天 |
| **P2** | Turn 层 tool_defs 过滤注入 | 修改 turn.ex ~5 行 | 1 小时 |
| **P3** | State 增加 phase 字段 | 修改 state.ex ~3 行 | 半小时 |
| **P4** | settings.jsonc 集成 | 修改 config.ex ~10 行 | 1 小时 |
| **P5** | 测试 + 日志 + telemetry | 测试文件 + 可观测性 | 1 天 |
| **P6** | LiveView 可视化阶段流转 | Dashboard 新增 panel | 后续 |

---

## 7. 与定时任务扩展的关系

定时任务不是 Sigil 内核功能，而是对话生成并热插拔的普通扩展。扩展触发 `Coordinator.add_message` 后，状态机护栏仍约束 Agent 如何执行：

```
定时任务扩展触发 Coordinator.add_message(prompt)
  └→ Agent loop 启动
       └→ PhaseMachine 约束工具可用性
            └→ Understanding → Planning → Implementing → Verifying → Completed
```

扩展负责 **"何时执行"**，状态机护栏负责 **"如何执行"**。两者正交，可独立开发、合并使用。

---

## 8. 风险与边界

- **规则引擎可能误判**：如果 Agent 在 planning 阶段用 `bash` 查看文件列表，会被错误推进到 implementing → 需要规则可配置 + 回退机制
- **对现有 Turn 逻辑零破坏**：`tool_defs` 过滤在 Registry 返回后、Provider 调用前，若 `phase_guard.enabled = false` 则完全透传
- **强制阶段可能降低灵活性**：某些简单任务不需要 4 阶段 → `mode: "auto" | "relaxed" | "strict"` 三级强度