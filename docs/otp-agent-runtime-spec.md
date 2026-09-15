# Sigil OTP Agent Runtime Spec

> 日期: 2026-05-17  
> 状态: Mostly implemented — OTP runtime phases landed; base ConversationTranscript/Delivery boundary landed; real SNS/Webhook adapters still pending  
> 范围: 重构 Sigil session / agent run 生命周期，使 LiveView、SNS/Webhook、CLI、MCP 等入口共享同一套 Coordinator/Runner API。

## 背景

本 spec 最初针对的 runtime 问题已经实施过一轮。当前代码不再由 `SigilWeb.WorkspaceLive` 直接启动 agent run：

```elixir
Sigil.Agent.Coordinator.add_message(conversation_id, content, opts)
```

`Sigil.PubSub.Session.start_or_get/1` 已经走 `Sigil.SessionSupervisor`；active run 已经由 `Sigil.Agent.Runner` 和 per-run `Sigil.Agent.RunSupervisor` 管理；`CandidateQueue` 在主运行路径中由 run supervisor 创建并 attach 到 Session。`Sigil.Agent.run/2` 仍保留自建 queue 的兼容路径，但 Runner 会传入外部 `candidate_queue`。

当前 OTP runtime 和基础 conversation transcript / delivery 边界已经落地。剩余缺口集中在真实外部渠道接入：SNS/Webhook inbound resolver、outbound delivery adapter、以及更严格的 transcript schema。后续多个入口会持续验证这条边界：

- LiveView 用户输入
- SNS/Webhook 外部消息
- CLI / local automation
- MCP tool / resource 触发
- Background job / generated extension
- 多个浏览器 tab 订阅同一 conversation

因此，核心原则是：

```text
入口层表达 intent，不拥有 agent runtime。
Coordinator 统一 start/reuse/enqueue/cancel/status。
Runner/AgentServer 拥有 run 状态。
Task 只是耗时执行单元，不是生命周期模型。
Session 负责会话事件、snapshot、replay 和轻量 metadata。
ConversationTranscript 负责跨渠道对话记录，Delivery/Projection 负责把回复送回 LiveView/SNS 等渠道。
```

## 实施现状

截至 2026-05-17，runtime 主线已基本落地，跨渠道 conversation transcript / delivery 的基础边界也已落地。真实 SNS/Webhook adapter、入口 resolver、thinking/schema 收敛仍待后续补齐。

| Area | Status | Current implementation | Gap |
|------|--------|------------------------|-----|
| Coordinator facade | Done | `Sigil.Agent.Coordinator`；LiveView 调 `Coordinator.add_message/3` | SNS/Webhook 入口尚未接入，但 API 已可用 |
| Supervised Session | Done | `Sigil.SessionSupervisor`；`Session.start_or_get/1` 走 DynamicSupervisor | 后续可加 reaper/TTL |
| Task supervision | Done | `Sigil.AgentRunTaskSupervisor`；Runner 使用 `Task.Supervisor.async_nolink/2` | 少量后台任务仍需按用途确认 supervisor 归属 |
| Runner owner | Done | `Sigil.Agent.Runner` owns active run status/task/queue ref | status 里还可继续暴露更完整 run metadata |
| Per-run supervisor | Done | `Sigil.Agent.RunSupervisor` + `Sigil.AgentRunSupervisor`，queue/runner `:one_for_all` | `Sigil.Agent.run/2` 兼容自建 queue 路径仍存在 |
| Candidate queue ownership | Mostly done | 主路径由 RunSupervisor 创建 queue，Session 只 attach/route | 兼容路径需要保留还是最终移除待定 |
| Event recorder | Done | `Sigil.EventRecorder` records `run_start/tool_start/tool_end/run_end/error` | 作为 audit 可用，不承担 transcript/delivery |
| Session store | Done | `Sigil.SessionStore.File` persists snapshot without pid/ref/task | 只保存 runtime snapshot，不保存 transcript/delivery |
| Conversation transcript | Mostly done | `Sigil.ConversationTranscriptStore` behaviour + ConversationStore-backed JSONL；`Sigil.Agent.TranscriptPersistence` 写 inbound/assistant/tool/error | thinking 记录和更严格 schema 仍可补 |
| Channel delivery/projection | Partial | `Sigil.Delivery` behaviour + no-op/default test adapter；LiveView 只做 projection，不再持久化 timeline | 真实 SNS/Webhook adapter 与入口 resolver 仍待接入 |

### 当前代码入口

```text
LiveView send_message
  -> Sigil.Agent.Coordinator.add_message/3
  -> Sigil.Agent.Runner.start_run/3
  -> Sigil.AgentRunSupervisor
     └── Sigil.Agent.RunSupervisor
         ├── Sigil.Agent.CandidateQueue
         └── Sigil.Agent.Runner
             └── Task.Supervisor.async_nolink(Sigil.AgentRunTaskSupervisor, Sigil.Agent.run/2)
  -> Sigil.PubSub.Session.broadcast_event/3
  -> LiveView projection + TranscriptPersistence/Delivery
```

### 当前主要风险

