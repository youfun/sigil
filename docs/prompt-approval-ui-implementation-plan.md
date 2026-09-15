# Prompt 审批模式 — 前端接入实施规划

> 状态：规划中  
> 关联：`docs/prd-workspace-permissions.md` Phase 3  
> 依赖：Phase 1（权限模型）、Phase 2（ToolGuard 中间件）— **已完成**

---

## 1. 当前真实状态

### 1.1 已完成能力

| 模块 | 文件 | 状态 |
|------|------|------|
| `ApprovalMode` | `lib/sigil/permissions/approval_mode.ex` | ✅ `:auto \| :prompt \| :deny` 解析 |
| `Matcher` | `lib/sigil/permissions/matcher.ex` | ✅ glob / 参数匹配 |
| `ToolPolicy` | `lib/sigil/permissions/tool_policy.ex` | ✅ workspace settings → decision |
| `InterruptData` | `lib/sigil/permissions/interrupt_data.ex` | ✅ 生成 `tool_approval_requested` payload |
| `ToolGuard` | `lib/sigil/agent/middleware/tool_guard.ex` | ✅ `after_tool_request` 支持 pass / deny / interrupt |
| `State` | `lib/sigil/agent/state.ex` | ✅ 已有 `interrupt_data` / `tool_guard_overrides` / denied block 相关字段 |
| `Turn` | `lib/sigil/agent/turn.ex` | ✅ 检测到 `:interrupted` 时 emit `tool_approval_requested` |
| `WorkspaceLive` | `lib/sigil_web/live/workspace_live.ex` | ✅ 已有 session replay、agent event dispatch、独立 `.heex` 模板 |

### 1.2 当前真正缺失的部分

缺的不是“后端完全没有 resume”，而是“当前 interrupt 只能停住，不能从 tool_use 断点继续执行”。

```text
provider.complete()
  -> assistant tool_use message appended into State
  -> ToolGuard returns {:interrupt, state, data}
  -> Turn emits tool_approval_requested
  -> Turn.run_loop returns interrupted State
  -> Runner task ends
```

现在没有以下能力：

1. Runner 持有 interrupted state，并在审批期间保持 run 未完成。
2. 一个“从 tool approval 断点继续”的恢复入口。
3. LiveView 对 `tool_approval_requested` 的 UI 投影与用户决策事件。
4. `Coordinator.resume/2` 对外 API。

### 1.3 当前代码约束

实现必须遵守下面几个真实约束：

1. `Turn` 已经在 interrupt 时 emit `tool_approval_requested`。Runner 不应再次广播同名事件，否则会重复。
2. `Turn` 在 tool_use 分支里先 append 了 assistant tool_use message，再 `increment_turn()`，然后才进入 ToolGuard。resume 不能简单再次调用 provider，否则这批待审批工具调用会悬空。
3. `Agent.run/2` 负责把 `on_event` 包装成 `Session.broadcast_event/3`。resume 若直接调用 `Turn.run_loop/2`，必须手动补齐同等的事件包装，或者提供新的 `Agent.resume_*` 入口复用这层逻辑。
4. `ToolPolicy.overrides` 当前只按 tool name 生效，不支持 `tool_call_id` 级别的一次性 approve。

---

## 2. 设计修正

### 2.1 不采用的方案

以下做法看起来简单，但和当前代码不兼容：

1. 让 Runner resume 后直接再次调用 `Turn.run_loop(interrupted_state, opts)`。
原因：这会重新走 provider，而不是执行被中断的那批 tool calls。

2. 用 `tool_call_id => "auto"` 写入 `tool_guard_overrides` 表示“本次批准”。
原因：`ToolPolicy.decision/2` 当前只按 tool name 查询 overrides。

3. Runner 在 interrupted 分支再次 `Session.broadcast_event(..., :tool_approval_requested, ...)`。
原因：`Turn` 已经 emit 过一次，同一请求会被 UI / snapshot replay 看到两次。

4. LiveView 把 decisions `Jason.encode!/decode!` 后再按 atom key / atom value 模式匹配。
原因：decode 后是 string key，容易踩类型不一致。

### 2.2 采用的方案

采用“Runner 持有 interrupted state + Agent/Turn 提供显式 resume-from-tool-approval 入口”的方案。

