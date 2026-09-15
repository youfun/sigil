# Sigil MCP Config Loader Spec

> 日期: 2026-05-15  
> 状态: Draft  
> 范围: 第一阶段只实现 MCP 配置加载，不启动 MCP server，不接入 ToolRegistry，不接入 Web UI。

## 背景

Sigil 目前没有可编译的 `Sigil.MCP.ConfigLoader` 模块。现有测试 `test/sigil/mcp/config_loader_test.exs` 已经定义了配置加载器的核心行为，包括：

- 读取项目级 `.mcp.json`
- 读取项目级 `.sigil/mcp.json`
- 支持用户级配置与项目级配置合并
- 项目配置覆盖同名用户配置
- 过滤 `disabled: true` 的 server
- 解析 `env:VAR` 到运行时环境变量
- 缺失环境变量解析为空字符串
- 无效 JSON 不抛异常，返回 diagnostics
- diagnostics 不泄露 env secret 值
- 校验 server name 和必填 command

`STATUS-CURRENT.md` 目前未把 MCP 列为当前优先项；因此本 spec 把 MCP 拆成可独立落地的小阶段。第一阶段目标是让配置层稳定、可测试、可被后续 MCP runtime 复用。

## 参考项目分析

### Cortex `Cortex.Channels.ConfigLoader`

路径: `upstream_refs/Cortex/lib/cortex/channels/config_loader.ex`

可借鉴点：

- 配置加载按来源分层，再按优先级 merge。
- 读取失败、JSON 失败、数据库未准备好时优雅降级。
- loader 返回普通 map，不在加载阶段做外部副作用。

不直接复用点：

- Cortex 的优先级是 DB > JSON > Env，面向 channel adapter。
- Sigil MCP 需要的是 user config + project config + env placeholder resolution。
- MCP loader 不能依赖数据库，也不能在 ConfigLoader 阶段启动外部进程。

### Alloy `Alloy.Provider.Codex`

路径: `upstream_refs/alloy/lib/alloy/provider/codex.ex`

可借鉴点：

- 明确避免默认加载用户完整 MCP/plugin 配置，只复制必要认证文件。
- 外部进程配置要与认证、工作目录、临时目录隔离。

对 Sigil 的启发：

- MCP 默认行为必须偏保守。
- ConfigLoader 可以发现和规范化配置，但 server 启动必须放到后续 Runtime 层，并经过权限、安全和用户可见诊断。

### Anubis MCP

路径: `upstream_refs/anubis-mcp/`

定位：

- 完整 Elixir MCP SDK。
- 同时提供 client 和 server。
- Client 支持 `stdio`、`sse`、`websocket`、`streamable_http`。
- Server 支持 component 注册、tool/resource/prompt、session、transport plug。

对 Sigil 最有价值的部分：

- `Anubis.Client` 已经覆盖 Sigil 作为 MCP client 的核心需求：`initialize`、`ping`、`tools/list`、`tools/call`、resources、prompts、progress callback、server capabilities。
- `Anubis.Client.Supervisor` 使用 client + transport 的 `:one_for_all` supervisor，这个结构适合 Sigil 后续为每个 MCP server 启动一棵独立 runtime 子树。
- `Anubis.Transport.STDIO` 用 Port 启动外部 command，并用 newline-delimited JSON 做 framing；这正好对应 `.mcp.json` 的 `command` / `args` / `env` / `cwd` 配置。
- `Anubis.Protocol` 管理 MCP protocol version、feature、transport compatibility，避免 Sigil 自己维护协议版本矩阵。
- Anubis client API 返回 `{:ok, Response.t()} | {:error, Error.t()}`，和 Sigil 当前工具执行的 tuple 风格兼容。

需要谨慎的部分：

- Anubis `STDIO` transport 会执行 `System.find_executable/1` 和 Port 启动外部进程。Sigil 第一阶段 ConfigLoader 不能引入这类副作用。
- Anubis 默认 stdio env 会带一组系统默认环境变量；Sigil 是否允许继承 env 需要单独安全决策。
- 如果引入依赖，需要评估版本、许可证、依赖体积、协议版本是否与目标 MCP server 兼容。

建议：

- 第一阶段仍然只写 Sigil 自己的 ConfigLoader，不依赖 Anubis。
- 第二阶段优先评估直接引入 `:anubis_mcp` 作为 MCP client runtime，而不是自研 JSON-RPC client。
- 如果不引入依赖，也应复用 Anubis 的结构思路：`Supervisor -> Client GenServer + Transport process`，transport 只负责 framing 和 IO，client 负责 request/response correlation 与 protocol state。