- `WorkspaceLive` 仍保留 `timeline` 这个 projection 名字，后续可改名为 `display_messages` 降低误解。
- `ConversationStore` 仍是 transcript 的第一版物理存储，meta/files/messages 同目录；边界已通过 `ConversationTranscriptStore` 隔离，但实现仍是文件包裹。
- `Sigil.Delivery` 目前只有 no-op/default 和测试 adapter；真实 SNS/Webhook outbound adapter 尚未接。
- SNS/Webhook 入口 resolver 尚未实现：conversation/workspace/model/channel metadata 仍需要入口侧补齐。

## 参考项目结论

本 spec 不是照搬某一个参考项目，而是把几个项目里最适合 Sigil 当前阶段的思路拆开组合：

| 参考项目 | 借鉴思路 | Sigil 对应设计 | 不照搬原因 |
|----------|----------|----------------|------------|
| Gong | `SessionManager -> Registry -> DynamicSupervisor -> Session GenServer`；`SessionReaper` 做 TTL/LRU；Tape 做历史 | `Sigil.SessionSupervisor`、未来 `Sigil.SessionManager`、后续 session reaper/event recorder | Gong 偏 session-centric，不能让 Sigil Session 变成 run/queue/provider loop 的大管家 |
| Anubis | Session GenServer 管状态；`Task.Supervisor.async_nolink/2` 跑耗时请求；terminate 清理 in-flight；Store behaviour 可替换 | `Sigil.AgentRunTaskSupervisor`、Runner 内部 async task、SessionStore behaviour | Anubis 是 MCP protocol server，request/response/task-store 语义比 Sigil agent run 更复杂 |
| Cortex | 长期 `LLMAgent` GenServer 拥有 status/context/steering queue；AgentLoop 由 Task.Supervisor 执行；SignalRecorder/Tape 记录事件 | `Sigil.Agent.Runner` 拥有 run 状态和 CandidateQueue；`Sigil.EventRecorder` | Cortex 的 SignalHub/Jido/Memory/Tape-first 体系太重，不作为第一阶段前置 |
| Sagents | `Session` 是 facade；`AgentServer` 是状态 owner；每个 agent 一棵 `AgentSupervisor` 小监督树；`initial_subscribers` 避免订阅竞态；persistence 只保存 conversation data | `Sigil.Agent.Coordinator`、`Sigil.Agent.RunSupervisor`、Runner 作为状态 owner、SessionStore 不保存 pid/task | Sagents 的 FactoryRouter/Horde/Publisher/Subscriber/sub-agent tree 很完整，但第一阶段照搬会过度设计 |

组合后的 Sigil 方向：

```text
Gong 的 session lifecycle
+ Anubis 的 task execution safety
+ Cortex 的 Runner/steering ownership
+ Sagents 的 Coordinator/per-agent supervisor boundary
+ Sagents 的 dual-view transcript/projection persistence
```

## 第一原则：UI 与 Agent Runtime 解耦

这次 GPT/sui2api 接入暴露出的多个问题，本质上不是单个 provider 或 LiveView bug，而是 UI、runtime event 和持久化展示历史三者耦合：

- LLM 返回正常、标题生成正常，但 UI 没显示内容：说明 runtime 成功，展示链路失败。
- 同一 delta 显示多次：说明 UI 订阅状态影响了展示历史。
- 热重载时列表清空：说明 LiveView assigns 曾经承担了 source of truth。
- 切换会话再切回来消息消失：说明会话切换依赖旧的 UI 内存副本，没有从持久化展示层重读。
- 后续 SNS/Webhook 接入后，消息可能完全绕过 LiveView；如果展示历史仍由 LiveView 写入，外部入口天然会丢 UI 历史。

因此 Sigil 的第一原则应调整为：

```text
LiveView is a projection, not the owner.
Agent runtime emits events, not UI state.
ConversationTranscript is the source of truth for cross-channel conversation history.
Delivery routes outbound assistant/tool/error output back to the originating channel when needed.
```

### 三层边界

```text
Intent Layer
  LiveView / SNS / Webhook / CLI / MCP
  -> 只表达用户/外部系统 intent
  -> 调 Coordinator.add_message/3
  -> 可做 optimistic user echo，但不能成为唯一持久化路径

Runtime Layer
  Coordinator / Runner / Session / CandidateQueue / Provider / Tools
  -> 拥有 run 生命周期、工具执行、streaming、cancel/status
  -> 发 run_start/message_delta/tool_start/tool_end/run_end 事件
  -> 不关心具体 UI 怎么折叠、分组、渲染

Transcript Layer
  ConversationTranscriptStore / ConversationStore transcript API
  -> 持久化跨渠道 transcript：inbound user/SNS/Webhook message、assistant text、tool card、tool result、error、thinking
  -> LiveView mount/select_conversation 从 transcript store 读
  -> SNS/Webhook 后续查询或审计也从 transcript store 读

Delivery / Projection Layer
  LiveView projection / SNS delivery / Webhook callback / CLI output
  -> LiveView 收到 PubSub 事件只做 projection 更新；重连后可从 transcript store 恢复
  -> SNS/Webhook 入口需要记录 source/channel，并把 assistant outbound 内容送回对应渠道
```

### Transcript Message 不等于 Agent Message

