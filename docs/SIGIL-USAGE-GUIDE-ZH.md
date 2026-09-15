# Sigil 使用指南

> 自主可控的 AI 编码助手 — 基于 Elixir / Phoenix + SQLite3 构建

## 1. 产品概述

Sigil 是一个**本地优先**的 AI 编码助手，运行在 BEAM 虚拟机（Erlang/Elixir VM）之上。它通过 **Phoenix LiveView Web 工作台** 提供交互式编程体验，并内置了完整的文件操作、命令执行、代码搜索、记忆管理、BEAM 运行时内省等能力。

### 1.1 核心特性

| 特性 | 说明 |
|------|------|
| 多 Provider 支持 | 统一接口对接 Anthropic Claude、OpenAI、DeepSeek、ZenMux、OpenRouter、StepFun 等主流模型 |
| 本地运行 | 对话、配置、工具执行全部发生在本地，不依赖第三方云平台 |
| 工具可扩展 | 内置文件/Shell/搜索工具，支持 BEAM 运行时内省，支持 MCP 协议扩展外部工具 |
| 工作区权限 | 文件访问限制在工作区目录内，支持工具审批策略（auto / deny / prompt） |
| 跨渠道接入 | 支持 LiveView、CLI、Webhook、SNS 等多入口 |
| 流式交互 | LLM 回复实时流式渲染，工具调用状态可视化 |
| 记忆系统 | 支持跨会话的事实/模式/偏好记忆，短期记忆可强化为长期记忆 |
| 三栏工作台 | 工作区侧栏 + 聊天区 + 文件预览/Diff 查看器 |

### 1.2 产品定位

Sigil 目前定位为 **WebUI-first coding-agent MVP**，适合以下场景使用：

- **个人自用**：在本地真实仓库上执行编码任务
- **小团队内测**：可控范围内的协作与调试
- **受控 dogfood**：在可 Git 回滚的仓库上进行小到中等规模的编码工作

当前 WebUI 主链路已覆盖：选择工作区、发起 agent run、流式展示、工具事件展示、读/写/编辑文件、执行命令、持久化 transcript、切换模型、查看 Diff。

> ⚠️ **使用边界**：暂不建议直接开放给外部用户或无人值守重度使用。当前 diff 查看器支持文本变更的查看与回滚（基于文件 hash 校验），但工具审批 UI / Runner resume 等高级安全功能仍在开发中。

---

## 2. 快速开始

### 2.1 环境要求

| 依赖 | 最低版本 |
|------|---------|
| Elixir | >= 1.20.0-rc.5 |
| Erlang / OTP | >= 28 |
| SQLite3 | 系统已安装 |
| Node.js | 用于 assets 构建（如需要） |

### 2.2 安装与启动

```bash
# 1. 进入项目目录
cd sigil

# 2. 安装依赖
mix deps.get

# 3. 创建并迁移数据库
mix ecto.create && mix ecto.migrate

# 4. 启动开发服务器
mix phx.server
```

启动后访问 **http://localhost:5002**。

可通过环境变量 `PORT` 自定义端口：

```bash
PORT=8080 mix phx.server
```

---

## 3. 配置文件

Sigil 使用三层配置体系，理解各层的作用是高效使用的前提。

### 3.1 全局模型配置

**路径：`~/.sigil/models.json`**

这是最重要的配置文件。没有它，Sigil 无法调用任何 LLM。

也可通过环境变量 `SIGIL_MODELS_FILE` 指定自定义路径。

