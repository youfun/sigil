# Sigil Embedded Terminal Spec

> 日期: 2026-05-22  
> 状态: Draft  
> 范围: 在 Sigil Web UI 中提供每工作区多终端、实时输出可视化、LLM 只读观察与受控输入能力。底层使用已引入的 `ghostty` 依赖。

## 背景

Sigil 当前已有 `bash` 工具，可以执行单次命令并返回截断输出。但它不能覆盖长运行进程、实时日志观察、后续 turn 继续读取输出、多进程并行运行等场景。

本 spec 定义一个 workspace 级 embedded terminal runtime：用户可创建、切换、关闭多个终端；Agent 可列出终端、读取指定终端输出，并在权限批准后向指定终端发送输入。

## 目标

- 每个 workspace 支持多个 terminal session 并发存在。
- 用户可以在 Web UI 中手动创建、切换、关闭单个终端。
- 关闭一个终端只结束该终端对应的 PTY/session，不影响同 workspace 其他终端。
- 终端输出实时渲染给用户，并可被 Agent 通过只读工具读取。
- Agent 向终端发送输入必须经过 workspace tool permission / ToolGuard。
- 终端生命周期由 OTP supervision 管理，不能依赖 LiveView 进程作为唯一 owner。

## 非目标

第一阶段不做：

- 跨应用容器级沙箱。
- 强制禁止终端内 `cd` 到 workspace 外部。
- 终端历史持久化到文件。
- 终端会话跨应用重启恢复。
- 多用户协同编辑同一终端输入。
- 把终端作为 MCP server 暴露给外部 client。
- 替代现有 `bash` 工具；`bash` 仍用于短命令，terminal 用于长运行和交互式进程。

## 术语

| 名称 | 含义 |
|------|------|
| Terminal session | 一个由 Sigil 管理的终端实例，包含 `Ghostty.Terminal` 和 `Ghostty.PTY` |
| Terminal name | workspace 内唯一的终端名称，例如 `shell`、`dev-server`、`tests` |
| Active terminal | 当前 UI 选中的终端 |
| Owner process | `Sigil.Terminal.Session` GenServer，负责持有 terminal/PTY pid 并转发消息 |
| Workspace terminal registry | 按 `{workspace_id, terminal_name}` 注册/查找 terminal session 的 registry |

## 用户故事

1. 作为用户，我可以在当前 workspace 打开一个默认 shell，并直接在浏览器里输入命令。
2. 作为用户，我可以创建多个终端，例如 `dev-server` 跑服务、`tests` 跑测试、`shell` 做临时操作。
3. 作为用户，我可以关闭某个终端；如果该终端内进程仍在运行，UI 会明确提示关闭会终止该进程。
4. 作为用户，我关闭 active terminal 后，UI 会自动切到同 workspace 的下一个终端；如果没有剩余终端，显示空状态和创建入口。
5. 作为 Agent，我可以列出当前 workspace 的终端，选择一个终端读取 tail 输出。
6. 作为 Agent，我只有在权限允许或用户批准后，才能向终端发送输入。

## 功能需求

### FR-1: Workspace 多终端

- 系统 MUST 支持同一 workspace 下多个 terminal session 并发运行。
- terminal name MUST 在单个 workspace 内唯一。
- 不同 workspace MAY 使用相同 terminal name，它们必须互相隔离。
- 创建重名 terminal 时，API MUST 返回 `{:error, :already_exists}` 或 UI MUST 自动生成唯一名称，例如 `shell-2`。
- `ext__term_list` MUST 只列出当前 workspace 的 terminal session。

### FR-2: 创建终端

- UI MUST 提供创建终端入口。
- 创建参数至少包含 `name`、`cmd`、`args`、`cwd`。
- `cmd` 默认用户 shell 或 `/bin/sh`。
- `args` 默认 `[]`。
- `cwd` 默认当前 workspace path。
- 创建成功后，UI SHOULD 自动切换到新 terminal。
- 首次进入 workspace 时，系统 MAY 自动创建默认 `shell` terminal；如果自动创建失败，UI MUST 显示可恢复错误和手动创建入口。

