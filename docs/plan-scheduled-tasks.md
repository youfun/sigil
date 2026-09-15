# 定时任务功能 — 已废弃的实施计划

> 状态：已废弃（2026-08-14）。Sigil 不提供内核 `Scheduler`、`Store`、Cron 或 `ext__schedule__*` 工具；本文仅保留为历史方案，不应继续按此实现。定时任务现在通过对话生成普通扩展，指定项目目录和执行提示词，再用 mount / 磁盘热插拔接入。
>
> 日期：2026-05-18  
> 策略：Ecto 持久化 + Cron 自实现解析器 + 单 GenServer 轮询 + Task 异步触发 Agent.run  
> 原则：不引入外部调度依赖（quantum/crontab），复用现有模式（MemoryStore CRUD、DeferredBootstrap、BEAM 扩展工具）  
> 未来：Web UI 面板、one-shot 一次性任务、秒级精度

## 一、架构概览

```
lib/sigil/schedule/
├── task.ex              # Ecto schema + changeset（照搬 Sigil.Memory.Engram 模式）
├── store.ex             # CRUD 操作（照搬 Sigil.Memory.MemoryStore 模式）
├── cron.ex              # 5字段 cron 解析 + next_run 计算（~80行纯函数）
├── scheduler.ex         # 全局 GenServer，30s 轮询 + Task.async 触发 Agent.run
└── bootstrap.ex         # 延迟启动恢复（照搬 Sigil.MCP.DeferredBootstrap 模式）

lib/sigil/tool/extension/
├── schedule_list.ex     # ext__schedule__list
├── schedule_add.ex      # ext__schedule__add
├── schedule_remove.ex   # ext__schedule__remove
├── schedule_run.ex      # ext__schedule__run（手动触发）
└── schedule_enable.ex   # ext__schedule__enable（启用/禁用）

priv/repo/migrations/
└── 20260518_create_scheduled_tasks.exs

sigil/
├── application.ex        # +Schedule +Schedule.Bootstrap 加入 children
└── tool/registry.ex      # @known_tools 新增 schedule_* 工具（或作为 BEAM 扩展按需注册）
```

```
Sigil.Application
├── Sigil.Schedule.Scheduler          # 全局 GenServer，30s 轮询
│   └── Task.async → Sigil.Agent.run  # 异步触发，不阻塞轮询
├── Sigil.Schedule.Bootstrap          # 延迟 3s，恢复 enabled 任务的 next_run_at
│
└── Sigil.Tool.Registry               # 工具注册（schedule 扩展工具按需或默认注册）
```

## 二、数据模型

### Ecto Schema（`Sigil.Schedule.Task`）

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | `:id` | 主键 |
| `name` | `:string` | 人类可读名称 |
| `workspace_path` | `:string` | 所属工作区绝对路径 |
| `cron_expr` | `:string` | 5字段 cron 表达式，如 `"0 9 * * 1-5"` |
| `prompt` | `:string` | Agent 初始 prompt |
| `model` | `:string` | 可选：指定模型，nil = 默认 |
| `enabled` | `:boolean` | 是否启用，默认 true |
| `last_run_at` | `:utc_datetime` | 上次实际执行时间 |
| `next_run_at` | `:utc_datetime` | 下次计划执行时间 |
| `last_result` | `:string` | 上次执行摘要（前200字符） |
| `error_count` | `:integer` | 连续失败次数，默认 0 |
| `max_errors` | `:integer` | 连续失败上限后自动禁用，默认 3 |
| `timestamps()` | — | `inserted_at` / `updated_at` |

### Changeset 校验

- `name`, `workspace_path`, `cron_expr`, `prompt` 四个字段必填
- `cron_expr` 通过 `Sigil.Schedule.Cron.parse/1` 校验格式合法性
- `max_errors` 不小于 1

### 索引

- `workspace_path` — 按工作区查询
- `enabled` — 轮询过滤
- `next_run_at` — 到期查询（调度器核心查询）

## 三、Phase 分解

### Phase 1：Cron 解析器（`Sigil.Schedule.Cron`）

自实现，约 80 行纯函数。支持：

- **标准 5 字段**：`minute(0-59) hour(0-23) day(1-31) month(1-12) weekday(0-6, SUN=0)`
- **通配符**：`*` 匹配所有值
- **步进**：`*/15` 每 15 单位触发
- **范围**：`1-5`（等效于 `1,2,3,4,5`），`9-17`
- **列表**：`1,15,30`
- **别名**：`@daily` / `@hourly` / `@weekly` / `@monthly` / `@yearly`

