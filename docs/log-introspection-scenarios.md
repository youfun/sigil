# Sigil 对话内 LLM 获取日志 — 场景分析

## 背景

当用 Sigil 作为 code agent 开发 Elixir 项目时，LLM 需要能读到目标项目的**运行时日志**（`Logger.info/warn/error` 等），而不是靠人去另一个终端 `tail -f`。

## 场景 1：同工作区 / 同 BEAM

```
┌─ Sigil 工作区: my-elixir-project ───────────────────────────────┐
│                                                                  │
│  Sigil 负责启动/管理目标项目的 mix phx.server                     │
│  或者目标项目已经在跑，Sigil 知道它在跑                           │
│                                                                  │
│  ┌─ 对话: "修 bug" ──────────────────────────────────────────┐  │
│  │                                                           │  │
│  │  LLM: 需要看到 my-elixir-project 的 Logger 输出            │  │
│  │                                                           │  │
│  │  现状: ❌ 没有办法。只能人去另一个终端 tail -f              │  │
│  │                                                           │  │
│  │  期望: LLM 调一个工具就能读到日志                          │  │
│  │        支持 level / grep / tail 过滤                      │  │
│  └───────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

### 约束

- 目标项目和 Sigil 在**同一个 BEAM VM** 内（Sigil 启动的 `mix phx.server`）
- Logger 输出默认打到 console，没有持久化
- Sigil 已有的 `ext__beam__*` 工具可以内省当前 VM，但没有日志工具
- Sigil 已有 `Sigil.Log.Store`（Agent 环形缓冲）+ `Sigil.Log.Event`（结构化事件），但没有接到 Logger

### 可能的方案

#### 方案 A：Logger Backend + 环形缓冲 + ext__beam__logs 工具

```
Elixir Logger ──→ LoggerBackend ──→ Sigil.Log.Store (ring buffer)
                                         │
                                    ext__beam__logs ←── LLM 对话中调用
```

- 新增 `Sigil.Log.LoggerBackend` — `:logger` handler，把所有 Logger 消息灌入 `Log.Store`
- 新增 `Sigil.Tool.Extension.Beam.Logs` — `ext__beam__logs` 工具，从 ring buffer 读
- 配置 `config :logger, backends: [...]` 加一行

**优点**：复用现有 `Log.Store`/`Log.Event`，代码量小，同 BEAM 直接读
**缺点**：只能看到配置之后的日志，历史日志需要额外处理

#### 方案 B：读日志文件

- 目标项目如果配了 file backend，直接 `read log/development.log`
- 不需要新代码，但依赖项目配置了文件日志

**优点**：零代码，有历史
**缺点**：不是所有项目都配了文件日志；LLM 需要知道文件路径

#### 方案 C：bash tail

- LLM 直接 `bash "tail -n 50 log/development.log"` 或 `bash "mix phx.server 2>&1 | tee ..."`
- 不需要新代码

**优点**：零代码，bash 工具已存在
**缺点**：笨重，没有结构化过滤，不同项目路径不同

### 推荐

方案 A（Logger Backend + ext__beam__logs）作为主力，方案 B/C 作为降级。

---

## 场景 2：跨 BEAM / 远程

```
┌─ BEAM VM A: Sigil ──────────┐    ┌─ BEAM VM B: 目标项目 ──────┐
│                              │    │                             │
│  Sigil agent 在跑            │    │  mix phx.server 在跑        │
│  LLM 对话在这里              │    │  Logger.info/warn/error     │
│                              │    │                             │
│  LLM 想读到 VM B 的日志 → ??? │    │                             │
└──────────────────────────────┘    └─────────────────────────────┘
```

### 约束

- 两个独立的 OS 进程，两个 BEAM VM
- 需要跨进程通信

### 可能的方案

#### 方案 A：分布式 Erlang（Tidewave 方式）

```
Sigil VM ──分布式 Erlang──→ 目标 VM
                │
          Node.spawn(:target@host, fn ->
            :logger.get_module_level() ...
          end)
```

- 目标项目启动时连接 Sigil 节点
- Sigil 通过 `Node.spawn/2` 在目标节点上执行日志查询
- 这就是 Pi 的 `elixir_logs` 工具底层做的事情

**优点**：实时、结构化、完整 Logger 元数据
**缺点**：需要配置分布式 Erlang（cookie、节点名），有安全顾虑

#### 方案 B：日志文件共享

- 目标项目写日志文件，Sigil 通过文件系统读取
- 简单粗暴

**优点**：无耦合
**缺点**：延迟、无结构化

#### 方案 C：HTTP/WebSocket 日志推送

- 目标项目起一个轻量 endpoint 推送日志
- Sigil 订阅

**优点**：解耦
**缺点**：侵入目标项目代码

---

## 优先级

1. **先做场景 1** — 覆盖大部分"用 Sigil 开发 Elixir 项目"的日常
2. **再做场景 2** — 跨 VM 是进阶需求，可以复用场景 1 的工具体验，换底层实现