```json
{
  "defaultProvider": "stepfun",
  "defaultModel": "step-router-v1",
  "providers": {
    "stepfun": {
      "baseUrl": "https://api.stepfun.com/step_plan/v1",
      "api": "stepfun-step-plan",
      "apiKey": "env:MY_STEPFUN_KEY",
      "provider": "stepfun",
      "models": [
        { "id": "step-router-v1", "name": "Step Router v1" }
      ]
    },
    "openai": {
      "baseUrl": "https://api.openai.com/v1",
      "api": "openai-chat-completions",
      "apiKey": "env:OPENAI_API_KEY",
      "provider": "openai",
      "models": [
        { "id": "gpt-4o", "name": "GPT-4o" },
        { "id": "gpt-4o-mini", "name": "GPT-4o Mini" }
      ]
    },
    "deepseek": {
      "baseUrl": "https://api.deepseek.com",
      "api": "openai-chat-completions",
      "apiKey": "sk-your-deepseek-key",
      "provider": "deepseek",
      "models": [
        { "id": "deepseek-chat", "name": "DeepSeek Chat" }
      ]
    },
    "anthropic": {
      "baseUrl": "https://api.anthropic.com",
      "api": "anthropic-messages",
      "apiKey": "env:ANTHROPIC_API_KEY",
      "provider": "anthropic",
      "models": [
        { "id": "claude-sonnet-4-20250514", "name": "Claude Sonnet 4" }
      ]
    },
    "zenmux": {
      "baseUrl": "https://openai.zenmux.ai/v1",
      "api": "openai-chat-completions",
      "apiKey": "env:ZENMUX_API_KEY",
      "provider": "zenmux",
      "models": [
        { "id": "openai/gpt-5", "name": "ZenMux GPT-5" }
      ]
    },
    "openrouter": {
      "api": "openai-chat-completions",
      "apiKey": "env:OPENROUTER_API_KEY",
      "provider": "openrouter",
      "models": [
        { "id": "openai/gpt-4o", "name": "OpenRouter GPT-4o" }
      ]
    }
  }
}
```

**`api` 字段决定使用哪个 Provider 模块：**

| api 值 | Provider 模块 | 说明 |
|--------|-------------|------|
| `"stepfun"` / `"stepfun-step-plan"` | StepFun | 阶跃星辰 Plan 模式 |
| `"openai-chat-completions"` | OpenAI | 标准 Chat Completions API |
| `"openai"` / `"openai-responses"` | OpenAI Responses | OpenAI Responses API |
| `"anthropic-messages"` | Anthropic | Claude Messages API |

**`apiKey` 的写法：**
- `"env:VAR_NAME"` → 从环境变量读取（**推荐**，密钥不写入文件）
- `"sk-xxx..."` → 直接写明文（不推荐）

> ⚠️ `OPENAI_API_KEY` 等环境变量不会被隐式使用，必须在 `models.json` 中显式声明。

### 3.2 工作区设置

**路径：`<workspace>/.sigil/settings.jsonc`**

位于每个工作区目录下的 `.sigil/` 子目录中。JSONC 格式，支持 `//` 注释。如果文件不存在，Sigil 会在首次使用该工作区时自动创建默认配置。

> ⚠️ **注意：当前 Web 工作台的 Settings 面板为只读占位**（显示 workspace / model / status / session / MCP 等只读信息），下方所有工具权限配置均需**手动编辑 `.sigil/settings.jsonc` 文件**完成，暂时没有可视化配置界面。

```jsonc
{
  // 限制此工作区可用的模型（不配 = 不限制）
  "models": {
    "allow": {
      "providers": {
        "stepfun": { "models": ["step-router-v1"] }
      }
    }
  },

  // 工具权限控制（手动编辑 JSON 文件配置，无 UI）
  "tools": {
    // 默认审批模式："auto" | "prompt" | "deny"
    "default_mode": "auto",

    // 白名单模式匹配
    "allow": ["read", "write", "edit", "file_search"],

    // 黑名单模式匹配
    "deny": ["bash(rm:*)", "bash(sudo:*)"],

    // 按工具名指定审批模式
    "per_tool": {
      "bash": "prompt",
      "edit": "prompt"
    },

    // BEAM 扩展工具开关
    "beam": {
      "auto": true,
      "eval": false
    },
    "explicit": []
  }
}
```

**三种审批模式：**

| 模式 | 行为 | 实现状态 |
|------|------|---------|
| `auto` | 工具直接执行，无需用户确认 | ✅ 完整可用 |
| `deny` | 工具调用被拦截，返回错误信息，不执行 | ✅ 完整可用 |
| `prompt` | 后端生成中断事件，等待用户审批 | ⚠️ 后端已实现，审批卡片 UI 待完成 |

**`allow`/`deny` 支持的模式匹配语法：**