关键点：

1. interrupt 发生时，Runner 不结束 run supervisor，不 `mark_run_finished/1`，而是进入 `:awaiting_approval`。
2. resume 不重新请求 provider，而是直接恢复到“执行这批 tool calls”的阶段。
3. 这批 tool calls 的来源是 interrupted state 中最后一条 assistant tool_use message；真正待审批的是 `interrupt_data.hitl_tool_call_ids`。
4. `auto_approved_tool_call_ids` 继续执行。
5. `deny` 的调用转成 `tool_result_block(is_error: true)`，与现有 denied block 机制保持一致。
6. “deny and remember” 只把 tool name 级别的 `:deny` 写入 `tool_guard_overrides`，影响后续 turn；本次恢复不依赖 overrides 来放行。

---

## 3. 目标执行流

### 3.1 当前已工作路径

```text
Coordinator.start_run
  -> Runner.start_link
  -> Task.async_nolink { Agent.run(...) }
  -> Turn.run_loop
  -> 正常 completed / error / max_turns
  -> Runner mark_run_finished
```

### 3.2 prompt 审批目标路径

```text
Coordinator.start_run
  -> Runner.start_link
  -> Task.async_nolink { Agent.run(...) }
  -> Turn.run_loop
     -> provider 返回 tool_use
     -> ToolGuard 返回 {:interrupt, state, data}
     -> emit(:tool_approval_requested, data)
     -> 返回 interrupted state
  -> Runner.handle_info({ref, {:ok, interrupted_state}})
     -> status = :awaiting_approval
     -> 保存 interrupted_state
     -> 不 mark_run_finished
     -> task = nil

用户点击 Approve All / Deny All
  -> LiveView handle_event(...)
  -> Coordinator.resume(conversation_id, decisions)
  -> Runner.handle_call({:resume, decisions})
     -> 启动新 Task
     -> Task 内调用 Agent.resume_after_tool_approval(interrupted_state, decisions, opts)
        -> 从 interrupted state 提取 last tool_use batch
        -> 执行 approved + auto-approved
        -> 注入 denied tool_result blocks
        -> 继续 do_turn，直至 run_end
  -> Runner.handle_info({ref, {:ok, result}})
     -> mark_run_finished
```

---

## 4. 分步实施

### Step 1: Runner 支持 awaiting_approval

**文件**: `lib/sigil/agent/runner.ex`

#### 目标

让 interrupted run 不被当作 completed 收尾。

#### 改动

1. 扩展 Runner struct：

```elixir
defstruct [
  :conversation_id,
  :content,
  :opts,
  :queue_pid,
  :task,
  :status,
  :error,
  :result,
  :interrupted_state
]
```

2. `handle_info({ref, {:ok, result}}, state)` 分支区分 interrupted：

```elixir
case result do
  %Sigil.Agent.State{status: :interrupted} = interrupted ->
    {:noreply,
     %{state | status: :awaiting_approval, interrupted_state: interrupted, task: nil}}

  _ ->
    Sigil.Agent.CandidateQueue.seal(state.queue_pid)
    Session.mark_run_finished(state.conversation_id)
    stop_run_supervisor(state.conversation_id)
    {:noreply, %{state | status: :completed, result: result, task: nil}}
end
```

3. `status/1` 返回 `status: :awaiting_approval` 时，`running?` 仍然可视为 `true`。
原因：对话仍处于活跃 run 生命周期中，只是等待用户决策。

4. `cancel/1` 需要接受 `:awaiting_approval` 状态，不仅仅是 `:running`。

#### 注意

不要在 Runner interrupted 分支里再次广播 `:tool_approval_requested`。当前 `Turn` 已经 emit 过一次。

### Step 2: 新增恢复入口，不重新请求 provider

**文件**:

- `lib/sigil/agent.ex`
- `lib/sigil/agent/turn.ex`

#### 目标

提供一个从“已中断的 tool approval 点”继续执行的入口。

#### 建议接口

在 `Sigil.Agent` 中新增：

```elixir
@spec resume_after_tool_approval(State.t(), [map()], keyword()) :: {:ok, State.t()} | {:error, term()}
def resume_after_tool_approval(%State{} = interrupted_state, decisions, opts) do
  # 与 run/2 一样复用 Session / on_event 包装
end
```