### FR-3: 手动关闭终端

- UI MUST 提供关闭单个 terminal 的入口。
- 关闭 active terminal 前，如果 session 状态是 `:running`，UI MUST 明确提示该操作会终止该终端进程。
- 关闭 terminal MUST 调用 `Sigil.Terminal.Supervisor.stop_terminal(workspace_id, name)`。
- 关闭 terminal MUST 停止该 session 的 PTY 子进程。
- 关闭 terminal MUST 从 registry/list 中移除该 terminal。
- 关闭 active terminal 后，UI MUST 选择同 workspace 的下一个 terminal 作为 active terminal。
- 如果没有剩余 terminal，UI MUST 显示空状态和创建 terminal 的入口。

### FR-4: 实时输出渲染

- PTY output MUST 先进入 `Sigil.Terminal.Session`。
- `Session` MUST 调用 `Ghostty.Terminal.write(term_pid, data)` 更新 terminal emulator 状态。
- `Session` MUST 向 UI 广播 refresh event，例如 `{:terminal_refresh, workspace_id, terminal_name}`。
- `TerminalPanel` 收到 refresh event 后 MUST 触发 `Ghostty.LiveTerminal.Component` refresh。
- `TerminalPanel` MUST 只渲染当前 workspace 的 terminal。

### FR-5: Resize

- UI terminal resize MUST 同步到 `Ghostty.Terminal.resize/3` 和 `Ghostty.PTY.resize/3`。
- Resize 由 `Session` 统一处理，LiveView 不应直接绕过 `Session` 操作 PTY。

### FR-6: Agent 只读观察

- `ext__term_list` MUST 返回当前 workspace terminal 列表。
- `ext__term_output` MUST 支持读取指定 terminal 的 plain text snapshot。
- `ext__term_output` MUST 支持 `tail` 参数。
- `ext__term_output` SHOULD 支持 `grep` 参数。
- `ext__term_output` MUST 对返回内容做最大字节限制和 UTF-8 安全截断。
- `ext__term_output` 返回给 LLM 前 SHOULD 经过现有 redaction 策略。

### FR-7: Agent 发送输入

- `ext__term_send` MUST 接收 `terminal` 和 `input`。
- `ext__term_send` MUST 通过 ToolGuard / workspace settings 审批。
- 默认策略 SHOULD 是 `tools.per_tool.ext__term_send = "prompt"`。
- `ext__term_send` 执行成功后 MUST 写 transcript / event recorder。
- `ext__term_send` 的审计记录 MUST 包含 terminal name、workspace id/path、input preview、conversation id。
- 审计记录 MUST 不写入完整 secret 内容；长 input 需要截断。

### FR-8: 工作区切换与清理

- workspace 切换时，UI MUST 取消订阅旧 workspace terminal events，并订阅新 workspace terminal events。
- workspace 删除或关闭时，系统 SHOULD 调用 `stop_all_for_workspace/1`。
- 应用退出时，Supervisor MUST 清理所有 terminal session。
- LiveView 断开不应默认关闭 terminal session；terminal 是 workspace runtime 资源，不是某个浏览器连接的私有资源。

## 模块规格

### `Sigil.Terminal.Supervisor`

职责：

- 管理 `Sigil.Terminal.Session` child。
- 提供 workspace/name 维度的 start/stop/list/lookup API。
- 保证 session 以 `{workspace_id, terminal_name}` 唯一注册。

建议 API：