### Phantom MCP

路径: `upstream_refs/phantom_mcp/`

定位：

- Elixir Plug MCP server framework。
- 重点是把一个 Elixir/Phoenix/Plug 应用暴露成 MCP server。
- 支持 stdio 和 streamable HTTP。
- 提供 Router DSL 定义 tools、prompts、resources。

对 Sigil 最有价值的部分：

- `.mcp.json` 示例同时包含 HTTP server 和 stdio server：

```json
{
  "mcpServers": {
    "tidewave": {
      "type": "http",
      "url": "http://localhost:4000/tidewave/mcp"
    },
    "phantom-test-stdio": {
      "command": "bin/phantom-stdio"
    }
  }
}
```

- 这说明 Sigil ConfigLoader 不能只考虑 `command`，还要为后续 HTTP MCP server 预留 `type` / `url` 字段。
- `Phantom.Stdio` 明确提醒 Logger 输出到 stdout 会污染 JSON-RPC stream，server 端应该把日志转到 stderr。Sigil 作为 client 侧启动 stdio server 时，也要把 stdout 当协议流，stderr 当诊断流。
- `Phantom.Router` 的 DSL、schema validation、tool visibility、UI metadata 对 Sigil “将自身暴露成 MCP server”有参考价值。
- Phantom 测试覆盖 `initialize`、`tools/list`、`tools/call`、duplicate request、elicitation、UI `_meta` 等复杂场景，可作为后续 runtime 测试设计参考。

不适合作为 Sigil 当前 MCP client 的直接基础：

- Phantom 主要是 server framework，不是通用 client。
- 它适合未来做 `Sigil as MCP server`，让 Claude/Codex/其他 client 调用 Sigil 的 read/edit/bash/memory tools。

建议：

- ConfigLoader 第一阶段保留 HTTP 配置字段：`type`、`url`、`headers`。
- 第二阶段如果目标是“Sigil 使用外部 MCP tools”，优先看 Anubis。
- 后续如果目标是“外部 client 调用 Sigil”，再评估 Phantom 或 Anubis server 侧。

### 参考项目结论

Sigil MCP 应分成两条线，避免混在一起：

| 方向 | 目标 | 参考优先级 |
|------|------|------------|
| Sigil as MCP client | Sigil 读取 `.mcp.json`，启动/连接外部 MCP server，把外部 tools 注入 agent | Anubis 优先 |
| Sigil as MCP server | Sigil 把 builtin/memory tools 暴露给 Claude/Codex/其他 MCP client | Phantom / Anubis server 侧 |

当前用户提到的 ConfigLoader 测试属于第一条线的最前置基础设施。近期实现不应该直接做 server framework 或 UI app。

## 目标

第一阶段交付 `Sigil.MCP.ConfigLoader`，使现有 `Sigil.MCP.ConfigLoaderTest` 通过，并形成后续 runtime 的稳定输入结构。

模块路径：

```text
sigil/lib/sigil/mcp/config_loader.ex
```

建议后续分拆路径：

```text
sigil/lib/sigil/mcp/config.ex
sigil/lib/sigil/mcp/server_config.ex
sigil/lib/sigil/mcp/diagnostic.ex
```

第一阶段可以先把 struct 放在 `config_loader.ex` 内，也可以直接拆文件。优先选择能让测试和类型清晰的最小实现。

## 非目标

第一阶段不做：

- MCP JSON-RPC client
- stdio / SSE / HTTP transport 启动
- MCP tool discovery
- MCP tool 到 `Sigil.Tool.Registry` 的桥接
- Web UI 配置页
- server 进程 supervisor
- permission prompt
- marketplace / extension 集成

这些属于第二阶段以后。

## 配置来源

`ConfigLoader.load/1` 接收 keyword opts：

```elixir
ConfigLoader.load(project: "/path/to/project")
ConfigLoader.load(user_config_path: "/path/to/mcp.json", project: "/path/to/project")
```

第一阶段支持的来源：

| 来源 | 默认路径 | 优先级 | 说明 |
|------|----------|--------|------|
| User | 显式 `:user_config_path`，后续可默认 `~/.sigil/mcp.json` | 低 | 跨项目 MCP server |
| Project legacy | `<project>/.mcp.json` | 高 | 兼容常见 MCP 配置 |
| Project Sigil | `<project>/.sigil/mcp.json` | 高 | Sigil 专属项目配置 |

项目级两个文件都存在时，建议优先级：