Agent 内部消息是给 LLM 看的，可以被 compact、summarize、rewrite：

```elixir
%Sigil.Agent.Message{role: :assistant, content: "...", tool_calls: [...]}
```

Transcript message 是给 conversation participants 和审计看的，应该是 append/update-friendly 的记录。它不是只给 Web UI 用，SNS/Webhook/CLI 同样需要读写：

```elixir
%{
  "id" => "msg_...",
  "conversation_id" => "...",
  "run_id" => "...",
  "channel" => "live_view" | "sns" | "webhook" | "cli",
  "direction" => "inbound" | "outbound" | "internal",
  "message_type" => "assistant",
  "content_type" => "text",
  "content" => %{"text" => "..."},
  "status" => "streaming",
  "sequence" => 12,
  "metadata" => %{}
}
```

两者不能互相替代：

- Agent Message 可以被压缩；Transcript Message 必须保留完整跨渠道对话历史。
- Agent Message 可以合并工具上下文；Transcript Message 应拆成 channel 可消费的 text/tool/thinking/error 记录。
- Agent Message 属于推理上下文；Transcript Message 属于产品对话历史、渠道投递和审计。

### LiveView 的职责约束

LiveView 允许：

- 发送 intent 到 Coordinator
- 订阅 session/conversation topic
- optimistic append 当前用户输入
- 根据 transcript/projection 记录渲染 timeline
- 在收到事件时更新本地 projection

LiveView 不允许：

- 直接启动 `Sigil.Agent.run/2`
- 直接拥有 CandidateQueue
- 把 assigns 里的 timeline 当长期历史
- 作为 assistant streaming 持久化的唯一写入者
- 在切换会话时复用旧 conversation map 作为最终数据

这条约束优先级高于局部 UI 便利性。只要出现 LiveView 和 runtime 共同写同一段 timeline，就应视为需要重构。

### SNS/Webhook 对架构的要求

SNS/Webhook 入口没有 LiveView 进程，但它本身也是 conversation channel。用户不仅期待之后打开 UI 能看到完整历史，也期待 LLM 的回复能回到 SNS/Webhook。因此外部入口必须走同一套 transcript + delivery 链路：

```text
SNS/Webhook
  -> resolve conversation/workspace/model
  -> append inbound transcript message (channel=sns/webhook, direction=inbound)
  -> Coordinator.add_message(..., source: :sns)
  -> Runner emits events
  -> TranscriptStore persists assistant/tool/error outbound records
  -> Delivery routes assistant outbound text back to SNS/Webhook
  -> LiveView later loads the same transcript
```

这意味着 transcript store 和 delivery 不能藏在 LiveView 里，也不能只由 `handle_info({:agent_event, ...})` 间接写入。

### Gong

可借鉴：

- `SessionManager -> Registry -> DynamicSupervisor -> Session GenServer`
- `SessionReaper` 负责 TTL/LRU 回收
- Tape 作为长期历史层

不照搬：

- 不让 Sigil Session 吃掉所有 Agent runtime 职责。

### Anubis

可借鉴：

- Session GenServer 串行管理协议状态
- `Task.Supervisor.async_nolink/2` 执行耗时请求
- terminate 时清理 in-flight task / waiter
- `Session.Store` behaviour 分离持久化实现

不照搬：

- MCP protocol request/response 复杂度不进入 Sigil agent 主流程。

### Cortex

可借鉴：

- `LLMAgent` GenServer 拥有 `status`、`llm_context`、`steering_queue`
- Agent loop 放到 `Task.Supervisor`
- `SignalRecorder` / Tape 负责 audit 和回放

不照搬：

- 不引入全局 SignalHub / Jido / Memory 大系统作为本次重构前置条件。

### Sagents

可借鉴最多：

- `Session` 是 lifecycle facade，不是进程
- `AgentServer` 是状态 owner
- 每个 agent 有一棵小监督树：

```text
AgentsDynamicSupervisor
└── AgentSupervisor per agent_id
    ├── AgentServer
    └── SubAgentsDynamicSupervisor
```

- `initial_subscribers` 关闭 “start 后再 subscribe” 的竞态
- `AgentPersistence` 只保存 conversation data，不保存 runtime id / pid / task
- LiveView 通过 Coordinator/Session API 启动和订阅，不直接启动 run

不第一阶段照搬：

- Horde abstraction
- FactoryRouter 完整体系
- direct Publisher/Subscriber 替换 Phoenix.PubSub
- SubAgentsDynamicSupervisor

## 目标架构

### 当前已落地形态

```text
Sigil.Application
├── SigilWeb.Telemetry                                # 已有
├── Sigil.Repo                                        # 已有
├── Ecto.Migrator                                     # 已有
├── DNSCluster                                        # 已有
├── Phoenix.PubSub                                    # 已有
├── Registry: Sigil.SessionRegistry                   # 已有
├── Registry: Sigil.AgentRunRegistry                  # 已有
├── Registry: Sigil.AgentRunSupervisorRegistry        # 已有
├── Registry: Sigil.AgentRunQueueRegistry             # 已有
├── Sigil.Tool.Registry                               # 已有
├── Sigil.SessionSupervisor                           # 已有
├── Sigil.AgentRunSupervisor                          # 已有
├── Task.Supervisor: Sigil.AgentRunTaskSupervisor     # 已有
├── Sigil.MCP.RuntimeSupervisor                       # 已有
└── SigilWeb.Endpoint                                 # 已有
```

