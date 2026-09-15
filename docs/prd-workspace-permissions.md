# PRD: Workspace Permission & Tool Approval System

> 版本: 2.0
> 状态: Draft
> 目标迭代: Post-MVP(优先级高于 Skills 快捷输入)
> 关联: `STATUS-CURRENT.md` → "工具审批" + "WebUI 实用化补强"

---

## 参考项目:sagents 权限设计分析

### 核心设计

[sagents](https://github.com/boxboxsir/sagents) 通过 **Middleware(中间件)** 而非独立拦截层实现权限控制。

#### 1. HumanInTheLoop 中间件

**文件**: `sagents/lib/sagents/middleware/human_in_the_loop.ex`

```elixir
# 配置:指定哪些工具需要人工审批
interrupt_on = %{
  "write_file" => true,                              # 默认审批选项
  "delete_file" => %{allowed_decisions: [:approve, :reject]}  # 不允许 edit
}
```

`init/1` 解析配置:
```elixir
# human_in_the_loop.ex:L~140
def init(opts) do
  interrupt_on = Keyword.get(opts, :interrupt_on, %{})
  config = %{interrupt_on: normalize_interrupt_config(interrupt_on)}
  {:ok, config}
end
```

`normalize_interrupt_config/1` 处理三种输入格式:
```elixir
# human_in_the_loop.ex:L~170
defp normalize_interrupt_config(interrupt_on) when is_map(interrupt_on) do
  Map.new(interrupt_on, fn
    {tool_name, true} when is_binary(tool_name) ->
      {tool_name, %{allowed_decisions: [:approve, :edit, :reject]}}
    {tool_name, false} ->
      {tool_name, %{allowed_decisions: []}}
    {tool_name, %{allowed_decisions: decisions} = config}
    when is_binary(tool_name) and is_list(decisions) ->
      {tool_name, config}
  end)
end
```

`check_for_interrupt/2` — 扫描 tool_calls,返回 :continue 或 {:interrupt, data}:
```elixir
# human_in_the_loop.ex:L~210
def check_for_interrupt(%State{} = state, config) do
  case get_last_assistant_message_with_tools(state.messages) do
    nil -> :continue
    assistant_message ->
      tool_calls = assistant_message.tool_calls || []
      interrupt_requests = collect_interrupt_requests(tool_calls, config.interrupt_on)
      if interrupt_requests == [] do
        :continue
      else
        interrupt_data = build_interrupt_data(interrupt_requests, config.interrupt_on)
        {:interrupt, interrupt_data}
      end
  end
end
```

三种决策:

| 决策 | 含义 | 实现位置 |
|------|------|---------|
| `:approve` | 按原参数执行 | `human_in_the_loop.ex:L~113` `@default_decisions` |
| `:edit` | 用户可修改参数后执行 | `process_decisions/3` 验证 `:arguments` 字段 |
| `:reject` | 跳过执行 | 同上 |

**工作方式**:
- 不是执行前拦截,而是在 **LLM 返回之后、工具执行之前** 检查
- 检查最后一个 assistant 消息中是否有 `tool_calls` 匹配 `interrupt_on` 配置
- 匹配到 → 返回 `{:interrupt, state, interrupt_data}`,**暂停执行**
- 不匹配 → `:continue`,正常执行

#### 2. 中断数据结构

```elixir
%{
  action_requests: [
    %{tool_call_id: "call_123", tool_name: "write_file", arguments: %{...}},
    %{tool_call_id: "call_456", tool_name: "delete_file", arguments: %{...}}
  ],
  review_configs: %{
    "write_file" => %{allowed_decisions: [:approve, :edit, :reject]},
    "delete_file" => %{allowed_decisions: [:approve, :reject]}
  },
  hitl_tool_call_ids: ["call_123", "call_456"]
}
```

#### 3. Resume 流程

**文件**: `sagents/lib/sagents/middleware/human_in_the_loop.ex`

```elixir
# L~115 — 默认决策: approve + edit + reject
@default_decisions [:approve, :edit, :reject]
```

HITL 中间件**总是放在中间件栈最后**
Resume 时,**非 HITL 工具自动批准**(`%{type: :approve}`),只有 HITL 工具使用用户决策:
```elixir
# human_in_the_loop.ex:L~270 — build_full_decisions
# 非 HITL 工具 -> %{type: :approve}
# HITL 工具 -> 使用用户决策
Enum.map(all_tool_calls, fn tc ->
  if tc.call_id in hitl_tool_call_ids do
    Map.fetch!(decisions_by_id, tc.call_id)
  else
    %{type: :approve}
  end
end)
```

如果 auto-approved 工具自己产生了新的 interrupt(如 `ask_user`),通过 `{:cont, state}` 交给后面的中间件处理:
```elixir
# human_in_the_loop.ex:L~200 — run_decisions
case find_interrupt_results(tool_result_message) do
  [] -> {:ok, state_with_results}
  interrupted ->
    interrupt_data = build_interrupt_data_from_results(interrupted)
    {:cont, %{state_with_results | interrupt_data: interrupt_data}}
end
```

> **关键点**: `{:cont, state}` 会继续遍历 middleware list,让下一个 middleware 处理新产生的 interrupt。
> 这要求 HITL 必须在栈最后,否则后面的 middleware 收不到。

#### 4. AskUserQuestion 中间件

**文件**: `sagents/lib/sagents/middleware/ask_user_question.ex`

提供一个 `ask_user` tool,agent 调用时触发 `{:interrupt, ...}`:
```elixir
# L~330 — execute_ask_user 触发中断
defp execute_ask_user(args, config) do
  # ... 验证参数 ...
  question_data = %{
    type: :ask_user_question,
    question: question,
    response_type: response_type,
    options: options,
    allow_other: ...,
    allow_cancel: ...,
    context: ...
  }
  {:interrupt, "Waiting for user response...", question_data}
end
```

`handle_resume` 支持冷启动恢复:
```elixir
# ask_user_question.ex:L~160 — 冷启动时 resume_data=nil
# 不尝试解析答案,直接展示 interrupt
def handle_resume(_agent, %State{interrupt_data: %{type: :ask_user_question}} = state, nil, _config, _opts) do
  {:interrupt, state, state.interrupt_data}
end

# ask_user_question.ex:L~175 — resume_data 有数据则解析
def handle_resume(agent, %State{interrupt_data: %{type: :ask_user_question}} = state, response, _config, _opts) do
  resolve_single_question(agent, state, state.interrupt_data, response)
end
```

`restorable_interrupt?` 支持冷启动恢复:
```elixir
# ask_user_question.ex
@impl true
def restorable_interrupt?(%{type: :ask_user_question}), do: true
def restorable_interrupt?(_other), do: false
```

#### 5. 关键设计决策

| 决策 | sagents 做法 | 代码参考 | 参考价值 |
|------|-------------|----------|---------|
| 拦截位置 | after_model(LLM 返回后、执行前) | `mode/steps.ex:L30` `check_pre_tool_hitl` | 比 pre-execution guard 更清晰 |
| 中间件栈顺序 | HITL 必须最后 | `human_in_the_loop.ex:L62` `maybe_append` | 确保 auto-approve 的非 HITL 工具能正常执行 |
| Resume 策略 | 非 HITL 自动批准 | `human_in_the_loop.ex:L270` `build_full_decisions` | 避免二次弹窗 |
| 决策类型 | approve / edit / reject 三档 | `human_in_the_loop.ex:L113` `@default_decisions` | edit 很有用(安全地修改危险参数) |
| 持久化 | `restorable_interrupt?` 支持冷启动恢复 | `ask_user_question.ex:L165` | Sigil 也应该支持 |

---

## 1. 问题陈述

当前 Sigil 在工具执行前**没有任何权限拦截机制**。LLM 返回的 tool_use 请求会直接进入 `Tool.Executor` 执行,没有任何"这个工具能不能在当前工作区运行"的检查。

### 现有安全层的局限性

| 层 | 现状 | 缺口 |
|----|------|------|
| `PathValidator` | 工作区路径边界 + symlink 逃逸检测 | 只检查文件路径,不检查"是否允许执行 bash" |
| `ShellPathGuard` | 危险命令模式提取 | 只审计,不拦截 |
| `Security Middleware` | `:after_tool_execution` 占位 | 不检查执行前的权限 |
| `WorkspaceSettings` | 模型限制 + BEAM tools 开关 | 没有工具级权限控制 |
| `WorkspaceStore` | 工作区列表 CRUD | 没有 per-workspace 工具白名单/黑名单 |

### 各 Agent 权限模型参考

| 维度 | Codex | Claude Code | Sigil 现状 |
|------|-------|-------------|-----------|
| 工具审批模式 | `AppToolApproval::Auto/Prompt/Approve` | `permissions.allow/deny` 列表 | **无** |
| 配置格式 | TOML `permissions` 表 | JSON `permissions` | **无** |
| 工作区隔离 | `:workspace` / `:read_only` / `:danger_full_access` | 隐式 workspace | **无** |
| 实时交互 | exec 权限弹窗 + TUI 选择 | CLI prompt / headless 自动 | **无** |
| Per-tool 粒度 | `default_tools_approval_mode` + per-tool override | `Bash(*)`, `Read`, `Edit`... | **无** |

### 用户痛点

1. **新工作区 = 完全信任**:添加一个新工作区,LLM 自动获得完全权限,没有中间选项。
2. **不知道 LLM 要做什么**:LLM 发起了 `bash` 或 `edit`,执行完了才知道,没有事前确认。
3. **信任度分级的成本太高**:当前要么全部允许(危险),要么全部禁止(无用),没有"阅读允许 + 编辑需确认 + bash 危险命令禁止"这样的分级。
4. **无法工作区级定制**:开源工作区和生产工作区应该有不同权限,但当前没有 per-workspace 工具权限配置。

---

## 2. 目标

### 核心目标
在工具执行前引入**三层权限控制**,让每个工作区可以定义不同工具的风险级别和审批策略:

```
审批模式  │  行为
──────────┼──────────────────────────
auto      │  无需确认,直接执行
prompt    │  向用户弹出确认,等待批准/拒绝/本次会话记忆
deny      │  直接拦截,不执行
```

### 设计原则

1. **工作区级配置优先**:权限策略跟随工作区,通过 `.sigil/settings.jsonc` 管理。
2. **渐进式信任**:新工作区默认更严格,用户可以逐步放宽。
3. **不破坏现有流程**:auto 模式 = 当前行为,prompt 需用户确认,deny 直接阻断。
4. **参考 Codex `AppToolApproval`**:Auto / Prompt / Approve 三档映射到 auto / prompt / deny。
5. **参考 Claude Code**:`permissions.allow` / `permissions.deny` 的 allowlist/denylist 模式作为补充。
6. **LiveView 交互**:prompt 模式在 Web UI 弹出确认卡片,无需降级到终端。

---

## 3. 现状分析

### 3.1 工具执行热路径

```
Turn.handle_tool_use/3
  → Executor.execute_all_with_details/2
    → partition_by_concurrency/2 (sequential / concurrent)
      → execute_one/4
        → fetch_tool/2              ← 从 Registry 查找
        → entry.executor.(input, ctx) ← 执行
```

参考 sagents 的设计,**拦截点选在 `Turn.handle_tool_use/3` 中 tool_calls 解析之后**,在工具执行之前做一次全量检查。而不是在 Executor 内部插桩。

优势:
- 与 sagents `check_pre_tool_hitl` 对齐:LLM 返回后 → 检查 → 执行
- 不侵入 `Executor` 内部逻辑
- 可以在一个地方完成所有 tool_calls 的审批决策,支持批量批准
- 通过中间件 `after_tool_request` hook 接入,保持与现有架构兼容

#### 现有 Turn.handle_tool_use/3 代码（插入点）

> **文件**: `lib/sigil/agent/turn.ex`

```elixir
# L232-247 — 当前 tool_use 处理入口
{:ok, %{stop_reason: :tool_use, messages: new_msgs, usage: usage} = response} ->
  Logger.debug(
    "[Turn] provider returned tool_use new_msgs=#{length(new_msgs)} " <> ...
  )
  # ← [插入点] 在此处调用 ToolGuard 中间件检查
  handle_tool_use(state, new_msgs, opts)
```

```elixir
# L475+ — handle_tool_use 当前结构
defp handle_tool_use(%State{} = state, new_msgs, opts) do
  tool_calls = extract_tool_calls(new_msgs)        # L476
  tool_names = Enum.map(tool_calls, & &1[:name])   # L478
  # ← [插入点] 在此处插入 ToolGuard 审批检查
  Enum.each(tool_calls, fn call ->                 # L484
    tool_use_id: call[:id],                        # L486
    # ...
  end)
  case Executor.execute_all_with_details(tool_calls, state) do  # L494
```

### 3.2 当前 `WorkspaceSettings` 结构

```jsonc
{
  "models": { "allow": { "providers": {} } },
  "tools": {
    "beam": { "auto": true, "eval": false },
    "explicit": []
  }
}
```

> **文件**: `lib/sigil/workspace_settings.ex`
> `explicit` 当前是字符串列表(BEAM 工具显式启用),需要扩展为 approval 模式对象。

### 3.3 已有可用的基础设施

| 基础设施 | 可用于权限系统 | 参考代码 |
|---------|--------------|----------|
| `WorkspaceSettings` | 配置读写已就绪 | `lib/sigil/workspace_settings.ex:47` `load/1`, `ensure_file/1` |
| `WorkspaceStore` | 工作区 CRUD | `lib/sigil/workspace_store.ex` |
| `Coordinator.validate_workspace_model_policy/1` | 工作区级验证模式参考 | `lib/sigil/agent/coordinator.ex:144` |
| `SigilWeb.WorkspaceLive` | LiveView 交互入口 | `lib/sigil_web/live/workspace_live.ex` |
| PubSub | 审批事件广播到 LiveView | `lib/sigil/pubsub/session.ex` |
| `Sigil.Agent.Middleware` | `:after_tool_request` 钩子可用 | `lib/sigil/agent/middleware.ex:18` hook 定义 |
| `Agent.Turn` | `handle_tool_use/3` 控制流节点 | `lib/sigil/agent/turn.ex:475` |
| `Security Middleware` | 中间件框架参考 | `lib/sigil/agent/middleware/security.ex`

---

## 4. 功能需求

### FR-1: 工具审批模式枚举

**优先级**: P0

```elixir
defmodule Sigil.Permissions.ApprovalMode do
  @type t :: :auto | :prompt | :deny
end
```

| 模式 | 含义 |
|------|------|
| `:auto` | 直接执行,不拦截 |
| `:prompt` | 向用户确认后执行 |
| `:deny` | 直接拒绝,返回错误 |

### FR-2: 工作区工具权限配置

**优先级**: P0

扩展 `.sigil/settings.jsonc` 的 `tools` 字段:

```jsonc
{
  "tools": {
    // 默认审批模式(所有未显式列出工具的行为)
    "default_mode": "auto",

    // 全局允许/拒绝列表(match 优先于 default_mode)
    "allow": ["read", "file_search", "mem_*"],
    "deny": ["bash(rm:*)", "bash(git push:*)", "edit(.env)"],

    // 按工具名覆盖审批模式
    "per_tool": {
      "bash": "prompt",       // bash 总是需要确认
      "write": "prompt",      // 写文件需要确认
      "edit": "prompt",
      "read": "auto",         // 读文件无需确认
      "file_search": "auto",
      "mem_*": "auto"
    },

    // MCP 工具(按 server 或 * 全局)
    "mcp": {
      "*": "prompt",          // 所有 MCP 工具默认需确认
      "filesystem__*": "auto" // 但 filesystem server 的例外
    }
  }
}
```

**优先级顺序**(从高到低):
1. `deny` 列表(含 glob pattern)→ `:deny`
2. `per_tool` 覆盖 → 对应模式
3. `allow` 列表 → `:auto`
4. `default_mode` → fallback

### FR-3: `ToolGuard` 执行前检查

**优先级**: P0

在 `Turn.handle_tool_use/3` 中 tool_calls 解析之后、`Executor.execute_all_with_details/2` 之前插入检查。

```elixir
# Turn.handle_tool_use/3 中的插入点
{:ok, %{stop_reason: :tool_use, messages: new_msgs} = response} ->
  tool_calls = extract_tool_calls(new_msgs)

  case ToolGuard.check_all(tool_calls, state) do
    {:all_approved, calls} ->
      handle_tool_use_continue(state, calls, opts)

    {:needs_approval, pending, auto_approved} ->
      # pending = 需要用户审批的工具
      # auto_approved = 自动批准的(非 HITL 工具)
      # 返回 interrupt,等待用户决策
      {:interrupt, state, build_interrupt_data(pending, auto_approved)}

    {:denied, denied_calls} ->
      # 将 denied 工具替换为错误结果
      handle_tool_use_with_denials(state, tool_calls, denied_calls, opts)
  end
```

参考 sagents 的 `check_pre_tool_hitl` + `HumanInTheLoop.check_for_interrupt` 模式:
- 检查**最后一个 assistant 消息**中的 tool_calls
- 只检查**尚未执行**的 tool_calls(已执行的不重复检查)
- 返回三种状态:全部批准 / 需要审批 / 部分拒绝

### FR-4: LiveView 审批弹窗

**优先级**: P0

参考 sagents `HumanInTheLoop` + `AskUserQuestion` 的设计,当需要审批时:

1. **暂停** 执行,进入 `:interrupted` 状态
2. **PubSub 广播** `tool_approval_requested` 事件,包含 `action_requests`(工具名 + 参数摘要)
3. **LiveView 弹出确认卡片**:
   - 工具名称 + 参数摘要
   - 批准 ✓ / 拒绝 ✗ / 编辑并执行 ✎ 三个按钮
4. **用户操作**:
   - 批准 → `type: :approve`,按原参数执行
   - 拒绝 → `type: :reject`,跳过该工具
   - 编辑 → `type: :edit`,用户修改参数后执行
5. **Resume**:`Coordinator` 或 `Runner` 接收决策,继续执行
6. **非 HITL 工具**:在 resume 时自动批准(参考 sagents 模式)

**实现方式**:
- 审批状态存在 `State.tool_guard_overrides` + `State.interrupt_data`
- `Turn.run_loop/2` 检测 `:interrupted` 状态后停止循环
- LiveView 通过 `Coordinator` 或 `Runner` 发送 resume 指令
- PubSub `Session` 广播状态变更,LiveView 订阅更新

> 关键:不阻塞 GenServer,而是通过状态机流转(running → interrupted → running)

### FR-5: 拒绝记忆(per-session)

**优先级**: P1

参考 sagents 模式:resume 时非 HITL 工具自动批准。Sigil 在此基础上增加拒绝记忆:

- `:approve` → 不记录(默认行为)
- `:reject` → 将 tool_name → `:deny` 注入 `State.tool_guard_overrides`
- `:edit` → 不记录(单次有效)

```elixir
# State 中
%State{
  ...,
  tool_guard_overrides: %{"bash" => :deny, "write" => :deny}
}
```

后续同名称工具在 `ToolGuard.check_all/2` 中优先查 overrides。

### FR-7: Cold-start 恢复

**优先级**: P1

参考 sagents `restorable_interrupt?` callback:如果审批中断数据可以仅从持久化数据恢复(不依赖进程内状态),则支持在 Runner 重启后恢复中断。

Sigil 的 Session 已有持久化能力,审批中断数据(tool_call_id + tool_name + arguments + 用户决策)可序列化到 session snapshot 中。

---

## 5. 非功能需求

### NFR-1: 性能

- 审批检查是**纯内存 map 查找 + 字符串匹配**,开销 < 1ms。
- `deny`/`allow` glob pattern 编译一次(首次配置加载时),后续查表命中。
- 不影响 auto 模式(直接 `:allow` 路径)的性能。

### NFR-2: 向后兼容

- 没有配置(旧工作区) → 默认 `default_mode: "auto"`,所有工具放行。
- `per_tool` / `allow` / `deny` 全部可选,不提供 = auto。
- 不影响现有 `PathValidator`、`ShellPathGuard`、Security Middleware。

### NFR-3: 配置兼容

- `.sigil/settings.jsonc` 格式不变,新增字段向后兼容(旧版本忽略)。
- `deny` 列表 **不自动覆盖** `per_tool` 的显式 `allow`(避免配置冲突静默生效)。

### NFR-4: 安全

- `deny` 是硬阻断,**不允许用户 prompt 绕过**。
- `:deny` 结果不包含工具输入参数细节(防止信息泄漏)。
- 删除工作区时权限配置跟随 `settings.jsonc` 一起移除。

---

## 6. 设计方案

### 6.1 新增模块

参考 sagents 的中间件模式,将权限审批作为 **Middleware** 接入现有 `Turn.run_loop/2` 中间件体系:

```
lib/sigil/permissions/
├── approval_mode.ex      # :auto/:prompt/:deny 枚举
├── tool_policy.ex        # 从 settings 加载 + 决策函数
├── matcher.ex            # glob pattern 匹配
└── interrupt_data.ex     # 中断数据结构(参考 sagents)

lib/sigil/agent/middleware/tool_guard.ex  # 中间件:检查 → 决策 → interrupt
```

**设计原则**(来自 sagents 验证):

> **文件**: `sagents/lib/sagents/middleware.ex`
> sagents 的 Middleware behaviour 定义了 8 个 callback hooks:
> ```elixir
> # sagents/middleware.ex
> @callback init(config) :: {:ok, middleware_config}
> @callback before_model(State.t(), middleware_config) :: middleware_result()
> @callback after_model(State.t(), middleware_config) :: middleware_result()
> @callback handle_resume(Agent.t(), State.t(), resume_data, middleware_config, opts) :: ...
> @callback restorable_interrupt?(interrupt_data :: map()) :: boolean()
> ```

对齐 sagents 的设计原则:
- 用 Middleware callback(`after_model` / `handle_resume`)实现,不是 pre-execution guard
- 放在中间件栈 **最后**,确保非 HITL 工具在 resume 时能正常执行
- 利用 `{:interrupt, state, interrupt_data}` 暂停执行,不阻塞 GenServer
- 利用 `handle_resume` 处理用户决策
- 利用 `restorable_interrupt?` 支持冷启动恢复

> **文件**: `sagents/lib/sagents/modes/agent_execution.ex`
> sagents 的 pipeline 步骤: `call_llm → check_pre_tool_hitl → execute_tools → check_tool_interrupts`
> Sigil 的 `Turn.run_loop/2` 在 `after_completion` 后插入 ToolGuard 中间件检查。

> **Sigil 现有 Middleware 代码**（`lib/sigil/agent/middleware.ex`）:
> ```elixir
> @type hook ::
>   :session_start
>   | :session_end
>   | :before_completion
>   | :after_completion
>   | :after_tool_request      # ← 可在此 hook 中插入审批检查
>   | :after_tool_execution
>   | :on_error
>
> @callback call(hook(), State.t()) :: State.t() | {:halt, String.t()}
> @spec run(hook(), State.t(), [module()]) :: State.t() | {:halted, String.t()}
> def run(hook, %State{} = state, middleware) when is_list(middleware) do
>   Enum.reduce_while(middleware, state, fn mod, acc ->
>     case mod.call(hook, acc) do
>       {:halt, reason} -> {:halt, {:halted, reason}}
>       %State{} = s -> {:cont, s}
>     end
>   end)
> end
> ```
> ```elixir
> # 现有 Security Middleware（lib/sigil/agent/middleware/security.ex）
> # 当前所有 hook 都是空实现,是扩展的天然位置:
> def call(:before_completion, %State{} = state), do: state
> def call(:after_completion, %State{} = state), do: state
> def call(:after_tool_request, %State{} = state), do: state
> def call(:after_tool_execution, %State{} = state) do
>   # Future: audit tool execution results
>   state
> end
> ```
> 注意:Sigil 当前 Middleware 只返回 `State.t() | {:halt, String.t()}`,**不支持 `{:interrupt, ...}`**。
> 新增 ToolGuard 中间件需要**扩展 Middleware callback 的返回值类型**以支持 interrupt。

### 6.2 修改点

| 文件 | 修改 | 类型 |
|------|------|------|
| `lib/sigil/permissions/approval_mode.ex` | 新增审批模式枚举(:auto/:prompt/:deny) | 新增 |
| `lib/sigil/permissions/tool_policy.ex` | 从 settings 编译 ToolPolicy + 决策函数 | 新增 |
| `lib/sigil/permissions/matcher.ex` | glob pattern 匹配 | 新增 |
| `lib/sigil/permissions/interrupt_data.ex` | 中断数据结构 + 构建函数(参考 sagents) | 新增 |
| `lib/sigil/agent/middleware/tool_guard.ex` | 中间件:after_model 检查 → :continue / {:interrupt} | 新增 |
| `lib/sigil/agent/turn.ex` | `handle_tool_use/3` interrupt 状态处理 | 修改 |
| `lib/sigil/agent/state.ex` | `tool_guard_overrides` + `interrupt_data` field | 修改 |
| `lib/sigil/agent/runner.ex` | resume 时传递决策给 ToolGuard | 修改 |
| `lib/sigil/workspace_settings.ex` | 文档注释说明新增权限字段 | 修改 |
| `lib/sigil_web/live/workspace_live.ex` | 审批弹窗 + handle_resume | 修改 |
| `lib/sigil_web/live/workspace_live.html.heex` | 确认卡片模板 | 修改 |

### 6.3 数据流

参考 sagents `AgentExecution` pipeline:

> **文件**: `sagents/lib/sagents/modes/agent_execution.ex`
> ```elixir
> # L30+ — Pipeline 步骤
> defp do_run(chain, opts) do
>   {:continue, chain}
>   |> call_llm()
>   |> check_max_runs(...)
>   |> check_pause(opts)
>   |> check_pre_tool_hitl(opts)     # ← HITL 检查点
>   |> execute_tools()
>   |> propagate_state(opts)
>   |> check_tool_interrupts(opts)
>   |> maybe_check_until_tool(opts)
>   |> continue_or_done_safe(&do_run/2, opts)
> end
> ```

参考 sagents `check_pre_tool_hitl` 在 `Sagents.Mode.Steps` 中的实现:
> **文件**: `sagents/lib/sagents/mode/steps.ex`
> ```elixir
> # L30+ — HITL 检查步骤
> def check_pre_tool_hitl({:continue, chain}, opts) do
>   middleware = Keyword.get(opts, :middleware, [])
>   hitl_middleware = Enum.find(middleware, fn %MiddlewareEntry{module: module} ->
>     module == HumanInTheLoop
>   end)
>   case hitl_middleware do
>     nil -> {:continue, chain}
>     %MiddlewareEntry{config: config} ->
>       case module.check_for_interrupt(state, config) do
>         {:interrupt, interrupt_data} -> {:interrupt, chain, interrupt_data}
>         :continue -> {:continue, chain}
>       end
>   end
> end
> ```

```
Turn.run_loop/2
  → 中间件 :session_start
  → do_turn/2
    → call LLM
    → 中间件 :after_completion
    → [NEW] ToolGuard 中间件检查
      │
      ├─ 全部 :auto / :allow → :continue
      │   └─► Executor.execute_all_with_details/2
      │
      ├─ 有 :deny → 替换为错误结果
      │   └─► Executor 跳过该工具
      │
      └─ 有 :prompt → {:interrupt, state, interrupt_data}
          │
          ├─ 状态变更为 :interrupted
          ├─ PubSub 广播 status_changed
          ├─ LiveView 弹确认卡片
          └─ 用户决策 → Coordinator.resume → 继续执行
```

**中断数据结构**(参考 sagents):

```elixir
%{
  action_requests: [
    %{tool_call_id: "call_123", tool_name: "bash", arguments: %{command: "rm -rf /"}},
    %{tool_call_id: "call_456", tool_name: "write", arguments: %{path: "config.json"}}
  ],
  review_configs: %{
    "bash" => %{allowed_decisions: [:approve, :reject]},
    "write" => %{allowed_decisions: [:approve, :edit, :reject]}
  },
  hitl_tool_call_ids: ["call_123", "call_456"],
  workspace_path: "/path/to/ws"
}
```

### 6.4 ToolPolicy 决策逻辑

参考 sagents `check_for_interrupt` + settings-based 策略:

```elixir
# 优先级顺序(高 → 低)
def decision(%ToolPolicy{} = policy, tool_name) do
  cond do
    # 1. session overrides(拒绝记忆)
    Map.get(policy.overrides, tool_name) == :deny -> :deny

    # 2. deny list(glob pattern)
    matches_deny?(policy, tool_name) -> :deny

    # 3. per_tool 覆盖
    Map.has_key?(policy.per_tool, tool_name) -> Map.fetch!(policy.per_tool, tool_name)

    # 4. allow list
    matches_allow?(policy, tool_name) -> :auto

    # 5. default_mode
    policy.default_mode
  end
end
```

### 6.5 LiveView 交互

```html
<!-- Approval confirm card -->
<div id="tool-approval-card" class="approval-card" :if={@pending_approval}>
  <div class="approval-title">⚠️ Approve tool call?</div>
  <div class="approval-tool">{@pending_approval.tool_name}</div>
  <div class="approval-args">{@pending_approval.args_summary}</div>
  <button phx-click="approve_tool">✓ Approve</button>
  <button phx-click="deny_tool">✗ Deny</button>
  <button phx-click="deny_tool_remember">✗ Deny &amp; Remember</button>
</div>
```

---

## 7. 与 Codex 的差异对照

### Codex 参考代码

> **文件**: `codex-rs/config/src/mcp_types.rs`
> ```elixir
> # Codex 的审批三档枚举
> #[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Default, JsonSchema)]
> #[serde(rename_all = "snake_case")]
> pub enum AppToolApproval {
>     #[default]
>     Auto,     # 自动执行
>     Prompt,   # 向用户确认
>     Approve,  # 审批通过
> }
> ```
> ```elixir
> # Codex MCP server 配置中的 approval
> pub struct McpServerConfig {
>     pub default_tools_approval_mode: Option<AppToolApproval>,
>     pub enabled_tools: Option<Vec<String>>,
>     pub disabled_tools: Option<Vec<String>>,
>     pub tools: HashMap<String, McpServerToolConfig>,  # per-tool override
> }
> ```
> ```elixir
> # Codex ToolsConfig（codex-rs/tools/src/tool_config.rs）
> pub struct ToolsConfig {
>     pub exec_permission_approvals_enabled: bool,
>     pub request_permissions_tool_enabled: bool,
>     # ...
> }
> ```

> **文件**: `codex-rs/config/src/permissions_toml.rs`
> Codex 使用 TOML permissions 表定义 filesystem + network 沙箱:
> ```toml
> [permissions]
> [permissions.filesystem]
> read = ["/Users/", "$WORKSPACE"]
> write = ["$WORKSPACE"]
>
> [permissions.network]
> enabled = true
> domain_allow = ["api.openai.com"]
> ```

> **文件**: `codex-rs/config/src/config_toml.rs:L800`
> SandboxMode 到 PermissionProfile 的映射:
> ```elixir
> SandboxMode::ReadOnly => PermissionProfile::read_only()
> SandboxMode::WorkspaceWrite => PermissionProfile::workspace_write()
> ```

| 维度 | Codex | sagents | Sigil（本 PRD） |
|------|-------|---------|----------------|
| 审批三档 | `Auto / Prompt / Approve` | approve / edit / reject | `auto / prompt / deny`（ deny = reject） |
| 配置位置 | TOML `[permissions]` | 中间件 opts | JSONC `.sigil/settings.jsonc` |
| 拦截位置 | 沙箱层 | 中间件 after_model | **中间件 after_model**（与 sagents 一致） |
| 决策类型 | 3 档 | 3 种（approve/edit/reject） | 3 档 + :edit（P1） |
| 配置粒度 | Per-tool + per-server | Per-tool `interrupt_on` | per_tool + allow/deny list |
| 暂停机制 | TUI/exec terminal | `{:interrupt, state, data}` | **`{:interrupt, state, data}`**（与 sagents 一致） |
| Resume 策略 | 交互式确认 | auto-approve 非 HITL | **auto-approve 非 HITL**（与 sagents 一致） |
| 持久化恢复 | — | `restorable_interrupt?` | P1，参考 sagents 模式 |
| LiveView 集成 | N/A | N/A | ✅ Web UI 确认卡片 |

### Claude Code 参考代码

> **文件**: `~/.claude/settings.json`
> ```json
> {
>   "permissions": {
>     "allow": [
>       "Bash(*)",
>       "Read", "Edit", "Write",
>       "Glob", "Grep", "Agent"
>     ],
>     "deny": [
>       "Bash(rm:*)",
>       "Bash(git push:*)"
>     ],
>     "defaultMode": "default"
>   }
> }
> ```
> Claude Code 的 allow/deny 是 **工具名 + 参数 glob** 的精确匹配模式。

---

## 8. 测试策略

### 8.1 单元测试

| 模块 | 测试 |
|------|------|
| `ToolPolicy` | 决策优先级(deny > per_tool > allow > default) | `test/sigil/skills/loader_test.exs` 结构参考 |
| `Matcher` | glob pattern 匹配 / `bash(rm:*)` 模式 |
| `ToolGuard` | check/3 三种返回值的正确性 |

### 8.2 集成测试

| 测试 | 覆盖 |
|------|------|
| `deny` 列表拦截 | Executor 不执行,返回 blocked error | `lib/sigil/agent/tool/executor.ex:L49` `execute_all_with_details` |
| `per_tool` 覆盖 | `bash: deny` 确实拦截 bash | `lib/sigil/agent/turn.ex:L476` `extract_tool_calls` |
| `allow` 列表放行 | `read` 在 allow 中正常执行 | `lib/sigil/tool/registry.ex:L97` `@known_tools` |
| 默认 auto | 无配置时所有工具正常执行(向后兼容) |
| LiveView 审批弹窗 | prompt 工具触发确认卡片,批准后执行 | `lib/sigil_web/live/workspace_live.ex:L155` `send_message` |
| Session 记忆 | "拒绝并记住" 后同工具自动 deny |

### 8.3 回归

- `mix test --exclude slow --exclude e2e` 全绿
- 现有 `turn.ex` / `executor.ex` / `coordinator.ex` 测试全绿

---

## 9. 实施阶段

### Phase 1: 核心权限模型（P0）

参考 sagents 权限设计的核心模式：

1. `ApprovalMode` 枚举（:auto/:prompt/:deny）
2. `ToolPolicy` — settings → 决策函数（deny > per_tool > allow > default）
3. `Matcher` — glob pattern 匹配
4. `InterruptData` — 中断数据结构（参考 sagents action_requests + review_configs）
5. 单元测试全绿

### Phase 2: ToolGuard 中间件（P0）

参考 sagents HumanInTheLoop 中间件模式：

6. 新增 ToolGuard middleware（`lib/sigil/agent/middleware/tool_guard.ex`）
   - `init/1`：从 settings 加载 tool_policy
   - `after_model/2`：检查 tool_calls → :continue / {:interrupt}
   - `handle_resume/5`：处理用户决策（approve/edit/reject）
7. `State` 新增 `tool_guard_overrides` + `interrupt_data` field
8. `Turn.handle_tool_use/3` interrupt 状态处理（中断后停止循环）
9. `Runner` resume 路径传递决策
10. 集成测试（deny/allow/auto 三种路径）

关键对齐 sagents 的设计：
- ToolGuard 放在中间件栈最后（maybe_append 模式）
- Resume 时非 HITL 工具自动批准
- {:cont, state} 传递给后续中间件

### Phase 3: LiveView 交互（P0）

11. LiveView 确认卡片（approve / reject / edit）
12. 拒绝并记住 session 记忆 → tool_guard_overrides
13. restorable_interrupt? 冷启动恢复支持（P1）

### Phase 4: 验收

14. mix test --exclude slow --exclude e2e 全绿
15. 手动验证新工作区默认 auto + 配置 deny 后的拦截行为
16. 手动验证 prompt 工具弹窗 + 批准/拒绝流程

---

## 10. 参考

### Codex
- `codex-rs/config/src/mcp_types.rs` → `AppToolApproval`（Auto/Prompt/Approve 三档）
- `codex-rs/config/src/permissions_toml.rs` → filesystem + network permissions
- `codex-rs/config/src/config_toml.rs` → `SandboxMode::ReadOnly/WorkspaceWrite`
- `codex-rs/core/src/config/permissions.rs` → permission profile compilation
- `codex-rs/tools/src/tool_config.rs` → `ToolsConfig` + approval modes

### Claude Code
- `~/.claude/settings.json` → `permissions.allow/deny` 列表

### sagents（核心参考）
- `sagents/middleware/human_in_the_loop.ex` → HITL 中间件完整实现
- `sagents/middleware/ask_user_question.ex` → 用户提问中间件
- `sagents/middleware.ex` → Middleware behaviour + `handle_resume` 机制
- `sagents/modes/agent_execution.ex` → Pipeline 编排（LLM → HITL → tools → propagate）
- `sagents/mode/steps.ex` → `check_pre_tool_hitl` + `propagate_state` steps
- `sagents/agent_server.ex` → `resume/2` + interrupt 状态管理

### Sigil 现有代码
- `lib/sigil/workspace_settings.ex` - 配置读写
- `lib/sigil/security/path_validator.ex` - 路径验证
- `lib/sigil/agent/tool/executor.ex` - 工具执行热路径
- `lib/sigil/agent/middleware.ex` - 中间件 behaviour（与 sagents 对齐的基础）
- `lib/sigil/agent/turn.ex` - agent loop，插入点
- `lib/sigil/pubsub/session.ex` - 状态广播