| 写法 | 匹配规则 | 示例 |
|------|---------|------|
| `"tool_name"` | 精确匹配工具名 | `"bash"` 匹配所有 bash 调用 |
| `"prefix_*"` | 通配符匹配 | `"mem_*"` 匹配 `mem_recall`、`mem_learn` 等 |
| `"tool(arg:*)"` | 匹配工具 + 参数值 | `"bash(rm:*)"` 匹配含 `rm` 的命令行 |
| `"edit(.env)"` | 匹配工具 + 文件路径 | `"edit(.env)"` 匹配对 `.env` 的编辑操作 |

> 以上匹配逻辑已通过单元测试验证，编辑 `.sigil/settings.jsonc` 后重启或下次 run 即生效。

### 3.3 MCP 配置

**路径：`.mcp.json`（项目级）/ `~/.mcp.json`（用户级）**

Sigil 通过 Model Context Protocol (MCP) 集成外部工具服务。MCP 配置文件支持多服务器配置，支持环境变量解析。

```json
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/project"]
    },
    "sqlite": {
      "command": "uvx",
      "args": ["mcp-server-sqlite", "--db-path", "project.db"]
    }
  }
}
```

MCP 工具在 Agent 启动时自动 bootstrap 并注册到工具系统，工具名格式为 `mcp__<server>__<tool>`。

> 当前 MCP 支持 **stdio** 传输（启动本地子进程通信），HTTP / streamable HTTP 传输待实现。

---

## 4. 数据存储

Sigil 的所有运行时数据都保存在本地文件系统中，**不使用云端存储**。

### 4.1 全局数据目录（`~/.sigil/`）

```
~/.sigil/
├── models.json              # 全局模型配置（手动创建）
├── workspaces.json          # 工作区列表
├── conversations/           # 对话存储
│   ├── index.json           # 对话索引
│   └── items/
│       └── <conversation_id>/
│           ├── meta.json    # 对话元信息（标题、创建时间等）
│           ├── messages.jsonl  # 对话消息（每条一行 JSON）
│           └── files.json   # 编辑器文件状态
├── sessions/                # 运行时会话快照
│   └── <session_id>.json
└── events/                  # 事件审计日志
    └── <session_id>.jsonl
```

**各文件说明：**

| 文件/目录 | 用途 |
|-----------|------|
| `models.json` | LLM 提供商与模型配置 |
| `workspaces.json` | 工作区列表（id、name、path、default 等） |
| `conversations/index.json` | 对话列表索引 |
| `conversations/items/<id>/meta.json` | 单条对话元信息 |
| `conversations/items/<id>/messages.jsonl` | 对话消息（user / assistant / tool / error / change） |
| `conversations/items/<id>/files.json` | 编辑器文件状态辅助数据 |
| `sessions/<id>.json` | 运行时 snapshot/replay（非用户可见 transcript） |
| `events/<id>.jsonl` | 事件审计日志（run_start / tool_start / tool_end / run_end / error） |

> ⚠️ **重要区分**：
> - `~/.sigil/conversations/` 是**全局对话历史**，所有工作区共用
> - `~/.sigil/sessions/` 是**运行时快照**，不是用户可见的对话历史
> - `~/.sigil/events/` 是**审计日志**，用于调试和回溯
> - `<workspace>/.sigil/` 只保存**工作区本地配置**

### 4.2 工作区本地目录（`<workspace>/.sigil/`）

```
<workspace>/.sigil/
├── settings.jsonc           # 工作区设置（模型限制 + 工具权限）
└── memory/                  # 该工作区的记忆 SQLite 数据库
    └── workspace_memory.db
```

> 工作区 `.sigil/` 目录只保存工作区本地配置和该工作区的记忆数据库，不保存全局对话 transcript 或 runtime session snapshot。

### 4.3 SQLite 数据库

| 环境 | 数据库路径 |
|------|-----------|
| 开发 | 项目根目录 `sigil_dev.db` |
| 测试 | 项目根目录 `sigil_test.db` |
| 生产 | `DATABASE_PATH` 环境变量指定 |

SQLite 当前只承载 **Memory 记忆系统**（`engrams` + `synapses` 表），不是对话/工作区的主存储。

---

## 5. Web 工作台使用

### 5.1 界面布局

Web 工作台采用三栏布局：