```elixir
@spec start_terminal(String.t(), String.t(), keyword()) ::
        {:ok, pid()} | {:error, :already_exists | term()}
def start_terminal(workspace_id, name, opts)

@spec stop_terminal(String.t(), String.t()) :: :ok | {:error, :not_found | term()}
def stop_terminal(workspace_id, name)

@spec stop_all_for_workspace(String.t()) :: :ok
def stop_all_for_workspace(workspace_id)

@spec list_terminals(String.t()) :: [
        %{name: String.t(), status: atom(), cmd: String.t(), cwd: String.t()}
      ]
def list_terminals(workspace_id)

@spec lookup(String.t(), String.t()) :: {:ok, pid()} | {:error, :not_found}
def lookup(workspace_id, name)
```

### `Sigil.Terminal.Session`

职责：

- 作为 `Ghostty.Terminal` 与 `Ghostty.PTY` 的 owner process。
- 接收 PTY output 并写入 terminal emulator。
- 接收 terminal effect message，例如 `{:pty_write, binary}` 并写回 PTY。
- 处理输入、resize、snapshot、close。
- 广播 terminal refresh 和 terminal exit event。

建议状态字段：

```elixir
%{
  workspace_id: workspace_id,
  workspace_path: workspace_path,
  name: name,
  cmd: cmd,
  args: args,
  cwd: cwd,
  term: term_pid,
  pty: pty_pid,
  status: :starting | :running | :exited | :closing,
  exit_status: nil | integer(),
  cols: pos_integer(),
  rows: pos_integer(),
  created_at: DateTime.t(),
  updated_at: DateTime.t()
}
```

建议 API：

```elixir
@spec send_input(pid(), binary()) :: :ok | {:error, term()}
def send_input(session, input)

@spec snapshot(pid(), :plain | :html | :vt, keyword()) :: {:ok, binary()} | {:error, term()}
def snapshot(session, format \\ :plain, opts \\ [])

@spec resize(pid(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
def resize(session, cols, rows)

@spec close(pid()) :: :ok
def close(session)

@spec info(pid()) :: map()
def info(session)
```

## Tool 规格

### `ext__term_list`

Input:

```json
{
  "type": "object",
  "properties": {},
  "required": []
}
```

Output:

```json
[
  {
    "name": "dev-server",
    "status": "running",
    "cmd": "mix",
    "args": ["phx.server"],
    "cwd": "/path/to/workspace",
    "created_at": "2026-05-22T10:00:00Z"
  }
]
```

### `ext__term_output`

Input:

```json
{
  "type": "object",
  "properties": {
    "terminal": {"type": "string"},
    "tail": {"type": "integer", "default": 80},
    "grep": {"type": "string"},
    "format": {"type": "string", "enum": ["plain"], "default": "plain"}
  },
  "required": ["terminal"]
}
```

Behavior:

- terminal 不存在时返回 tool error。
- `tail` 默认 80 行，最大值 SHOULD 限制为 500 行。
- 返回内容 MUST 限制最大字节数。
- 第一阶段只支持 `plain`，不把 HTML 输出注入模型上下文。

### `ext__term_send`

Input:

```json
{
  "type": "object",
  "properties": {
    "terminal": {"type": "string"},
    "input": {"type": "string"}
  },
  "required": ["terminal", "input"]
}
```

Behavior:

- terminal 不存在时返回 tool error。
- input 为空时返回 validation error。
- 执行前 MUST 经过 ToolGuard。
- 成功后返回简短确认，不默认返回完整 terminal output。
- 如果调用方需要查看结果，应再调用 `ext__term_output`。

## UI 规格

Terminal panel MUST 包含：

- terminal tab/list，显示 name 和 status。
- create terminal 控件。
- close terminal 控件。
- terminal viewport。
- 空状态：当前 workspace 无 terminal 时，显示创建入口。

Terminal tab SHOULD 显示：

- `running` / `exited` / `closing` 状态。
- 最近输出活动提示。
- 当前 active 标记。

创建 terminal 表单 SHOULD 支持：

- name。
- command。
- args。
- cwd，默认 workspace path。

关闭 terminal 行为：

- 如果 terminal status 是 `running`，显示确认。
- 如果 terminal status 是 `exited`，允许直接关闭。
- 关闭后切换到下一个 terminal。

## 权限与安全