原第一阶段目标已经超额完成：不仅抽出了 Coordinator，也已经引入 Runner GenServer 和 per-run supervisor tree。

### Runtime 目标形态

```text
Sigil.Application
├── Sigil.SessionSupervisor
│   └── Sigil.PubSub.Session per conversation
├── Sigil.AgentRunSupervisor
│   └── Sigil.Agent.RunSupervisor per active run/conversation
│       ├── Sigil.Agent.Runner
│       └── Sigil.Agent.CandidateQueue
├── Sigil.AgentRunTaskSupervisor
├── Sigil.EventRecorder
└── Sigil.SessionStore.File or DB implementation
```

上述 runtime 目标形态已基本落地。当前成熟度缺口在 Transcript / Delivery Layer：

```text
Sigil.ConversationTranscriptStore
└── Sigil.ConversationTranscriptStore.File

Sigil.Agent.TranscriptPersistence
└── runtime events -> transcript append/update

Sigil.Delivery
├── LiveView projection
├── SNS outbound delivery
└── Webhook callback delivery
```

## 模块职责

### `Sigil.Agent.Coordinator`

新增 facade。所有入口都调用它，不直接启动 agent run。

路径：

```text
lib/sigil/agent/coordinator.ex
```

建议 API（统一 `{:ok, _} | {:error, _}` 惯例，符合 sigil/AGENTS.md 风格约定）：

```elixir
defmodule Sigil.Agent.Coordinator do
  @type source :: :live_view | :sns | :webhook | :cli | :mcp | atom()
  @type action :: :started | :enqueued
  @type ack :: %{action: action(), run_id: String.t() | nil, run_pid: pid() | nil}

  @spec add_message(String.t(), String.t(), keyword()) ::
          {:ok, ack()} | {:error, term()}
  def add_message(conversation_id, content, opts \\ [])

  @spec start_run(String.t(), String.t(), keyword()) ::
          {:ok, ack()} | {:error, :run_in_progress | term()}
  def start_run(conversation_id, content, opts \\ [])

  @spec enqueue_candidate(String.t(), String.t(), keyword()) ::
          {:ok, ack()} | {:error, term()}
  def enqueue_candidate(conversation_id, content, opts \\ [])

  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(conversation_id)

  @spec cancel(String.t()) :: :ok | {:error, :not_running | term()}
  def cancel(conversation_id)
end
```

并发与互斥语义（同一 conversation 强制 one active run）：

```text
start_run/3:
  - idle     -> 启动 run，返回 {:ok, %{action: :started, ...}}
  - running  -> {:error, :run_in_progress}

add_message/3:
  - idle     -> 调用 start_run/3
  - running  -> 调用 enqueue_candidate/3 (deliver_as: :steer)
```

第一阶段行为：

```text
add_message/3
  -> ensure Session exists
  -> if session meta running?:
       Session.enqueue_candidate(..., deliver_as: :steer)
     else:
       start_run(...)
```

必需 opts：

```elixir
[
  workspace_id: String.t() | nil,
  workspace_path: Path.t(),
  model: String.t(),
  provider_config: map(),
  tools: [module()],
  source: source()
]
```

LiveView 可以传完整 opts；SNS/Webhook 入口后续可以通过 conversation/workspace store 补齐 opts。

### `Sigil.SessionSupervisor`

新增 DynamicSupervisor。

路径：

```text
lib/sigil/session_supervisor.ex
```

API：

```elixir
def start_link(opts \\ [])
def start_session(opts)
def stop_session(session_id)
def which_sessions()
```

`Sigil.PubSub.Session.start_or_get/1` 改为：

```elixir
def start_or_get(opts) do
  case Sigil.SessionSupervisor.start_session(opts) do
    {:ok, pid} -> {:ok, pid}
    {:error, {:already_started, pid}} -> {:ok, pid}
    other -> other
  end
end
```

