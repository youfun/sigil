# Sigil 嵌入式终端 — 设计文档

> 可执行规格见 [terminal-spec.md](./terminal-spec.md)。

## 目标

在 Sigil Web UI 中嵌入终端面板，让 LLM Agent 能：
1. **直接看到工作区内任意进程的实时输出**（日志、测试、构建、任何命令）
2. **用户也能看到**，不需要离开浏览器切终端
3. **目标项目零修改**，不限制技术栈
4. **每个工作区可开多个终端**，用于同时观察 dev server、测试、构建、shell 等不同进程
5. **用户可手动创建和关闭终端**，关闭单个终端时只结束该终端的 PTY 和 session，不影响同工作区其他终端

本质：把 Tmux 的 `capture-pane` 能力搬进 Sigil。

## 底层依赖：ghostty_ex

`ghostty_ex` 是 Ghostty 终端的 BEAM 封装：

- **`Ghostty.Terminal`** — VT 终端仿真器 GenServer，支持 scrollback、颜色、ANSI、text reflow
- **`Ghostty.PTY`** — 真实 PTY 子进程，捕获 stdout/stderr 为 Erlang message
- **`Ghostty.LiveTerminal.Component`** — Phoenix LiveView 组件，在浏览器渲染终端
- **`Ghostty.Terminal.snapshot/2`** — 随时获取终端纯文本 / HTML 内容

当前项目已经在 `mix.exs` 中引入 `{:ghostty, "~> 0.4"}`，`mix.lock` 锁定为 `0.4.8`。后续工作不是添加依赖，而是完成运行时进程模型、LiveView hook 接入、权限接入与 UI 集成。

重要约束：

- `Ghostty.Terminal.start_link/1` 与 `Ghostty.PTY.start_link/1` 都会把 effect / output message 发给调用 `start_link/1` 的进程。
- 因此不能只用普通 Supervisor 直接启动 `{Ghostty.Terminal, Ghostty.PTY}` child 后期待输出自动流转。
- 必须有一个 per-terminal owner process 作为调用方，负责接收 `{:data, binary}` / `{:exit, status}` / `{:pty_write, binary}`，写入 terminal，广播刷新事件，并统一清理 PTY。
- `Ghostty.LiveTerminal.Component` 依赖前端 hook `GhosttyTerminal`。Phoenix 侧需要运行或等价实现 `mix igniter.install ghostty`，把 `ghostty.js` vendor 到 `assets/vendor/ghostty.js` 并在 `assets/js/app.js` 注册 hook。

## 架构

```
┌─ Sigil Web UI (LiveView, port 5002) ────────────────────────────────────┐
│                                                                          │
│  ┌─ Workspace: my-project ────────────────────────────────────────────┐ │
│  │                                                                     │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐  │ │
│  │  │ Terminal     │  │ Terminal     │  │ Terminal     │  │  Terminal │  │ │
│  │  │ "dev-server" │  │ "tests"     │  │ "build"     │  │  "shell"   │  │ │
│  │  │              │  │             │  │              │  │            │  │ │
│  │  │ mix phx.srv  │  │ mix test    │  │ mix compile │  │  git log   │  │ │
│  │  │ npm run dev  │  │ npm test    │  │ npm build   │  │  curl ...  │  │ │
│  │  │ go run .     │  │ go test     │  │ go build    │  │  docker .. │  │ │
│  │  │ ...          │  │ ...         │  │ ...          │  │  ...       │  │ │
│  │  └──────┬───────┘  └──────┬──────┘  └──────┬───────┘  └─────┬─────┘  │ │
│  │         │                 │                │                │        │ │
│  │         └─────────────────┴────────────────┴────────────────┘        │ │
│  │                                    │                                  │ │
│  │                    Terminal Registry                                  │ │
│  │                    (per-workspace)                                    │ │
│  └────────────────────────────────────┬─────────────────────────────────┘ │
│                                       │                                    │
│  ┌─ 对话 ─────────────────────────────┴────────────────────────────────┐  │
│  │                                                                     │  │
│  │  ext__term_output(terminal: "dev-server", tail: 20)                 │  │
│  │  → Ghostty.Terminal.snapshot(pid, :plain)                           │  │
│  │  → 纯文本，LLM 直接读                                               │  │
│  │                                                                     │  │
│  │  ext__term_send(terminal: "dev-server", input: "mix test\n")        │  │
│  │  → ToolGuard 审批后 Sigil.Terminal.Session.send_input/2             │  │
│  │  → Ghostty.PTY.write(pid, input)                                    │  │
│  │                                                                     │  │
│  │  ext__term_list() → 列出当前工作区所有终端                           │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

## 模块设计

### 1. `Sigil.Terminal.Supervisor` — 终端监督树

```elixir
# 全局 DynamicSupervisor 或每工作区一个 Supervisor
# 只监督 Sigil.Terminal.Session，不直接监督 Ghostty.Terminal / Ghostty.PTY