```elixir
defmodule Sigil.Schedule.Cron do
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  @spec next_run(String.t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, String.t()}

  # 内部：暴力步进搜索，每分钟 +60s 直到匹配所有字段
  # 最多搜索 2 年（~1M 分钟），超过则返回 error
end
```

**关键设计决策**：不引入 `quantum` / `crontab` 等外部依赖。Cron 解析足够简单，自实现保持项目零额外依赖。

### Phase 2：Ecto Schema + Migration + Store

完全照搬 `Engram` + `MemoryStore` 模式：

```elixir
# Store API
Sigil.Schedule.Store.list_by_workspace(workspace_path)  # → [Task.t()]
Sigil.Schedule.Store.list_due(now)                       # → [Task.t()]  调度器轮询用
Sigil.Schedule.Store.create(attrs)                       # → {:ok, Task.t()}
Sigil.Schedule.Store.mark_completed(task, summary)       # → 更新 last_run_at / next_run_at / 清零 error_count
Sigil.Schedule.Store.mark_failed(task)                   # → 累加 error_count / 超阈值自动 disable
Sigil.Schedule.Store.delete(id)                          # → :ok
Sigil.Schedule.Store.set_enabled(task, true|false)       # → {:ok, Task.t()}
Sigil.Schedule.Store.list_all_enabled()                  # → Bootstrap 恢复用
Sigil.Schedule.Store.update_next_run(task, dt)           # → 更新 next_run_at
```

Migration 命名遵循现有约定：`20260518_create_scheduled_tasks.exs`

### Phase 3：调度器 GenServer（`Sigil.Schedule.Scheduler`）

全局单一进程，30 秒间隔轮询。

**核心逻辑**：

```elixir
defmodule Sigil.Schedule.Scheduler do
  use GenServer
  @poll_ms 30_000

  def handle_info(:poll, state) do
    due = Sigil.Schedule.Store.list_due()

    Enum.each(due, fn task ->
      # 异步执行，不阻塞轮询循环
      Task.start(fn -> execute_task(task) end)
    end)

    schedule_next_poll()
    {:noreply, state}
  end

  defp execute_task(task) do
    case Sigil.Agent.run(task.prompt,
           working_directory: task.workspace_path,
           model: task.model,
           tools: Sigil.Agent.default_tools()
         ) do
      {:ok, final_state} ->
        summary = extract_summary(final_state)
        Sigil.Schedule.Store.mark_completed(task, summary)

      {:error, reason} ->
        Logger.warning("[Scheduler] task '#{task.name}' failed: #{inspect(reason)}")
        Sigil.Schedule.Store.mark_failed(task)
    end
  end
end
```

**设计决策**：

- 使用 `Task.start/1`（fire-and-forget）而非 `Task.async/1` — 不需要等待结果
- 不限制并发数（MVP 阶段假设定时任务数量有限，< 20 个）
- `Sigil.Agent.run` 内部已有超时保护（provider timeout + turn limit），无额外保护需要
- 失败自动降级：连续失败 ≥ `max_errors` → 自动 `enabled = false`

### Phase 4：Bootstrap 恢复（`Sigil.Schedule.Bootstrap`）

完全照搬 `Sigil.MCP.DeferredBootstrap`：延迟 3s 启动，恢复所有 enabled 任务。

**恢复逻辑**：

```
1. 从 DB 读取所有 enabled=true 的任务
2. 对每个任务：
   - 若 next_run_at 为 nil 或已过期 → 调用 Cron.next_run(cron_expr, now) 重新计算
   - 更新 DB
3. 日志记录恢复数量
```

### Phase 5：扩展工具（`ext__schedule__*`）

遵循 `@behaviour Sigil.Agent.Tool` 模式（照搬 `Beam.Sql`），每个工具独立模块。

| 工具名 | 功能 | 关键参数 |
|--------|------|----------|
| `ext__schedule__list` | 列出工作区所有定时任务 | 无（自动取当前工作区） |
| `ext__schedule__add` | 添加定时任务 | `{name, cron, prompt, model?}` |
| `ext__schedule__remove` | 删除定时任务 | `{id}` (或 name，取第一个匹配) |
| `ext__schedule__enable` | 启用/禁用任务 | `{id, enabled: bool}` |
| `ext__schedule__run` | 立即手动触发一次 | `{id}` (Ad-hoc 执行，不影响 next_run_at) |

**工具注册策略**（两种方案）：

| 方案 | 描述 | 适用场景 |
|------|------|----------|
| A. `@known_tools` 默认注册 | 与 Builtin 工具一起在 Registry.init 中加载 | 所有工作区默认可用 |
| B. BEAM extension 按需注册 | 在 `@beam_tools` map 中新增条目，安全策略控制 | 需要权限区分 |