`Sigil.Agent` 负责：

1. 复用现有 tools 注册逻辑。
2. 复用 `session_event_callback/2` 包装。
3. 不重新 `State.init/2`。
4. 调用 `Turn.resume_after_tool_approval/3`。

在 `Sigil.Agent.Turn` 中新增：

```elixir
@spec resume_after_tool_approval(State.t(), [map()], keyword()) :: State.t()
def resume_after_tool_approval(%State{status: :interrupted} = state, decisions, opts) do
  ...
end
```

#### 推荐恢复逻辑

1. 规范化 decisions，统一成内部结构：

```elixir
%{
  "tool_call_id" => "call_x",
  "action" => "approve" | "deny",
  "remember" => true | false,
  "tool_name" => "bash"
}
```

2. 从 interrupted state 中提取最后一批 tool calls。
建议直接复用 `Turn` 里已有的 tool call 提取逻辑，或抽成共享 helper。

3. 用 `interrupt_data.hitl_tool_call_ids` 划分 pending calls。

4. 用 `interrupt_data.auto_approved_tool_call_ids` 划分自动放行 calls。

5. 构造三类结果：

- `approved_calls`
- `denied_blocks`
- `remembered_overrides`

6. 仅对 `approved_calls ++ auto_approved_calls` 执行工具。

7. 将 `denied_blocks` 与执行结果组装成一个最终 `tool_result` message。
这一层建议复用 `execute_tool_calls_with_guard_results/2` 的现有思路，必要时把它重构为可接收显式 denied blocks 的 helper。

8. 清理 interrupt 状态并继续 agent loop：

```elixir
state
|> Map.put(:status, :running)
|> Map.put(:interrupt_data, nil)
|> Map.put(:tool_guard_result_blocks, denied_blocks)
|> Map.put(:tool_guard_overrides, merged_overrides)
|> resume_tool_batch(...)
```

#### 关键原则

resume 后第一步必须是“执行被中断的 tool batch”，不是再次 provider.complete。

### Step 3: Coordinator 新增 `resume/2`

**文件**: `lib/sigil/agent/coordinator.ex`

新增 API：

```elixir
@spec resume(String.t(), [map()]) :: :ok | {:error, term()}
def resume(conversation_id, decisions) when is_binary(conversation_id) and is_list(decisions) do
  Sigil.Agent.Runner.resume(conversation_id, decisions)
end
```

同时在 `Sigil.Agent.Runner` 增加：

```elixir
def resume(conversation_id, decisions) do
  call_runner(conversation_id, {:resume, decisions})
end
```

`handle_call({:resume, decisions}, ...)` 中：

1. 仅在 `status == :awaiting_approval` 时接受。
2. 启动新 task。
3. task 内调用 `Sigil.Agent.resume_after_tool_approval(interrupted_state, decisions, run_opts)`。
4. 清空 `interrupted_state`，恢复 `status: :running`。

### Step 4: LiveView 加入审批卡片

**文件**:

- `lib/sigil_web/live/workspace_live.ex`
- `lib/sigil_web/live/workspace_live.html.heex`

#### 4.1 mount assign

在 mount 中新增：

```elixir
|> assign(:pending_approval, nil)
```

#### 4.2 事件投影

在 `handle_agent_event/2` 中新增：

```elixir
defp handle_agent_event(%{kind: :tool_approval_requested, payload: payload}, socket) do
  socket
  |> assign(:pending_approval, payload)
  |> update_status(%{status: :awaiting_approval})
end
```

这里不需要额外 `:status_changed` 事件；现有 `tool_approval_requested` 已足够驱动 UI。

#### 4.3 审批卡片模板

在 `workspace_live.html.heex` 中渲染 overlay 或 inline card。

建议首版只支持批量决策：

```heex
<%= if @pending_approval do %>
  <div id="tool-approval-overlay" class="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
    <div class="approval-card ...">
      ...
      <%= for request <- @pending_approval.action_requests do %>
        ...
      <% end %>

      <div class="flex gap-3 justify-end">
        <button phx-click="deny_all_tools">Deny All</button>
        <button phx-click="approve_all_tools">Approve All</button>
      </div>
    </div>
  </div>
<% end %>
```