defmodule Sigil.Terminal.Supervisor do
  use DynamicSupervisor

  # API
  def start_terminal(workspace_id, name, opts)
  def stop_terminal(workspace_id, name)
  def stop_all_for_workspace(workspace_id)
  def list_terminals(workspace_id)
  def lookup(workspace_id, name)
end
```

### 2. `Sigil.Terminal.Session` — 单个终端 owner process

```elixir
# 每个终端一个 GenServer，作为 Ghostty.Terminal / Ghostty.PTY 的 owner。
# 负责 PTY output → Terminal.write、terminal effect → PTY.write、
# PubSub/UI refresh、状态记录、snapshot、输入、resize、退出清理。

defmodule Sigil.Terminal.Session do
  use GenServer

  # API
  def start_link(workspace_id: workspace_id, name: name, cmd: cmd, args: args, cwd: cwd)
  def send_input(session, input)
  def snapshot(session, format \\ :plain)
  def resize(session, cols, rows)
  def close(session)
  def info(session)

  # handle_info({:data, data}, state)
  #   Ghostty.Terminal.write(state.term, data)
  #   PubSub.broadcast(..., {:terminal_refresh, workspace_id, name})
  #
  # handle_info({:pty_write, data}, state)
  #   Ghostty.PTY.write(state.pty, data)
end
```

`Session` 是唯一允许直接持有 `{term_pid, pty_pid}` 的模块。其他模块通过 `Session` API 访问，避免 LiveView、工具和 Supervisor 分别处理 PTY message 导致状态分裂。

同一 workspace 下允许多个 `Session` 并存，注册键使用 `{workspace_id, terminal_name}`。终端名称在单个 workspace 内唯一；创建重名终端时返回错误或由 UI 生成 `shell-2`、`tests-2` 之类的唯一名称。

### 3. `Sigil.Tool.Extension.Terminal` — LLM 工具

```elixir
# 工具名: ext__term_output
# 参数: terminal (string), tail (int, 可选), grep (string, 可选)
# 返回: 终端的纯文本输出

# 工具名: ext__term_send
# 参数: terminal (string), input (string)
# 返回: 确认，或输出