```text
user < .mcp.json < .sigil/mcp.json
```

理由：

- `.mcp.json` 用于兼容外部工具。
- `.sigil/mcp.json` 是 Sigil 专属覆盖层，应该允许覆盖通用 MCP 配置。

当前测试没有覆盖两个项目级文件同时存在的场景，建议补测试确认该规则。

## 输入格式

支持 Claude/Codex 常见 MCP JSON 风格：

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "."],
      "env": {
        "TOKEN": "env:MY_TOKEN",
        "PLAIN": "static"
      },
      "disabled": false
    }
  }
}
```

第一阶段字段：

| 字段 | 类型 | 必填 | 默认 | 说明 |
|------|------|------|------|------|
| `command` | string | 是 | 无 | 可执行命令 |
| `args` | list(string) | 否 | `[]` | 命令参数 |
| `env` | object | 否 | `%{}` | server 运行环境 |
| `disabled` | boolean | 否 | `false` | 为 true 时不进入 active config |
| `cwd` | string | 否 | `nil` | 后续 runtime 可用，第一阶段只保留 |
| `transport` | string | 否 | `"stdio"` | 后续 runtime 可用，第一阶段只保留 |
| `type` | string | 否 | `nil` | 兼容 HTTP MCP 配置，例如 Phantom 示例中的 `"http"` |
| `url` | string | 否 | `nil` | HTTP / streamable HTTP MCP endpoint |
| `headers` | object | 否 | `%{}` | HTTP MCP headers，允许 `env:VAR` 占位 |

未知字段第一阶段应保留到 `raw` 或 `extra` 中，不直接失败。这样可以兼容外部 MCP 配置。

## 输出结构

`ConfigLoader.load/1` 返回：

```elixir
{:ok, %Sigil.MCP.Config{
  servers: %{
    "filesystem" => %Sigil.MCP.ServerConfig{
      name: "filesystem",
      command: "npx",
      args: ["-y", "server"],
      env: %{"TOKEN" => "env:MY_TOKEN"},
      runtime_env: %{"TOKEN" => "actual-value"},
      disabled: false,
      type: nil,
      url: nil,
      headers: %{},
      runtime_headers: %{},
      source: "/project/.mcp.json",
      raw: %{}
    }
  },
  diagnostics: []
}}
```

最低限度必须满足测试访问：

```elixir
config.servers["filesystem"].command
config.servers["filesystem"].disabled
config.servers["api"].runtime_env["TOKEN"]
config.diagnostics
```

建议 struct：

```elixir
defmodule Sigil.MCP.Config do
  defstruct servers: %{}, diagnostics: []
end

defmodule Sigil.MCP.ServerConfig do
  defstruct [
    :name,
    :command,
    args: [],
    env: %{},
    runtime_env: %{},
    disabled: false,
    cwd: nil,
    transport: "stdio",
    type: nil,
    url: nil,
    headers: %{},
    runtime_headers: %{},
    source: nil,
    raw: %{}
  ]
end

defmodule Sigil.MCP.Diagnostic do
  defstruct [:type, :message, :source, :server, details: %{}]
end
```

Diagnostics 的 `type` 至少支持：

```elixir
:error
:warning
```

测试当前断言 `hd(config.diagnostics).type == :error`，因此无效 JSON 必须使用 `:error`。

## 合并规则

合并单位是 server name。

```text
user servers
  |> Map.merge(project .mcp.json servers)
  |> Map.merge(project .sigil/mcp.json servers)
```

同名 server 采用整体覆盖，不做深 merge。

示例：

```json
// user
{"mcpServers": {"shared": {"command": "user-cmd", "args": ["--user"]}}}