```
┌──────────┬───────────────────┬─────────────┐
│ 工作区    │                   │  文件预览     │
│ 侧栏      │   聊天区域         │  / Diff     │
│          │                   │             │
│ - 对话列表 │  - 流式 Markdown   │  - 文件内容   │
│ - 工作区   │  - 工具事件卡片    │  - Diff 对比 │
│   列表    │  - 模型选择器      │             │
│          │  - thinking 折叠  │             │
└──────────┴───────────────────┴─────────────┘
```

### 5.2 基本操作

| 操作 | 方法 |
|------|------|
| 新建对话 | 点击工作区旁的 + 按钮 |
| 切换工作区 | 侧栏选择不同工作区 |
| 切换模型 | 输入框输入 `/model` 或使用模型选择器 |
| 归档对话 | 对话项 Archive 按钮 |
| 发送消息 | 底部输入框输入后按 Enter |
| 查看文件 | 点击工具事件中的文件路径 |
| 查看 Diff | 点击 edit/write 工具事件查看文本变更 |

### 5.3 流式特性

- **流式 Markdown 渲染** — LLM 回复逐字显示，打字机效果
- **thinking 折叠块** — 如果模型输出 `<think>...</think>` 标签，会被折叠成可展开的块
- **工具事件卡片** — 工具调用显示 running → completed/error 状态变化
- **Diff 查看器** — edit/write 工具触发文件变更展示，支持基于文件 hash 的回滚

### 5.4 命令行

在聊天输入框中，以下命令有特殊处理：

| 命令 | 功能 |
|------|------|
| `/model` | 列出可用模型并提示切换 |
| `/model <provider>/<model>` | 直接切换模型 |
| `/clear` | 清空当前对话上下文 |

---

## 6. 内置工具一览

Sigil 的工具系统分为 Builtin（基础工具）、Memory（记忆工具）、BEAM Extension（Elixir 运行时工具）和 MCP（外部协议工具）四大类。

### 6.1 文件操作

| 工具 | 功能 | 示例 |
|------|------|------|
| `read` | 读取文件内容，支持分页、行号范围、二进制检测 | `read file_path="lib/app.ex" offset=0 limit=100` |
| `edit` | 精确文本替换（old_string → new_string） | `edit file_path="lib/app.ex" old_string="def old" new_string="def new"` |
| `write` | 创建/覆盖文件，自动创建父目录 | `write file_path="lib/new.ex" content="..."` |

### 6.2 命令执行

| 工具 | 功能 | 安全限制 |
|------|------|---------|
| `bash` | 执行 Shell 命令 | 限时 120s，工作区路径验证，危险命令模式拦截 |

`bash` 工具支持参数：
- `command`：要执行的 Shell 命令
- `timeout`：超时时间（毫秒，默认 120000）
- `workdir`：工作目录（默认当前工作区）

### 6.3 搜索

| 工具 | 功能 | 性能 |
|------|------|------|
| `file_search` | 模糊文件名搜索 | ~5ms，支持 typo 容忍、glob、排除 |

`file_search` 基于 ex_fff（纯 Elixir ETS 三元组索引），支持：
- Typo 容忍：`"usr_cntrl"` → `user_controller`
- Glob 过滤：`*.ex`
- 排除模式：`!test/`
- 查询语法：term / glob / exclude / AND

### 6.4 记忆系统

记忆数据存储在 SQLite 的 `engrams` 和 `synapses` 表中，支持跨会话持久化。

| 工具 | 功能 | 说明 |
|------|------|------|
| `mem_recall` | 记忆检索 | 根据当前上下文搜索相关记忆 |
| `mem_learn` | 记忆学习 | 写入新知识（默认 24h 短期记忆） |
| `mem_reinforce` | 记忆强化 | 将短期记忆提升为长期记忆 |
| `mem_associate` | 记忆关联 | 在两条记忆之间建立关联 |

### 6.5 BEAM 扩展工具（Elixir 项目自动启用）

当工作目录包含 `mix.exs` 时，Sigil 自动检测为 Elixir 项目并启用 BEAM 内省工具。