# 工具名: ext__term_list
# 参数: 无
# 返回: 工作区终端列表（名称、命令、状态）
```

工具注册与权限：

- `ext__term_output` / `ext__term_list` 是只读工具，可以默认注册。
- `ext__term_send` 是执行通道，必须接入 `Sigil.Agent.Middleware.ToolGuard` 与 workspace settings。
- 推荐默认策略：`tools.per_tool.ext__term_send = "prompt"`，用户显式允许后才发送输入。
- 不把 `ext__term_send` 只归类为 `register_beam_tools(:all)`；BEAM 工具注册是可见性开关，不是完整权限边界。

### 4. `SigilWeb.Live.TerminalPanel` — LiveView 组件

```elixir
# 现有 Web UI 三栏布局中的新面板
# 用 Ghostty.LiveTerminal.Component 渲染终端
# 支持 tab 切换多个终端
# 自动 resize 适配容器
```

UI 接入要求：

- 在 `assets/js/app.js` 注册 `GhosttyTerminal` hook。
- `TerminalPanel` 只做 projection：显示当前 workspace 的 terminal 列表和 active terminal。
- `TerminalPanel` 不直接启动 PTY；创建/销毁通过 `Sigil.Terminal.Supervisor` / `Session` API。
- UI 必须提供创建终端入口，至少支持名称、命令、cwd（默认当前 workspace）。
- UI 必须提供关闭当前终端入口；关闭前如果 PTY 仍在运行，应提示用户确认或明确显示会终止该进程。
- 关闭 active terminal 后，UI 自动切换到同 workspace 的下一个终端；如果没有剩余终端，显示空状态和创建终端按钮。
- `TerminalPanel` 收到 `{:terminal_refresh, workspace_id, terminal_name}` 后调用 `send_update(Ghostty.LiveTerminal.Component, id: ..., refresh: true)`。
- `Ghostty.LiveTerminal.Component` 的 keyboard input 应走 `Session.send_input/2` 或组件绑定的 PTY pid；如果直接传 `pty` 给组件，仍需保证该 PTY 由 `Session` 创建并清理。

## 安全考虑

1. **工作区隔离** — PTY 是长期交互式 shell，单纯设置初始 cwd 不等于隔离。必须明确限制边界：默认只在 workspace path 启动；是否允许 `cd` 到 workspace 外需要作为产品权限决策，不应在文档中声称已经强隔离。
2. **启动 cwd** — `Ghostty.PTY` 当前 API 没有 `cwd` 选项。实现时需要用 wrapper command（例如 shell `cd <workspace> && exec ...`）或扩展 PTY 启动能力，并复用 `PathValidator` 校验 workspace。
3. **工具权限** — `ext__term_send` 必须走 ToolGuard / workspace settings。默认建议 `prompt`，并记录每次发送的 terminal、input preview、workspace、conversation。
4. **输出大小限制** — snapshot 必须支持 `tail`、最大字节数和 UTF-8 安全截断，避免一次返回整个 scrollback。
5. **进程清理** — workspace 关闭、terminal 手动关闭、LiveView 断开、应用退出时都要关闭 PTY；Session terminate 中调用 `Ghostty.PTY.close/1` 或让 linked child 正常退出。
6. **审计** — `ext__term_send` 是执行通道，必须写入 transcript / event recorder，不能只在 terminal scrollback 中留下痕迹。
7. **敏感信息** — `ext__term_output` 返回给 LLM 前应沿用现有 redaction/truncation 策略，避免把长期终端里的 token、cookie、env dump 直接注入模型上下文。

## 技术栈无关能力

| 技术栈 | 终端里能跑的 | LLM 能读到 |
|--------|------------|-----------|
| Elixir/Phoenix | `mix phx.server`, `mix test` | Logger 输出、测试结果 |
| Node.js | `npm run dev`, `npm test` | 编译错误、测试输出 |
| Python | `python manage.py`, `pytest` | traceback、日志 |
| Go | `go run .`, `go test ./...` | panic、测试输出 |
| Rust | `cargo run`, `cargo test` | 编译错误、测试输出 |
| Docker | `docker compose up`, `docker logs` | 容器日志 |
| 任意 CLI | `curl`, `git`, `make` | stdout/stderr |

## 分步计划

### Phase 1: 核心集成
- [x] `mix.exs` 添加 `ghostty` 依赖（当前锁定 `0.4.8`）
- [ ] Ghostty LiveView hook 接入：vendor `ghostty.js` 并注册 `GhosttyTerminal`
- [ ] `Sigil.Terminal.Supervisor` — 终端监督树
- [ ] `Sigil.Terminal.Session` — 单终端 owner process
- [ ] 手动创建默认 "shell" 终端（当前工作区）
- [ ] 支持同一工作区多个 terminal session 并发存在
- [ ] `ext__term_output` / `ext__term_list` 工具（只读）

### Phase 2: Web UI 嵌入
- [ ] `SigilWeb.Live.TerminalPanel` — LiveView 组件
- [ ] 嵌入现有三栏布局（第四面板或可切换面板）
- [ ] tab 切换多终端
- [ ] UI 创建终端
- [ ] UI 手动关闭单个终端
- [ ] 关闭 active terminal 后切换到下一个终端或空状态

### Phase 3: 交互式命令
- [ ] `ext__term_send` 工具（接入 ToolGuard，默认 prompt）
- [ ] Web UI 终端支持键盘输入
- [ ] 预置快捷按钮（`mix test`, `mix compile` 等）

### Phase 4: 进阶
- [ ] 工作区关闭时自动清理终端进程
- [ ] 终端输出持久化（保存历史到文件）
- [ ] 跨工作区终端隔离与权限策略
- [ ] terminal send/output 审计与 redaction
