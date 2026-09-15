# BEAM 跨会话工具 — OTP 版 "Tmux"

## 概述

Tmux 的 `capture-pane` / `list-sessions` / `send-keys` 让 Coding Agent 能跨 window/session 获取上下文。OTP 天生就是为分布式、跨进程通信设计的，比 Tmux 更强：拿到的不是无结构的终端文本，而是**结构化的进程状态和事件流**。

本批次新增 3 个跨会话工具，加上已有的 6 个 BEAM 内省工具，构成完整的 "OTP 版 Tmux" 工具集。

## 核心映射

| Tmux 操作 | OTP/Sigil 等价工具 | 数据结构 | 安全级别 |
|-----------|-------------------|---------|---------|
| `tmux list-sessions` | `ext__beam__sessions` | session_id, pid, workspace, model, status, event_count | 🟢 safe |
| `tmux capture-pane -t <s>` | `ext__beam__session_snapshot` | 结构化 event list: role + content + timestamp | 🟢 safe |
| `tmux send-keys -t <s>` | `ext__beam__session_steer` | 走 CandidateQueue 安全注入，非 stdin 灌字节 | 🔴 dangerous |
| `htop` / 进程列表 | `ext__beam__top` | pid, memory, reductions, message_queue_len | 🟢 safe |
| 进程详情 | `ext__beam__process_info` | GenServer state, mailbox, links | 🔴 sensitive |
| `pstree` / 监督树 | `ext__beam__sup_tree` | child_id, type, status 嵌套结构 | 🟢 safe |
| 数据库 schema | `ext__beam__schemas` | Ecto schema 字段列表 | 🟢 safe |
| 源码定位 | `ext__beam__source` | module.function → file:line | 🟢 safe |
| 文档查询 | `ext__beam__docs` | @doc + @spec | 🟢 safe |
| SQL 查询 | `ext__beam__sql` | 查询结果行 | 🟢 safe |
| 代码执行 | `ext__beam__eval` | Elixir 表达式求值结果 | 🔴 dangerous |

## 安全设计：按需注册

BEAM 工具**默认不注册**，不会出现在 Agent 的 tool defs 中。需要时显式调用：

```elixir
# 安全模式 — 只注册只读工具（推荐日常默认）
Sigil.Tool.Registry.register_beam_tools(:safe_only)

# 全量模式 — 含 eval + process_info + session_steer（深度调试/跨 Agent 协作时）
Sigil.Tool.Registry.register_beam_tools(:all)
```

### 分级详情

| 级别 | 包含工具 | 风险 |
|------|---------|------|
| 不注册 | 无 | 零风险 |
| `:safe_only` | docs, source, sql, schemas, sup_tree, top, sessions, session_snapshot | 只读，无副作用 |
| `:all` | + eval, process_info, session_steer | 可执行代码、可修改进程状态 |

关键决策：**`:safe_only` 可以默认开着**，它不会改变任何状态。`:all` 里的 `eval`、`process_info`、`session_steer` 需要用户显式授信。

## 使用场景

### 🟢 日常场景（`:safe_only`）

#### 场景 1：系统健康检查

```
用户: "Sigil 现在负载高吗？"

Agent: → ext__beam__top
       → ext__beam__sessions
       → "当前 47 个进程，内存 89MB，3 个活跃 Agent session。一切正常。"
```

替代了 `htop` + `tmux list-sessions`。

#### 场景 2：跨 Session 获取上下文

```
Agent A（在写 Elixir 代码）想知道 Agent B（在修数据库迁移）做了什么：

Agent A: → ext__beam__sessions
         → 发现 session_abc123, workspace: "sigil"
         → ext__beam__session_snapshot(session_abc123)
         → 拿到 B 最近 20 条 transcript
         → 发现 B 刚改了一个 migration
         → 据此调整自己的代码，避免冲突
```

这就是 Tmux `capture-pane -t <other-window>` 的 OTP 版本，但拿的是**结构化事件**（role + content + timestamp），而非终端文本。

#### 场景 3：数据库探索