| 工具 | 功能 |
|------|------|
| `ext__beam__docs` | 查询模块/函数文档（`Code.fetch_docs/1`） |
| `ext__beam__source` | 源码位置定位（`:beam_lib.chunks/2`） |
| `ext__beam__sql` | 通过 Ecto Repo 执行 SQL 查询 |
| `ext__beam__eval` | 隔离进程安全代码执行（需在 settings.jsonc 中显式开启 `"eval": true`） |
| `ext__beam__schemas` | 发现所有 Ecto Schema 模块及其文件路径 |
| `ext__beam__sup_tree` | 可视化监督树结构 |
| `ext__beam__top` | BEAM 进程排名（内存/归约/消息队列） |
| `ext__beam__process_info` | 深度检查指定 BEAM 进程 |

> BEAM 工具通过 ExtensionBridge 动态注册。非 Elixir 项目（无 `mix.exs`）不暴露 BEAM 工具。`eval` 不自动注册，需在 settings.jsonc 中显式启用。

### 6.6 MCP 工具（外部服务）

MCP 工具格式为 `mcp__<server>__<tool>`，来自外部 MCP 兼容服务器。工具列表在 Agent 启动时通过 `tools/list` 动态获取。

---

## 7. 安全机制

Sigil 内置多层安全防护：

| 机制 | 说明 |
|------|------|
| **PathValidator** | 确保文件操作不逃逸工作区目录，检测 symlink 逃逸 |
| **ShellPathGuard** | 危险命令模式拦截（如 `rm -rf /`、`sudo` 等） |
| **Redactor** | 递归敏感字段脱敏（secret / password / api_key / token / passphrase 等） |
| **ToolGuard** | 工具执行前权限检查：auto → 直接执行；deny → 拦截返回错误；prompt → 生成中断事件等待审批 |
| **工作区边界** | 所有文件操作限制在工作区目录内 |

工具审批策略通过 `.sigil/settings.jsonc` 中的 `tools` 字段配置，支持精确工具名匹配、通配符匹配、参数值匹配和文件路径匹配。

---

## 8. 常用命令

```bash
# 开发命令
mix compile              # 编译项目
mix format               # 格式化代码
mix test                 # 运行所有测试
mix test --exclude slow  # 排除慢测试和端到端测试
mix test --dry-run       # 列出测试但不执行 (Elixir 1.20+)
mix phx.server           # 启动开发服务器（默认端口 5002）
iex -S mix phx.server    # 启动 + IEx 交互式控制台
mix ecto.migrate         # 运行数据库迁移
mix precommit            # 提交前检查（compile, deps, format, test）

# Elixir 1.20 新增开发命令
mix source MODULE        # 打印或打开模块/函数源码位置
mix deps.tree --output FILE   # 导出依赖树到文件
mix app.tree --output FILE    # 导出应用树到文件
mix help MODULE          # 在 shell 中显示模块文档（含 types/callbacks）
```

---

## 9. 故障排查

### UI 没有显示，但日志显示 LLM 调用成功

1. 检查 `~/.sigil/conversations/items/<conversation_id>/messages.jsonl` 是否有新消息
2. 检查 LiveView 是否从 `ConversationTranscriptStore` 正确读取了 transcript
3. 确认没有多个 LiveView 实例重复订阅同一 session

### 修改 `models.json` 后模型没有变化

1. 确认文件路径正确：`cat ~/.sigil/models.json`
2. 确认 `api` 字段值与 Provider 匹配
3. 重启 Sigil 服务

### 文件操作报 "Path traversal blocked"

- 确保操作的文件路径在工作区目录内
- 如果使用了 symlink，确保目标也在工作区范围内
- 检查 `settings.jsonc` 中是否有针对该工具/路径的 deny 规则

### 对话历史丢失

1. 先确认文件是否存在：`ls ~/.sigil/conversations/items/`
2. 检查 `index.json` 是否被覆盖或损坏
3. 用绝对路径检查：`ls -la ~/.sigil/conversations/index.json`
4. 不要只相信日志中动态解析的路径

### BEAM 工具不可用

- 确认工作目录下有 `mix.exs` 文件
- 确认 `settings.jsonc` 中 `"beam": { "auto": true }`
- 非 Elixir 项目不自动暴露 BEAM 工具

---

## 10. 编程接口

### 10.1 通过 Coordinator 发送消息

```elixir
alias Sigil.Agent.Coordinator

{:ok, ack} = Coordinator.add_message(
  "conversation-id",
  "你好，帮我分析一下这段代码",
  workspace_path: "/path/to/project",
  model: "stepfun/step-router-v1",
  provider_config: %{...},
  tools: [],
  source: :cli
)
```