推荐 **方案 A**：定时任务管理是基础设施，不涉及敏感操作（执行的是 Agent.run，其自有权限控制）。

### Phase 6：Application 集成

修改 `lib/sigil/application.ex`，在 `children` 列表中加入（位置：Endpoint 之前，DeferredBootstrap 之后）：

```elixir
Sigil.Schedule.Scheduler,
Sigil.Schedule.Bootstrap,
```

### Phase 7：配置集成（`.sigil/settings.jsonc`）

可选扩展，非 MVP 必需：

```jsonc
"schedules": {
  "enabled": true,     // 工作区级别总开关，false 时调度器跳过此工作区
  "default_max_errors": 3
}
```

### Phase 8：测试

| 测试文件 | 覆盖内容 |
|----------|----------|
| `test/sigil/schedule/cron_test.exs` | Cron 解析 + next_run 计算（核心，需全覆盖） |
| `test/sigil/schedule/task_test.exs` | Schema changeset 校验 |
| `test/sigil/schedule/store_test.exs` | CRUD 操作 |
| `test/sigil/schedule/scheduler_test.exs` | 轮询逻辑、执行触发、失败降级 |
| `test/sigil/tool/extension/schedule_add_test.exs` | 工具行为验收 |

## 四、实现优先级

| 阶段 | 内容 | 预估工作量 | 依赖 |
|------|------|-----------|------|
| **P0 (MVP)** | Phase 1-6 全部 | 核心调度链路 | 无外部依赖 |
| **P1** | Phase 7 配置集成 | settings.jsonc 可选扩展 | P0 完成 |
| **P2** | Phase 8 测试全覆盖 | 回归保护 | P0 完成 |
| **后续** | Web UI 管理面板 | LiveView 页面 | P0+P2 完成 |
| **后续** | One-shot 一次性任务 | `cron_expr = nil` + 到期即删除 | P0 完成 |
| **后续** | 任务执行历史日志 | `scheduled_task_runs` 独立表 | P0 完成 |

## 五、设计边界与取舍

| 决策 | 选择 | 理由 |
|------|------|------|
| 不引入外部 cron 依赖 | 自实现 `Sigil.Schedule.Cron` | ~80行纯函数，保持零额外依赖 |
| 单一全局调度器 | 一个 GenServer 管理所有工作区 | 定时任务不会很多（< 20），无需 DynamicSupervisor 分片 |
| 轮询间隔 30s | `Process.send_after 30_000` | cron 精度到分钟，30s 延迟可接受 |
| 不限制并发 | `Task.start` fire-and-forget | MVP 阶段任务量小，后续可加并发上限 |
| 不在调度器进程内执行 Agent | `Task.start` 异步 | 防止一个任务阻塞所有其他任务 |
| 失败自动降级 | `error_count >= max_errors → enabled = false` | 防止反复报错占满日志 |
| 重启恢复延迟 3s | `Process.send_after 3_000` | 确保 Repo 就绪（参照 MCP.DeferredBootstrap 的 1s 延迟） |
| 不支持分布式锁 | 无 | 单节点 SQLite 应用，无需；未来多节点可用 DB advisory lock |
| 不支持秒级精度 | 无 | 轮询 30s，cron 精度到分钟 |

## 六、与现有模块的耦合点

| 耦合点 | 现有模块 | 交互方式 |
|--------|----------|----------|
| Agent 执行 | `Sigil.Agent.run/2` | 直接调用，传入 prompt + workspace_path |
| 持久化 | `Sigil.Repo` | Ecto CRUD |
| 启动时序 | `Sigil.Application` | children 列表 |
| 工具注册 | `Sigil.Tool.Registry` | `@known_tools` 或 `@beam_tools` |
| 日志 | `Logger` | 标准 Logger.info/warning |

**零改动现有模块** — 全部为新增代码。

## 七、文件清单

```
新增文件（共 12 个）:

lib/sigil/schedule/
├── task.ex                     (~50行)
├── store.ex                    (~70行)
├── cron.ex                     (~80行)
├── scheduler.ex                (~60行)
└── bootstrap.ex                (~40行)

lib/sigil/tool/extension/
├── schedule_list.ex            (~35行)
├── schedule_add.ex             (~50行)
├── schedule_remove.ex          (~30行)
├── schedule_run.ex             (~35行)
└── schedule_enable.ex          (~35行)

priv/repo/migrations/
└── 20260518_create_scheduled_tasks.exs  (~25行)

修改文件（共 1 个）:

lib/sigil/application.ex        (+2 行 children)
```

注：若工具采用 `@known_tools` 注册方式，还需修改 `lib/sigil/tool/registry.ex`（+5 行）。