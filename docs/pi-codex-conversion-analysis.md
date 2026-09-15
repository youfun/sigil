# pi-codex-conversion 分析报告

> 仓库：https://github.com/IgorWarzocha/pi-codex-conversion
> 作者：Igor Warzocha
> 版本：v1.5.3
> 许可证：MIT
> 语言：TypeScript（Node.js ES Module）+ Rust（apply_patch 原生二进制）

---

## 一、项目概述

**pi-codex-conversion** 是一个 Pi 编码助手的扩展插件，其核心目标是将 **Pi** 的工具面和 prompt 风格"转换"成接近 **OpenAI Codex CLI** 的体验。

---

## 二、架构概览

```
src/
├── index.ts                           # 扩展入口：注册工具、事件监听、adapter 开关
├── adapter/
│   ├── codex-model.ts                 # 模型检测：isCodexLikeModel / isOpenAICodexContext
│   ├── runtime-shell.ts               # Shell 检测（fish → bash fallback）
│   └── tool-set.ts                    # 工具名常量（core adapter / image / search / view_image）
├── tools/
│   ├── exec-command-tool.ts           # exec_command 工具注册
│   ├── exec-session-manager.ts        # PTY + pipe 双模式会话管理
│   ├── exec-command-state.ts          # 命令追踪 + 渲染分组
│   ├── write-stdin-tool.ts            # write_stdin 工具注册
│   ├── apply-patch-tool.ts            # apply_patch 工具注册
│   ├── apply-patch-binary.ts          # apply_patch 二进制 PATH 注入
│   ├── apply-patch-rendering.ts       # Patch 渲染（collapsed/expanded/partial failure）
│   ├── web-search-tool.ts             # web_search（透传到 OpenAI native）
│   ├── image-generation-tool.ts       # image_generation（透传到 OpenAI native）
│   ├── view-image-tool.ts             # view_image（本地文件图片查看）
│   ├── codex-rendering.ts             # "Ran / Explored / Read / Search" 渲染逻辑
│   └── unified-exec-format.ts         # exec 结果格式化
├── prompt/
│   └── build-system-prompt.ts         # system prompt 重组（注入 shell、guidelines、skills）
├── providers/
│   ├── openai-codex-custom-provider.ts   # 自定义 OpenAI Codex Provider（WebSocket，~700 行）
│   └── openai-responses-shared.ts        # Responses API 消息转换 + 流处理
├── shell/                              # Shell 命令解析（tree-sitter bash + tokenizer）
├── patch/                              # apply_patch 格式解析器（TypeScript 复刻 Rust）
└── vendor/                             # Rust apply_patch 源码 + 预编译二进制
```

---

## 三、核心设计

### 3.1 Adapter 模式切换

当检测到模型是 **Codex-like**（provider/api/id 包含 `codex`，或 `openai` + `gpt`），自动启用 Codex 风格工具集：

| 维度 | Pi 默认 | Adapter 模式 |
|------|---------|-------------|
| 工具 | `read` `bash` `edit` `write` | `exec_command` `write_stdin` `apply_patch` |
| Shell | 任意 | `/bin/bash`（fish → bash fallback） |
| 渲染 | Pi 原生 | Codex 风格（Ran / Explored / Read / Search） |
| System prompt | Pi 默认 | 注入 Codex guidelines + shell info + skills |

切换离开 Codex-like 模型时，**恢复**之前用户的 Pi 工具配置。

### 3.2 四个核心工具

#### ① exec_command（`exec-command-tool.ts` + `exec-session-manager.ts`）

- 支持参数：`cmd`（必填）、`workdir`、`shell`、`tty`（PTY）、`yield_time_ms`、`max_output_tokens`、`login`
- **双模式**：**pipe**（默认，spawn 子进程）和 **PTY**（tty=true，node-pty）
- 会话可复用（`write_stdin` 继续交互）、可中断（AbortSignal）、输出 token 限流
- Shell 特殊处理：fish 用户 fallback 到 bash 并同步 PATH/HOME 等关键环境变量

#### ② write_stdin（`write-stdin-tool.ts`）

- 向运行中的 exec 会话写入输入，或空字符轮询
- 兼容 pipe + PTY 两种会话
- 渲染为 "Interacted with background terminal" / "Waited for background terminal"

#### ③ apply_patch（`apply-patch-tool.ts` + `patch/` 目录）

- 接受完整 patch text（`*** Begin Patch ... *** End Patch`）
- 格式：`*** Add File:` / `*** Delete File:` / `*** Update File:` + Move to + unified diff chunks
- TypeScript 复刻了 Rust 的 parser（`patch/parser.ts`），但实际**优先调用 Rust 二进制**
- 支持**部分失败**（partial_failure）：部分文件成功、部分失败，提供恢复指令（mustReadFiles / mustNotReadFiles）
- 渲染区分 Added / Edited / Deleted，失败文件高亮红色

#### ④ web_search / image_generation / view_image