- `ext__term_output` 和 `ext__term_list` 是只读工具，可以默认 auto。
- `ext__term_send` 是执行工具，默认 prompt。
- UI 用户手动输入不走 LLM ToolGuard，但仍应受 workspace terminal 创建/关闭权限约束。
- PTY 是长期 shell，不能声称具备强 workspace 沙箱。
- 初始 cwd MUST 校验在 workspace path 内。
- 如果使用 wrapper command 实现 cwd，workspace path MUST shell-escape。
- 返回给 LLM 的 output MUST 走 truncation/redaction。
- terminal send audit MUST 避免记录完整 secret。

## 事件

建议 PubSub event：

```elixir
{:terminal_started, workspace_id, terminal_name, info}
{:terminal_refresh, workspace_id, terminal_name}
{:terminal_exited, workspace_id, terminal_name, exit_status}
{:terminal_closed, workspace_id, terminal_name}
```

订阅 topic：

```text
terminal:<workspace_id>
```

## 验收标准

### Runtime

- 创建 `shell` terminal 后，`list_terminals(workspace_id)` 返回该 terminal。
- 同 workspace 可创建 `shell`、`dev-server`、`tests` 三个 terminal。
- 创建重名 terminal 不会覆盖已有 session。
- 向 `shell` 发送 `echo hello\n` 后，snapshot 能读到 `hello`。
- 关闭 `shell` 后，`dev-server` 和 `tests` 仍存在。
- `stop_all_for_workspace/1` 会关闭该 workspace 所有 terminal。
- PTY 退出后 session 状态变为 `:exited`，list 中能看到状态。

### Tools

- `ext__term_list` 只返回当前 workspace terminal。
- `ext__term_output` 对不存在 terminal 返回错误。
- `ext__term_output` 支持 tail 并限制输出大小。
- `ext__term_send` 在 workspace policy 为 `prompt` 时触发 ToolGuard interrupt。
- `ext__term_send` 在用户批准后能写入指定 terminal。
- `ext__term_send` 成功后写 transcript/event recorder。

### UI

- Terminal panel 能显示多个 terminal tab。
- 用户能创建 terminal 并自动切换到新 terminal。
- 用户能关闭 inactive terminal，active terminal 不变。
- 用户关闭 active terminal 后自动切换到下一个 terminal。
- 用户关闭最后一个 terminal 后显示空状态。
- terminal 输出实时刷新。
- resize 后 terminal 和 PTY 尺寸同步。

## 测试建议

单元测试：

- `Sigil.Terminal.SupervisorTest`
- `Sigil.Terminal.SessionTest`
- `Sigil.Tool.Extension.TerminalTest`

LiveView 测试：

- 创建 terminal。
- tab 切换。
- 关闭 terminal。
- 关闭最后一个 terminal 空状态。

权限测试：

- `ext__term_send` 默认 prompt。
- workspace settings `deny` 能拦截 `ext__term_send`。
- workspace settings `auto` 能执行 `ext__term_send`。

集成测试：

- 启动 PTY，发送 `echo`，读取 snapshot。
- 启动多个 terminal，关闭其中一个，验证其他仍可读写。

## 分阶段交付

### Phase 1: Runtime + 只读工具

- `Sigil.Terminal.Supervisor`
- `Sigil.Terminal.Session`
- Terminal registry
- `ext__term_list`
- `ext__term_output`
- Runtime unit tests

### Phase 2: Web UI

- Ghostty LiveView hook 接入。
- `SigilWeb.Live.TerminalPanel`
- 多 terminal tab。
- 创建 terminal。
- 手动关闭 terminal。
- LiveView tests。

### Phase 3: 受控输入

- `ext__term_send`
- ToolGuard / workspace settings 接入。
- transcript / event recorder 审计。
- 权限测试。

### Phase 4: 增强

- terminal output 持久化。
- terminal activity indicator。
- terminal preset commands。
- 更细粒度 workspace terminal policy。