#### 4.4 决策构造

不要把 decisions JSON 编进 DOM 再 decode。

直接在 `handle_event/3` 里从 `socket.assigns.pending_approval` 生成 decisions：

```elixir
def handle_event("approve_all_tools", _params, socket) do
  decisions = build_approve_decisions(socket.assigns.pending_approval)
  ...
end
```

推荐内部格式统一用 string key / string value，避免 atom/string 混用：

```elixir
defp build_approve_decisions(%{action_requests: requests}) do
  Enum.map(requests, fn req ->
    %{
      "tool_call_id" => req.tool_call_id,
      "tool_name" => req.tool_name,
      "action" => "approve"
    }
  end)
end
```

如果 payload 是 string-key map，则同时兼容两种读取方式。

#### 4.5 run_end 时清理

在 `do_handle_run_end/3` 中清掉：

```elixir
|> assign(:pending_approval, nil)
```

在 `mark_run_cancelled/1` 中也同步清理。

### Step 5: deny-and-remember 只影响后续 turn

**文件**:

- `lib/sigil/agent/turn.ex`
- 可能需要补 `lib/sigil/permissions/tool_policy.ex` 的测试

#### 行为定义

1. 本次被拒绝的调用：直接生成 denied result block。
2. 若 `remember == true`：把对应 tool name 写入 `tool_guard_overrides` 为 `:deny`，影响同一 run 的后续 turn。
3. “remember” 不需要让本次调用再经过 ToolGuard 一次。

#### 当前约束

`ToolPolicy.overrides` 现在只按 tool name 查，因此“remember” 做成 tool name 级别是兼容的；“一次性 approve” 不要依赖这个机制。

### Step 6: refresh / replay 行为

当前 `WorkspaceLive.restore_active_session_snapshot/1` 已会 replay session events。

因此首版只需满足：

1. `tool_approval_requested` 事件能进入 Session snapshot。
2. 用户尚未决策前，刷新页面后仍能恢复审批卡片。

不需要为首版新增额外的 `tool_approval_resolved` 事件。
只要在用户点击按钮后立即清本地 assign，并在 run_end / cancel 时兜底清理即可。

---

## 5. 数据流全貌

```text
用户发送消息
  │
  ▼
Coordinator.add_message / start_run
  │
  ▼
Runner.start_link
  │
  ▼
Task.async_nolink { Agent.run(...) }
  │
  ▼
Turn.run_loop
  │
  ├─ provider.complete() -> assistant tool_use
  │
  ├─ ToolGuard.after_tool_request
  │   ├─ all auto -> handle_tool_use
  │   ├─ deny only -> denied blocks + handle_tool_use
  │   └─ has prompt -> {:interrupt, state, interrupt_data}
  │
  ├─ emit(:tool_approval_requested, interrupt_data)
  └─ return interrupted state
      │
      ▼
Runner.handle_info({ref, {:ok, interrupted_state}})
  ├─ status = :awaiting_approval
  ├─ interrupted_state kept in Runner
  └─ run stays open

LiveView receives tool_approval_requested
  ├─ assign(:pending_approval, payload)
  └─ render approval card
      │
      ├─ Approve All
      │   └─ Coordinator.resume(conv_id, decisions)
      │       └─ Runner.handle_call({:resume, decisions})
      │           └─ Agent.resume_after_tool_approval(...)
      │               ├─ execute approved + auto-approved calls
      │               ├─ build tool_result message
      │               └─ continue do_turn
      │
      └─ Deny All
          └─ same resume path
              ├─ no pending call executes
              ├─ denied result blocks injected
              └─ agent sees tool errors and continues / stops naturally
```

---

## 6. 边界情况

| 场景 | 处理 |
|------|------|
| 审批期间刷新页面 | 依赖现有 Session snapshot replay 恢复卡片 |
| 审批期间关闭页面 | Runner 保持 `:awaiting_approval`，直到 resume 或 cancel |
| 审批期间 cancel | Runner 允许 `cancel/1`，清理 interrupted state 并结束 run |
| resume 时 Runner 已不存在 | 返回 `{:error, :not_found}` |
| 多次重复 resume | 仅 `:awaiting_approval` 接受；其它状态返回 `{:error, :not_awaiting_approval}` |
| 同批既有 auto-approved 又有 pending | auto-approved 不展示在卡片中，但 resume 时要一起执行 |
| 全部 deny | 不执行任何 pending tools，直接构造 error tool_result 后继续下一轮 |
| deny + remember | 当前 run 后续同名工具调用自动 deny |