// project
{"mcpServers": {"shared": {"command": "project-cmd"}}}
```

结果：

```elixir
servers["shared"].command == "project-cmd"
servers["shared"].args == []
```

理由：

- MCP server 配置通常是完整启动描述，深 merge 容易产生不可见混合状态。
- 测试已要求项目配置覆盖用户配置。

## 校验规则

### Server name

允许：

```text
lowercase letters, digits, hyphen, underscore
```

建议正则：

```elixir
~r/^[a-z0-9_-]+$/
```

无效 name：

- 空字符串
- 含空格
- 含大写字母
- 含路径分隔符
- 含 shell metacharacters

无效 server 不进入 `servers`，追加 diagnostic。

### Command

`command` 必须是非空字符串。

缺失或非字符串时：

- 不进入 `servers`
- 追加 diagnostic

第一阶段不检查 command 是否存在于 PATH，不执行 shell lookup。

### Args

`args` 缺省为 `[]`。

若不是 list，建议：

- server 不进入 `servers`
- 追加 diagnostic

若 list 中有非字符串，建议：

- server 不进入 `servers`
- 追加 diagnostic

### Env

`env` 缺省为 `%{}`。

只支持 string key 和 string value。非 string value 第一阶段建议转成 diagnostic，不进入该 server。

`env:VAR` 解析规则：

```elixir
"env:SIGIL_TEST_TOKEN" -> System.get_env("SIGIL_TEST_TOKEN") || ""
"static" -> "static"
```

原始 `env` 保留占位符，运行时用 `runtime_env`。

### HTTP Fields

为兼容 Phantom 示例和常见 MCP HTTP 配置，第一阶段应允许以下形态：

```json
{
  "mcpServers": {
    "remote": {
      "type": "http",
      "url": "http://localhost:4000/mcp",
      "headers": {
        "Authorization": "Bearer env:MCP_TOKEN"
      }
    }
  }
}
```

第一阶段只解析和保留，不发请求。

建议规则：

- `type: "http"` 或 `transport: "streamable_http"` 时，`url` 是必填。
- 纯 `command` 配置默认视为 stdio。
- `headers` 与 `env` 一样支持 `env:VAR`，解析结果放入 `runtime_headers`。
- diagnostics 不得包含解析后的 header secret。

当前测试尚未覆盖 HTTP 配置。为了不扩大第一阶段实现风险，可以先只保留字段，不强制 `url` 校验；后续 runtime 阶段再收紧。

## Secret Safety

ConfigLoader 不应在 diagnostics 中包含解析后的 env 值。

禁止出现在 diagnostics 的内容：

- `runtime_env`
- `runtime_headers`
- `System.get_env/1` 返回值
- token、api key、password、secret 等敏感 value

实现建议：

- diagnostics 只记录 env var 名称，例如 `SIGIL_SECRET`。
- 如果 details 需要包含 server config，先经过 `Sigil.Log.Redactor.redact/1`。
- 不在 error message 中拼接完整 decoded config。

## Error Handling

加载器必须尽量返回 `{:ok, config}`，而不是因为单个配置文件失败而失败整个加载。

场景：

| 场景 | 行为 |
|------|------|
| 所有文件不存在 | `{:ok, %{servers: %{}, diagnostics: []}}` |
| 单个 JSON 无效 | 跳过该文件，追加 `:error` diagnostic |
| 单个 server 无效 | 跳过该 server，追加 `:error` diagnostic |
| `mcpServers` 缺失 | 视为空配置，可追加 warning |
| `mcpServers` 非 map | 跳过该文件，追加 `:error` diagnostic |
| 文件不可读 | 跳过该文件，追加 `:error` diagnostic |

## 第一阶段实现计划

1. 新增 `lib/sigil/mcp/config_loader.ex`。
2. 定义 `Sigil.MCP.Config`、`Sigil.MCP.ServerConfig`、`Sigil.MCP.Diagnostic`。
3. 实现 `ConfigLoader.load/1`：
   - normalize opts
   - collect candidate paths
   - read existing files
   - decode JSON
   - extract `mcpServers`
   - validate and normalize servers
   - merge by priority
   - filter disabled servers
   - resolve `runtime_env`
4. 保证 diagnostics 不泄露 secret。
5. 运行并修复现有测试：

```sh
cd sigil
mix test test/sigil/mcp/config_loader_test.exs
```

6. 视实现影响运行：

```sh
cd sigil
mix compile
```

## 建议新增测试

现有测试之外建议补：

- `.mcp.json` 和 `.sigil/mcp.json` 同时存在时，`.sigil/mcp.json` 覆盖。
- invalid args type 产生 diagnostic。
- invalid env type 产生 diagnostic。
- uppercase server name 被拒绝。
- unknown fields 被保留到 `raw`，不阻塞加载。
- diagnostics 中不出现 `runtime_env` value。

## 第二阶段：MCP Runtime

第二阶段才引入外部进程和协议层。

推荐路线：

1. 优先评估直接使用 `:anubis_mcp` 的 `Anubis.Client`。
2. 如果依赖评估不通过，再自研最小 client runtime。

使用 Anubis 时建议模块：

```text
lib/sigil/mcp/runtime_supervisor.ex
lib/sigil/mcp/client_registry.ex
lib/sigil/mcp/tool_bridge.ex
```

`RuntimeSupervisor` 从 `ConfigLoader` 结果启动每个 active server：

```elixir
{Anubis.Client,
 name: {:via, Registry, {Sigil.MCP.Registry, {:client, server_name}}},
 transport_name: {:via, Registry, {Sigil.MCP.Registry, {:transport, server_name}}},
 transport: {:stdio, command: command, args: args, env: runtime_env, cwd: cwd},
 client_info: %{"name" => "Sigil", "version" => sigil_version},
 capabilities: %{"roots" => %{}},
 protocol_version: Anubis.Protocol.latest_version()}