### 10.2 直接使用 Agent

```elixir
alias Sigil.Agent

{:ok, state} = Agent.run("列出当前目录文件",
  working_directory: "/path/to/project",
  tools: [Sigil.Tool.Builtin.Bash, Sigil.Tool.Builtin.Read],
  model: "gpt-4o",
  max_turns: 50,
  streaming: true,
  on_chunk: fn chunk -> IO.write(chunk) end
)
```

### 10.3 查询运行状态

```elixir
{:ok, status} = Coordinator.status("conversation-id")
# %{conversation_id: "...", running?: true, run_pid: #PID<...>, ...}
```

### 10.4 取消运行

```elixir
:ok = Coordinator.cancel("conversation-id")
```

---

## 11. 架构速览

```
Intent Layer (LiveView / CLI / SNS / Webhook)
  → Coordinator
  → RunSupervisor (CandidateQueue + Runner)
  → Agent Core (Turn) → Provider / Tools
  → Runtime events
      ├── PubSub Session snapshot → LiveView projection
      ├── TranscriptPersistence → messages.jsonl
      ├── Delivery → SNS/Webhook/CLI outbound
      └── EventRecorder → audit/debug JSONL
```

| 层 | 模块路径 | 职责 |
|----|----------|------|
| Agent Runtime | `lib/sigil/agent/` | Agent loop、Provider、Middleware、Compactor、Runner、Coordinator |
| Tool Registry | `lib/sigil/tool/` | 工具注册、查找、defs 生成 |
| Builtin Tools | `lib/sigil/tool/builtin/` | Read / Edit / Bash / Write / FileSearch |
| Extension Tools | `lib/sigil/tool/extension/` | ext__beam__docs / source / sql / eval / schemas / sup_tree / top / process_info |
| Memory Tools | `lib/sigil/tool/memory/` | mem_recall / mem_learn / mem_reinforce / mem_associate |
| MCP Runtime | `lib/sigil/mcp/` | Protocol / ServerRuntime / ToolBridge / Config / Diagnostic |
| Extension System | `lib/sigil/extension/` | Loader / Registry / Manifest / HookRunner / ExtensionBridge |
| Security | `lib/sigil/security/` | PathValidator / ShellPathGuard / Redactor |
| Memory Schema | `lib/sigil/memory/` | Engram / Synapse (Ecto/SQLite3) |
| PubSub & Session | `lib/sigil/pubsub/` | AgentEvent / Session (seq + snapshot) |
| Session Store | `lib/sigil/session_store/` | Runtime session snapshot 持久化 |
| Event Recorder | `lib/sigil/event_recorder.ex` | JSONL 事件记录（run_start / tool_start / tool_end / run_end / error） |
| Log System | `lib/sigil/log/` | 结构化日志事件 / Formatter / Redactor / Store |
| Data Persistence | `lib/sigil/` | ConversationStore / WorkspaceStore (meta/files/messages JSONL + workspace CRUD) |
| Delivery | `lib/sigil/delivery*` | assistant/tool/error outbound 投递边界（SNS/Webhook/CLI 等） |
| Web UI | `lib/sigil_web/live/` | WorkspaceLive (三栏布局) |

---

## 12. 测试

```bash
mix test --exclude slow --exclude e2e    # 运行单元测试和集成测试（排除慢测试和端到端测试）
mix test test/sigil/tool/builtin/file_search_test.exs  # 运行特定测试文件
mix test --dry-run                       # 列出所有测试但不执行（Elixir 1.20+）
```

当前测试基线：**1105 tests, 0 failures, 24 excluded (slow/e2e)**。

---

## 13. 技术栈

| 组件 | 技术 |
|------|------|
| 语言 | Elixir 1.20 / Erlang OTP 28 |
| Web 框架 | Phoenix 1.8.7 / LiveView 1.1 |
| 数据库 | SQLite3 (ecto_sqlite3) |
| HTTP 客户端 | Req ~> 0.5 |
| 文件搜索 | ex_fff (ETS 三元组模糊索引) |
| Web 服务器 | Bandit ~> 1.5 |
| Provider 支持 | Anthropic Claude / OpenAI / DeepSeek / ZenMux / OpenRouter / StepFun |