- `web_search`：仅 openai-codex provider 可用，`before_provider_request` 将 function tool 改写成 Responses API 原生 `web_search` 格式
- `image_generation`：仅 image-capable openai-codex 模型，改写成 Responses API 原生格式，图片保存到 `.pi/openai-codex-images/`
- `view_image`：本地图片查看，支持 `original` detail 模式

### 3.3 OpenAI Codex Provider（`openai-codex-custom-provider.ts`，~700 行）

项目最复杂的部分，实现了完整的 OpenAI Codex Responses API 适配器：

- **传输层**：支持 HTTP + WebSocket 双模式，WebSocket 会话缓存复用（5 分钟 TTL）
- **认证**：Bearer token + `chatgpt-account-id`（从 JWT 提取）+ `originator: pi`
- **消息转换**（`openai-responses-shared.ts`）：将 Pi 的 Context messages → Responses API 格式
  - assistant 消息 → `message` items（带 text_signature 编码）
  - tool calls → `function_call` items（call_id + id 分离）
  - tool results → `function_call_output`
  - thinking → `reasoning` items（带签名缓存）
  - image_generation_call → 透传
- **流处理**：实时解析 `response.output_item.added` / `text_delta` / `function_call_arguments.delta` 等事件
- **图片保存**：base64 解码 → `.pi/openai-codex-images/{callId}-{responseId}.png` + `latest.png`
- **Web search 渲染**：收集搜索查询和来源，显示为紧凑可展开摘要
- **JWT 提取**：解析 `chatgpt_account_id` 以设置 header
- **幂等性**：流中断/重试时基于 `prompt_cache_key` + `previous_response_id` 继续

### 3.4 Shell 解析层（`src/shell/`）

三层解析：

1. **`bash.ts`**：tree-sitter-bash AST 解析，提取纯命令序列
2. **`parse-command.ts`**：将命令 token → `ParsedShellCommand`（read/list/search/unknown）
3. **`tokenize.ts`**：`shellSplit` 自定义词法分析（支持单引号、双引号、转义、连接符）

支持的命令分类：`rg`/`grep`/`ag`/`ack` → **search**；`cat`/`bat`/`less`/`head`/`tail` → **read**；`ls`/`tree`/`du` → **list**；其他 → **run**

### 3.5 System Prompt 重组（`build-system-prompt.ts`）

- 注入 **Current shell**（替换 Pi 默认 shell 信息）
- 注入 **Codex Guidelines**（5 条核心原则，合并到 Pi 的 Guidelines 段落，不重复）
- 注入 **Skills 指令**（提取 Pi 的 available_skills，写入 `<skills_instructions>` 块）

---

## 四、Rust apply_patch 二进制

- 源码：`vendor/apply-patch-src/`（Rust crate `codex-apply-patch`）
- GitHub Actions 多平台构建：linux-x64/arm64、darwin-x64/arm64、win32-x64/arm64
- TypeScript 端：`bin/apply_patch` + `bin/apply_patch.cmd` shell wrapper + `apply-patch-binary.ts` PATH 注入
- CI 流程：构建 → 上传 artifact → 下载 → 验证 → `npm publish`

---

## 五、对 Sigil 项目的参考价值

| 维度 | 可借鉴之处 |
|------|-----------|
| **工具集设计** | `exec_command` + `apply_patch` 替代传统 read/edit/write 的 shell-first 范式 |
| **PTY 会话管理** | pipe + PTY 双模式、可复用会话、AbortSignal 中断、输出 token 限流 |
| **Shell 解析** | tree-sitter bash + tokenizer 三层解析 + read/list/search/run 分类 |
| **Patch 格式** | `*** Begin Patch` 自定义格式，TS+RS 双实现，partial_failure 模式 |
| **渲染层** | 每个 tool 有 `renderCall` / `renderResult`，Codex 风格（Ran / Explored / Read） |
| **Provider 适配** | Responses API → Pi Context 双向转换（含 thinking、image、function_call 处理） |
| **WebSocket 流式** | 会话缓存、消息去重、重试 + 续传、WebSocket 消息太大关闭处理（1009） |
| **事件驱动架构** | `session_start` / `model_select` / `tool_execution_start` 等 Pi hook 精细利用 |
| **适配器开关** | 按模型能力自动切换工具集，无缝切回 |

---

## 六、局限性 & 观察

1. **TS patch parser ≠ Rust parser**：TypeScript 复刻版功能接近但不完全等价（如 `strict/lenient` mode 差异，gpt-4.1 的兼容性处理在 TS 版未体现）
2. **复杂度极高**：`openai-codex-custom-provider.ts` 单文件 ~700 行，包含大量企业级代码（WorkspaceRoot 检测、WebSocket 缓存、Web search 收集、图片保存等），与 Sigil 的 Elixir/Phoenix 架构差异大
3. **Pi 框架耦合**：高度依赖 `@earendil-works/pi-ai` / `pi-coding-agent` / `pi-tui` 的 API
4. **没有中断/权限系统**：这是一个纯工具转换扩展，没有 interrupt 或权限控制概念——这部分是 Sigil 独有的
5. **没有 MCP 概念**：Sigil 的 MCP bridge/延迟启动/Plugin bridge 架构在此项目中完全不存在