```
用户: "users 表有哪些字段？"

Agent: → ext__beam__schemas
       → "Sigil.Accounts.User，字段: id, email, name, inserted_at, updated_at"
       → ext__beam__sql("SELECT count(*) FROM users")
       → "当前共 42 个用户"
```

不需要 Agent 去翻 migration 文件或 schema 定义。

### 🔴 深度场景（`:all`）

#### 场景 4：Debug 卡住的 Agent

```
用户: "Agent B 半小时没响应了，帮我看看怎么回事"

Agent A: → ext__beam__sessions          # 发现 B 的 session
         → ext__beam__session_snapshot  # 看 B 的 transcript，发现卡在某个 tool call
         → ext__beam__process_info(B的pid)
            → message_queue_len: 1427  ← 邮箱爆了
         → ext__beam__sup_tree          # 检查 B 的监督树是否异常
         → "B 的邮箱积压了 1427 条消息，Runner 进程可能死锁。
            建议重启该 session。"
```

相当于 Tmux `capture-pane` + `strace` + 进程诊断，三位一体。

#### 场景 5：跨 Agent 协作注入

```
用户: "让 Agent B 别继续了，改用方案 C"

Agent A: → ext__beam__session_steer(session_B,
            %{message: "放弃当前方案，改用方案 C..."})
         → 消息注入到 B 的 CandidateQueue
         → Agent B 在下一轮 turn 中收到新指令
```

这是 Tmux `send-keys -t <other-pane>` 的安全版本——走消息队列而非往终端灌字节。

#### 场景 6：生产环境火线诊断（需要 eval）

```
运维: "为什么 Phoenix 请求突然变慢？"

Agent: → ext__beam__eval(":recon.proc_count(:memory, 10)")
       → 拿到内存 Top 10 进程
       → ext__beam__process_info(可疑pid)
       → 定位到具体模块
```

替代了 SSH 进生产节点 + `iex --remsh` 的整条链路。

## OTP 相比 Tmux 的本质优势

Tmux 的 `capture-pane` 拿的是**无结构的终端字节流**，LLM 要靠 prompt 自己去 parse VT100 转义序列、对齐的列、ANSI 颜色。

而 OTP 版拿到的是：

| 工具 | 返回结构 | LLM 需要做什么 |
|------|---------|---------------|
| `ext__beam__sessions` | `[{session_id, pid, workspace, model, status, event_count}]` | 直接推理 |
| `ext__beam__session_snapshot` | `[{kind, role, content, seq}]` 事件列表 | 直接推理 |
| `ext__beam__top` | `[{pid, memory, reductions, message_queue_len}]` | 直接推理 |
| `ext__beam__sup_tree` | 嵌套 `[{child_id, type, status, children}]` | 直接推理 |
| `ext__beam__schemas` | `[{schema_name, fields, types}]` | 直接推理 |
| Tmux `capture-pane` | 终端字节流（含 ANSI escape codes） | 需要 parse + guess |

**结论：OTP 对 Tmux 是降维打击。** 不是因为 OTP 能做什么 Tmux 做不到的事，而是因为 OTP 返回的数据质量高一个数量级——LLM 不需要 "理解终端输出"，直接就能进行逻辑推理。

## 新增/修改文件

```
lib/sigil/tool/registry.ex                          # +50行: @beam_tools + register_beam_tools/1
lib/sigil/tool/extension/beam_sessions.ex           # 新建: session 发现 (tmux list-sessions)
lib/sigil/tool/extension/beam_session_snapshot.ex   # 新建: transcript 捕获 (tmux capture-pane)
lib/sigil/tool/extension/beam_session_steer.ex      # 新建: 跨 session 消息注入 (tmux send-keys)
test/sigil/tool/extension/beam_sessions_test.exs    # 新建: 10 tests
```

## 注册方式

```elixir
# 在应用启动时（如 application.ex 或 config 中）
# 安全模式（推荐默认）
Sigil.Tool.Registry.register_beam_tools(:safe_only)

# 或者在需要全量能力时
Sigil.Tool.Registry.register_beam_tools(:all)
```