> 注意：不要先 `whereis/1` 再决定是否 `start_session/1`，那是 TOCTOU 竞态。`Registry` via tuple 注册天然幂等，依赖 `{:already_started, pid}` 才是正确的并发模型。当前 [lib/sigil/pubsub/session.ex](file:///Users/box/dev-code/demo/cc-like-elixir/sigil/lib/sigil/pubsub/session.ex) 的 `start_or_get/1` 已经正确处理 `:already_started`，迁移到 `SessionSupervisor` 时必须保留该模式。

### `Sigil.PubSub.Session`

继续作为 session event/snapshot owner。

保留职责：

- seq 分配
- snapshot replay
- `next_turn_messages`
- run metadata
- candidate enqueue routing
- monitor active run pid / queue pid

不新增职责：

- 不直接执行 `Sigil.Agent.run/2`
- 不创建长期 run task
- 不拥有 provider/tool loop
- 不做 conversation history persistence

第一阶段可继续 `attach_run(session_id, run_pid, queue_pid)`；成熟阶段改为：

```elixir
attach_run(session_id, runner_pid, queue_pid, run_id: run_id)
```

> `run_id` 是新引入的标识，由 Coordinator/Runner 在启动 run 时生成（建议 `Ecto.UUID.generate/0`，或 `"run-<ulid>"` 便于日志排序）。它用于：事件携带 `run_id` 标签便于过滤；EventRecorder 文件分片；外部入口（SNS/CLI）后续 `cancel(run_id)` 精确取消而不是按 conversation 一刀切。第一阶段 Session 可以暂时不持有 `run_id`，第二阶段 Runner 出现后再 attach 进 Session metadata。

### `Sigil.Agent.Runner`

第二阶段新增。每个 active run 一个 GenServer。

路径：

```text
lib/sigil/agent/runner.ex
```

职责：

- 管理一次 run 的状态：`:idle | :running | :cancelled | :error | :completed`
- 启动/持有 `CandidateQueue`
- 调用 `Sigil.Agent.run/2` 或更底层 `Turn.run_loop/2`
- 处理 cancel/status
- 向 `Sigil.PubSub.Session` 发事件
- run_end 后清理 queue 并更新 Session

建议 API：

```elixir
def start_link(opts)
def start_run(conversation_id, content, opts)
def cancel(conversation_id)
def status(conversation_id)
def enqueue(conversation_id, content, opts \\ [])
```

### `Sigil.Agent.RunSupervisor`

第三阶段新增。每个 run/conversation 一棵小 supervisor。

路径：

```text
lib/sigil/agent/run_supervisor.ex
```

目标 child tree（顺序很关键）：

```text
Sigil.Agent.RunSupervisor
├── Sigil.Agent.CandidateQueue   # 先启动，无外部依赖
└── Sigil.Agent.Runner            # 后启动，依赖 queue
```

推荐 strategy：

```elixir
Supervisor.init(
  [
    {Sigil.Agent.CandidateQueue, queue_opts},
    {Sigil.Agent.Runner, runner_opts}
  ],
  strategy: :one_for_all,
  max_restarts: 1,
  max_seconds: 5
)
```

原因：

- 一次 run 是一个原子单元，Runner 或 Queue 任一崩溃都意味着这次 run 失败，不应残留半个状态
- `:one_for_all` 保证 Runner 崩溃时 queue 一并清理，queue 崩溃时 Runner 也重启（拿到全新 queue pid，避免持有 stale ref）
- `max_restarts: 1` 防止无限重启刷掉父 DynamicSupervisor —— 真正的"是否重试"由上层 `AgentRunSupervisor` 与 Coordinator 策略决定
- 如果后续增加 sub-agent/tool runtime supervisor，小树更容易扩展

> 注：早期草案曾建议 `:rest_for_one` + queue 在前，但那种策略下 Runner 崩溃不会重建 queue，与"Runner 崩溃时 queue 应一起重建/清理"的需求矛盾，已修正。

### `Sigil.AgentRunTaskSupervisor`

已落地：

```elixir
{Task.Supervisor, name: Sigil.AgentRunTaskSupervisor}
```

当前 Runner 内部使用：

```elixir
Task.Supervisor.async_nolink(Sigil.AgentRunTaskSupervisor, fn ->
  Sigil.Agent.run(...)
end)
```

Runner 通过 task ref 接收结果，避免 task crash 链接杀死 Runner。

## CandidateQueue 归属

主运行路径中，`CandidateQueue` 由 `Sigil.Agent.RunSupervisor` 创建，并通过 Runner 调 `Session.attach_run/3` 注册。`Sigil.Agent.run/2` 仍保留未传 `:candidate_queue` 时自建 queue 的兼容路径。

目标边界：

```text
Session 不创建 queue。
Runner/RunSupervisor 创建 queue。
Session 只登记 queue pid 并路由 enqueue。
```

理由：

- queue 是 run 级资源，不是 session 级资源
- 一个 session 可以有多次 run
- cancel/restart/status 应由 Runner 统一处理
- Session 只负责 “当前 active queue 在哪里”

## 多入口流程

### LiveView

目标：

```text
WorkspaceLive.handle_event("send_message")
  -> Sigil.Agent.Coordinator.add_message(conversation_id, message, opts)
  -> UI 只更新输入框、本地 optimistic user message、订阅事件
```

LiveView 不再调用：

```elixir
Task.start(...)
Sigil.Agent.run(...)
Sigil.Agent.CandidateQueue.start_link(...)
```

### SNS/Webhook

目标：

```text
WebhookController / SnsConsumer
  -> resolve conversation_id / workspace_path / model
  -> Sigil.Agent.Coordinator.add_message(conversation_id, message,
       source: :sns,
       workspace_path: workspace_path,
       model: model,
       provider_config: provider_config
     )
```

返回值不依赖 LiveView 存在。UI 通过 Session snapshot 和 PubSub replay 看到后续事件。

### CLI / Background extension

同样只调用 Coordinator。入口层最多负责鉴权、解析参数、补齐 workspace/model。定时任务属于对话生成的扩展，不属于 Sigil 内核入口。

### MCP

```text
Sigil.MCP.ToolHandler / ResourceHandler
  -> resolve conversation_id from MCP context (session, tool args)
  -> Sigil.Agent.Coordinator.add_message(conversation_id, payload,
       source: :mcp,
       workspace_path: ws,
       model: model,
       provider_config: provider_config
     )
  -> 返回 {:ok, ack} 给 MCP client（含 run_id 便于后续 status/cancel 查询）
```

MCP 触发的 run 与 LiveView 共享 Session，事件通过同一套 PubSub 广播；MCP client 通过 `Coordinator.status/1` 轮询或后续扩展的 MCP notification 拿到结果。

### Coordinator 与 ConversationStore 的边界

Coordinator **不直接读** `Sigil.ConversationStore` / `Sigil.WorkspaceStore`。所有 opts 由调用方显式传入，原因：

- 测试时无需 stub 整个 store
- SNS/MCP 等无状态入口可以自带 payload，不强制走 DB
- 避免 Coordinator 变成隐式的 conversation 解析器

为了避免各入口重复解析逻辑，可在 `Sigil.Agent.Coordinator.Resolver` 或入口侧（如 `SigilWeb.ConversationContext`）提供 helper：

```elixir
@spec resolve_opts(String.t()) :: {:ok, keyword()} | {:error, term()}
def resolve_opts(conversation_id)
# 返回 [workspace_id:, workspace_path:, model:, provider_config:, tools:]
```

入口先调用 helper、再传给 `Coordinator.add_message/3`。helper 是纯查询，不影响 Coordinator 主流程。

## 事件与订阅

第一阶段保留 Phoenix.PubSub：

```text
Session.broadcast_event(session_id, kind, payload)
  -> Phoenix.PubSub.broadcast("session:<id>")
  -> append snapshot
```

成熟阶段可评估 Sagents-style direct `Publisher/Subscriber`，但不是当前必需。

原因：

- Sigil 已经有 PubSub.Session 和 LiveView replay
- Phoenix.PubSub 对单机/普通 Phoenix app 足够
- direct Publisher 能减少跨节点广播噪音，但会引入订阅 map、presence re-subscribe 复杂度

## 持久化与记录

### `Sigil.EventRecorder`

第四阶段做，优先于 `SessionStore`。

路径：

```text
lib/sigil/event_recorder.ex
```

落地（workspace-local 为默认，避免多 workspace 事件混在一起）：

```text
<workspace_path>/.sigil/events/<session_id>.jsonl   # 默认
~/.sigil/events/<session_id>.jsonl                  # 无 workspace 时 fallback
```

记录：

- `run_start`
- `tool_start`
- `tool_end`
- `run_end`
- `error`
- optional final assistant message

不记录或节流：

- `message_delta`
- 高频 thinking delta

### `Sigil.SessionStore`

第四阶段做。定义 behaviour，先 File 实现。

保存 runtime snapshot，不保存完整 conversation history。

```elixir
defmodule Sigil.SessionStore do
  @callback save(String.t(), map(), keyword()) :: :ok | {:error, term()}
  @callback load(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  @callback delete(String.t(), keyword()) :: :ok | {:error, term()}
  @callback list_active(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  @callback update(String.t(), map(), keyword()) :: :ok | {:error, term()}
end
```

保存字段：

- `seq`
- last snapshot events
- `running?`
- `model`
- `next_turn_messages`

不保存：

- pid
- task ref
- active queue pid
- open port
- provider connection

## 分阶段实施计划

### Phase 0: Conversation Transcript + Delivery Boundary — Mostly Done

主要借鉴：

- Sagents: Agent internal state 与 user-facing records 分离
- 当前 Sigil `ConversationStore` 的 JSONL messages 文件可以作为第一版 transcript store，不必先引入 DB

已新增：

- `Sigil.ConversationTranscriptStore` behaviour
- `Sigil.ConversationTranscriptStore.ConversationStore`，ConversationStore-backed JSONL 实现
- `Sigil.Agent.TranscriptPersistence`，从 inbound intent 和 runtime events 写 transcript records
- `Sigil.Delivery` behaviour，用于把 assistant outbound 内容送回 SNS/Webhook/CLI 等 channel

仍待补：

- `Sigil.ConversationTranscript.Message` 或更严格 map schema/normalizer
- 真实 SNS/Webhook delivery adapter
- SNS/Webhook inbound resolver

当前 API：

```elixir
defmodule Sigil.ConversationTranscriptStore do
  @callback list(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback append(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback update(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback replace_all(String.t(), [map()], keyword()) :: :ok | {:error, term()}
end
```

```elixir
defmodule Sigil.Delivery do
  @callback deliver(map(), keyword()) :: :ok | {:error, term()}
end
```

当前实现直接包住现有：

```text
ConversationStore.load_messages/1
ConversationStore.append_message/2
ConversationStore.replace_messages/2
```

但对外不要再暴露 `timeline` 是 conversation meta 的一部分。`timeline` 只是 LiveView projection 的旧名字，应逐步迁移为 `display_messages`。

已修改：

- `WorkspaceLive.mount/select_conversation` 只从 `ConversationTranscriptStore.list/2` 加载 conversation transcript
- `WorkspaceLive.handle_event("send_message")` 可以 optimistic render，但 inbound transcript 的持久化由入口层/Coordinator 或 TranscriptPersistence 完成
- `WorkspaceLive.handle_info({:agent_event, ...})` 只更新本地 projection，不作为唯一持久化路径
- `ConversationPersistence` 已替换为 `TranscriptPersistence`，明确它只写 transcript
- tool_start/tool_end 也写 transcript message/update，而不是只存在 LiveView assigns 中
- SNS/Webhook source 的 run 必须携带 channel metadata，assistant outbound text 持久化后交给 `Sigil.Delivery` 投递；测试 adapter 已验证链路

验收现状：

- LiveView crash / hot reload 不影响正在运行的 agent
- 同一 conversation 切换出去再切回来，消息从 transcript store 恢复
- 没有 LiveView 打开的 SNS/Webhook-like inbound 消息，打开 UI 后也能看到完整 inbound/assistant/tool/error 历史
- SNS/Webhook-like inbound 触发的 LLM 回复能通过 delivery behaviour 回到原 channel；真实 adapter 未接
- 多个 LiveView tab 订阅同一 conversation 时，不会因为重复订阅导致 transcript 重复写入
- `WorkspaceLive` 不再通过 `ConversationStore.upsert(... timeline ...)` 持久化 transcript；只保存 editor/files state
- assistant streaming 的持久化发生在 runtime callback/Runner 侧，而不是 LiveView 侧

### Phase 1: Coordinator + Basic Supervision — Done

主要借鉴：

- Sagents: `Session`/Coordinator facade 收口所有入口
- Gong: `SessionSupervisor` + `Registry` 管 session 生命周期
- Anubis/Cortex: 用 `Task.Supervisor` 替代裸 `Task.start`

已落地：

- `Sigil.Agent.Coordinator`
- `Sigil.SessionSupervisor`
- `Registry, name: Sigil.AgentRunRegistry`
- `{Task.Supervisor, name: Sigil.AgentRunTaskSupervisor}`

已修改：

- `Sigil.PubSub.Session.start_or_get/1` 走 `SessionSupervisor`
- `WorkspaceLive` 调用 `Coordinator.add_message/3`
- `Sigil.Agent.run/2` 内部创建 `CandidateQueue` 的兼容路径仍保留；Runner 主路径传入外部 queue

现状：

- LiveView (`SigilWeb.WorkspaceLive`) 内全部 `Task.start` 调用消失，所有 agent run 启动都走 `Coordinator.add_message/3`；其他后台型 Task 必须挂在 `Sigil.AgentRunTaskSupervisor` 或其他显式 supervisor 下
- `Session.start_or_get/1` 启动的 session 出现在 `Sigil.SessionSupervisor` 下，且 `which_sessions/0` 可列出
- 现有 PubSub.Session / CandidateQueue / WorkspaceLive 测试通过
- 新增 Coordinator 单元测试覆盖 idle start、running enqueue、missing opts error
- `AgentRunTaskSupervisor` 下的 task crash 不会影响 Coordinator 进程（验证 `Task.Supervisor` 的隔离收益）
- 并发两次 `start_or_get(session_id: same)` 返回同一 pid（验证 `:already_started` 路径正确）

相关测试：

```text
test/sigil/session_supervisor_test.exs
test/sigil/agent/coordinator_test.exs
```

### Phase 2: Runner GenServer — Done

主要借鉴：

- Cortex: `LLMAgent` GenServer 拥有 status/context/steering state
- Sagents: `AgentServer` 拥有 execute/cancel/resume/status 和 task ref
- Anubis: 耗时执行用 async task，Runner 只接收结果并更新状态

已落地：

- `Sigil.Agent.Runner`

已修改：

- Coordinator 启动 Runner，而不是直接启动 task
- Runner 用 `Task.Supervisor.async_nolink/2` 执行 `Sigil.Agent.run/2`
- Runner 持有 task ref，处理 success/error/DOWN/cancel

现状：

- `Coordinator.status/1` 返回 Runner 状态
- `Coordinator.cancel/1` 可终止 active run
- LiveView crash 不影响 active run
- task crash 会广播 `run_end status: error`

相关测试：

```text
test/sigil/agent/runner_test.exs
```

### Phase 3: Per-run Supervisor + Queue Ownership — Mostly Done

主要借鉴：

- Sagents: 每个 agent 一棵 `AgentSupervisor` 小监督树
- Cortex: steering queue 属于 agent/runtime，而不是 UI/session

已落地：

- `Sigil.Agent.RunSupervisor`
- `Sigil.AgentRunSupervisor` DynamicSupervisor

已修改：

- `CandidateQueue` 由 RunSupervisor/Runner 创建
- `Sigil.Agent.run/2` 接收外部 `candidate_queue` 时不再创建 queue；未传外部 queue 时仍保留自建兼容路径
- Session 仅 attach 和 route

现状：

- queue 生命周期与 run 绑定
- run cancel 后 queue sealed
- stale queue 不接收新 candidate
- 同一 conversation 同时最多一个 active run

相关测试：

```text
test/sigil/agent/run_supervisor_test.exs
test/sigil/agent/candidate_queue_test.exs
```

### Phase 4: EventRecorder — Done

主要借鉴：

- Cortex: `SignalRecorder` 记录系统事件，过滤高频 chunk
- Gong: Tape/history 作为后续回放和调试基础

已落地：

- `Sigil.EventRecorder`

已修改：

- `Session.broadcast_event/3` 记录重要事件

现状：

- jsonl 文件不含 API key/token
- 高频 delta 不造成巨大文件
- run error 可通过 jsonl 复盘

相关测试：

```text
test/sigil/event_recorder_test.exs
```

### Phase 5: SessionStore — Done

主要借鉴：

- Anubis: `Session.Store` behaviour，存储实现可替换
- Sagents: state serializer 不保存 runtime id / pid / task，只保存可恢复数据

已落地：

- `Sigil.SessionStore`
- `Sigil.SessionStore.File`

已修改：

- Session init 尝试 load snapshot
- Session 在重要状态变化后 save/update

现状：

- Session crash/restart 后可恢复 snapshot 和 next_turn_messages
- 不恢复 pid/task/queue
- 与 `ConversationStore` 职责不混淆

相关测试：

```text
test/sigil/session_store/file_test.exs
```

## 非目标 / 已延期事项

以下事项仍不属于当前已落地 runtime 范围，或需要独立 spec：

- Horde/distributed registry
- direct Publisher/Subscriber 替换 Phoenix.PubSub
- Redis/DB session store（当前已有 file-backed `SessionStore.File`）
- 完整 replay UI（当前有 Session snapshot + LiveView 局部恢复，但 transcript/delivery 边界未完成）
- Extension Registry GenServer 化
- Tool Registry source/owner 权限系统
- SessionReaper / TTL / LRU 回收
- `run_id` 级别的 cancel/status 外部 API
- SNS/Webhook/MCP 入口侧 resolver

这些可以后续独立 spec。

## 关键设计决策

### 为什么先抽 Coordinator

因为入口会变多。LiveView、SNS、CLI、后台扩展如果各自启动 run，会导致：

- 重复 run
- 状态不一致
- cancel/status 无统一语义
- queue 路由不清晰
- 测试只能覆盖 UI 路径

Coordinator 先收口 API，内部实现可以从 `Task.Supervisor` 平滑演进到 `Runner`。

### 为什么 Session 不拥有 run

Session 的核心价值是 session-level event stream 和 replay。Run 是执行生命周期，应该由 Runner/AgentServer 管。

避免：

```text
Session = event store + run manager + queue owner + persistence + cancellation + provider loop
```

目标：

```text
Session: session state and event snapshot
Runner: active run state and execution
Coordinator: lifecycle facade
Recorder/Store: persistence
```

### 为什么第一阶段不直接照搬 Sagents

Sagents 的 per-agent supervisor、Publisher/Subscriber、FactoryRouter、Persistence 很成熟，但一次性照搬会带来过多概念。Sigil 当前最紧迫的问题是：

```text
LiveView owns runtime
Session not supervised
Task not supervised
```

所以原计划先解决入口收口和基础 supervision，再逐步引入 Runner 小监督树。当前这条 runtime 路线已经基本完成；后续不应重复重构 runtime，优先补 ConversationTranscript/Delivery boundary。

## 建议测试清单

已存在/应保留测试：

```text
test/sigil/session_supervisor_test.exs
test/sigil/agent/coordinator_test.exs
test/sigil/agent/runner_test.exs        # Phase 2
test/sigil/event_recorder_test.exs      # Phase 4
test/sigil/session_store/file_test.exs  # Phase 5
```

Runtime 回归必测：

- `Session.start_or_get/1` idempotent
- duplicate session returns same pid
- supervised session can be found by `Session.whereis/1`
- Coordinator idle path starts run task
- Coordinator running path enqueues candidate
- missing workspace/model/provider opts returns structured error
- WorkspaceLive no longer owns `Task.start`

ConversationTranscript + Delivery boundary 已新增/应保留测试：

- LiveView mount/select_conversation 从 ConversationTranscriptStore 读取，而不是从 conversation assign 旧副本读取
- LiveView `message_delta/tool_start/tool_end/run_end` 只更新 projection，不作为唯一持久化路径
- Runtime path 持久化 inbound/assistant/tool/error transcript messages，即使没有 LiveView 进程
- SNS/Webhook 模拟入口调用 Coordinator 后，UI 后打开能看到完整 transcript
- SNS/Webhook 模拟入口收到 LLM outbound 回复 delivery
- 多 LiveView tab 订阅同一 conversation 不重复写 transcript messages

## Open Questions

- `conversation_id` 是否等同于 `session_id`，还是后续区分 UI conversation 与 runtime session？
- SNS/Webhook 入口如何从外部 payload 映射到 workspace/model/provider config？
- 是否允许同一 conversation 有多个 concurrent runs，还是强制 one active run？
- Runner 是否应支持 resume interrupt，还是先只支持 cancel/status？
- EventRecorder 是否写到 `~/.sigil`，还是 workspace-local `.sigil/events`？

默认建议：

- 第一阶段继续使用 `conversation_id == session_id`
- 同一 conversation 强制 one active run
- 外部入口必须显式提供或可解析 workspace/model
- recorder 默认 user-level `~/.sigil/events`，后续可配置