---

## 7. 冷启动恢复范围

本规划首版不解决“应用彻底重启后恢复 interrupted_state”。

当前首版保证的是：

1. 页面刷新可恢复审批 UI。
2. 只要 Runner 进程还在，就可以 resume。

后续 P1 若要支持冷启动恢复，需要补：

1. interrupted_state 的持久化。
2. Session snapshot 与 interrupted_state 的关联恢复。
3. 已审批 / 未审批的显式 resolved 标记。

---

## 8. 测试要点

### 8.1 Runner / Agent 集成测试

| 场景 | 验证 |
|------|------|
| `default_mode: prompt` + 单个 bash | 返回 interrupted，Runner 进入 `:awaiting_approval` |
| approve all | resume 后工具真实执行，产生对应副作用 |
| deny all | resume 后不执行工具，生成 error tool_result |
| pending + auto-approved 混合 | auto-approved 在 resume 后也会执行 |
| deny + remember | 当前 run 后续同名工具自动 deny |
| cancel while awaiting approval | run 正常结束并清理状态 |

### 8.2 Turn 恢复路径测试

重点补 `Turn.resume_after_tool_approval/3`：

1. 能从 interrupted state 找回最后一批 tool calls。
2. 不会重新触发 provider.complete 获取新 tool_use。
3. denied blocks 与 executed blocks 顺序稳定。
4. 恢复后还能继续进入后续 do_turn。

### 8.3 LiveView 测试

| 场景 | 验证 |
|------|------|
| 收到 `tool_approval_requested` | 卡片显示工具名和参数 |
| 点击 Approve All | 调用 `Coordinator.resume/2`，卡片消失 |
| 点击 Deny All | 调用 `Coordinator.resume/2`，卡片消失 |
| 页面刷新且 session snapshot 仍在 | 卡片通过 replay 恢复 |
| run_end / cancel | `pending_approval` 被清空 |

---

## 9. 实施顺序

| 步骤 | 内容 | 预估工时 | 依赖 |
|------|------|---------|------|
| Step 1 | Runner awaiting_approval 生命周期 | 2h | — |
| Step 2 | Agent / Turn 恢复入口 | 4h | Step 1 |
| Step 3 | Coordinator.resume API | 0.5h | Step 1 |
| Step 4 | LiveView 审批卡片与事件 | 2h | Step 3 |
| Step 5 | deny-and-remember 行为收口 | 1h | Step 2 |
| Step 6 | 集成测试与 replay 测试 | 2h | Step 1-5 |
| **合计** | **核心路径** | **~11.5h** | |

---

## 10. 文件清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `lib/sigil/agent/runner.ex` | 修改 | interrupted run 生命周期、resume/cancel |
| `lib/sigil/agent/coordinator.ex` | 修改 | 新增 `resume/2` facade |
| `lib/sigil/agent.ex` | 修改 | 新增 `resume_after_tool_approval/3` 入口，复用 Session event 包装 |
| `lib/sigil/agent/turn.ex` | 修改 | 新增从 interrupted tool batch 恢复执行的逻辑 |
| `lib/sigil_web/live/workspace_live.ex` | 修改 | `pending_approval` assign、agent event、按钮事件 |
| `lib/sigil_web/live/workspace_live.html.heex` | 修改 | 审批卡片 UI |
| `test/sigil/agent/runner_test.exs` | 修改 | awaiting_approval / resume / cancel |
| `test/sigil/agent/turn_test.exs` | 修改 | resume-from-interrupt 逻辑 |
| `test/sigil_web/live/workspace_live_test.exs` | 修改 | 审批卡片渲染与交互 |

---

## 11. 明确不做

首版不包含以下内容：

1. 单工具粒度 approve / deny / edit 按钮。
2. 审批结果持久化到 workspace settings 文件。
3. 应用重启后的 interrupted_state 恢复。
4. Settings 面板里的完整 tool permission 编辑器。

这些都可以在核心链路稳定后再做。