```

自研时建议模块：

```text
lib/sigil/mcp/supervisor.ex
lib/sigil/mcp/server_runtime.ex
lib/sigil/mcp/client.ex
lib/sigil/mcp/transport/stdio.ex
lib/sigil/mcp/tool_bridge.ex
```

职责：

- 根据 `ServerConfig` 启动 stdio MCP server。
- 或根据 `type/url` 连接 streamable HTTP MCP server。
- 管理 server lifecycle。
- 发送 `initialize`、`tools/list`、`tools/call`。
- 把 MCP tools 转换成 Sigil tool definitions。
- 把 tool call 转发到 MCP server。
- 将错误变成 Sigil tool result 和 PubSub event。

安全要求：

- server 启动前必须过权限策略。
- command/args 不走 shell 拼接，使用 Port 参数数组或成熟 transport 实现。
- env 只传 `runtime_env` 中声明的 key，不继承完整系统 env，除非明确允许。
- cwd 必须经过 workspace/path boundary 校验。
- stdio stdout 是协议流，不能混入日志；stderr 作为 diagnostics。
- HTTP headers 必须过 redaction，不能进入普通日志或 PubSub 明文事件。

依赖评估清单：

- `:anubis_mcp` 是否支持 Sigil 当前 Elixir/OTP 版本。
- License 是否可接受。
- 引入依赖数量和编译时间是否可接受。
- stdio env 继承策略是否能满足 Sigil 安全要求。
- 对 `2025-03-26` / `2025-06-18` / 更新协议版本的兼容程度。

## 第三阶段：Agent / ToolRegistry 集成

建议桥接规则：

```text
mcp__<server_name>__<tool_name>
```

原因：

- 避免与 builtin tools 冲突。
- 与 extension namespace 风格一致。
- 便于 UI 和日志识别来源。

需要处理：

- MCP tool schema 到 provider tool schema 的转换。
- tool name 碰撞检测。
- server unavailable 时的降级 tool result。
- tool timeout。
- tool call event metadata 中标记 `source: :mcp`。

## 第四阶段：Web UI / Dogfood

UI 最小需求：

- 显示加载到的 MCP servers。
- 显示每个 server 的状态：disabled、configured、running、failed。
- 显示 diagnostics，但不显示 secret。
- 支持刷新配置。
- 支持在会话中启用/禁用 MCP tools。

Dogfood 场景：

```text
项目里配置 filesystem MCP server，让 Sigil 通过 MCP tool 读取一个文件，再用 builtin write 生成摘要。
```

## 第五阶段：Sigil as MCP Server

这是独立方向，不应阻塞 ConfigLoader 和 client runtime。

目标：

- 让外部 MCP client 调用 Sigil 的 builtin tools、memory tools 或受限 workspace tools。
- 支持 stdio 或 Phoenix/Plug HTTP endpoint。

参考：

- Phantom 的 `Phantom.Router` DSL 适合定义 Sigil 对外暴露的 tool/resource/prompt。
- Phantom 的 `Phantom.Stdio` 对 Logger/stdout 隔离有直接参考价值。
- Anubis server component 模型也可评估，但 Phantom 对 Plug/Phoenix 的集成路径更贴近 Sigil Web。

建议不要复用内部 ToolRegistry 原样对外暴露。应该先定义安全白名单，例如：

- `sigil_read`
- `sigil_write`
- `sigil_mem_recall`

每个外部 tool 都要经过 workspace boundary、权限策略和审计事件。

## 验收标准

第一阶段验收：

```sh
cd sigil
mix test test/sigil/mcp/config_loader_test.exs
```

期望：

```text
0 failures
```

同时：

- `mix compile` 通过。
- 无外部进程启动。
- 无网络调用。
- diagnostics 不泄露环境变量值。
- `STATUS-CURRENT.md` 可更新 MCP 状态为 “ConfigLoader spec ready / implementation pending” 或 “ConfigLoader implemented”，取决于后续是否完成实现。
