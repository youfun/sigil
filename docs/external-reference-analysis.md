# 外部参考项目分析报告

> 日期：2026-05-15  
> 分析项目：[fff](https://github.com/dmtrKovalenko/fff) / [pi-rtk-optimizer](https://github.com/MasuRii/pi-rtk-optimizer)  
> 目标项目：Sigil — 自主可控的 AI 编码助手 (Elixir/Phoenix)

---

## 一、fff — 文件搜索引擎库

### 1.1 项目概述

fff 是一个长驻进程的内存索引文件搜索库（而非 CLI 工具如 ripgrep/fzf）。核心差异在于：

- **ripgrep/fzf**：每次调用 fork 新进程，重新读取 .gitignore、重新 stat 目录、重建内存状态
- **fff**：索引和文件缓存常驻一个长生命周期进程中，一次 `FileFinder.create()` 后所有查询命中热内存

**性能对比（Chromium 500k 文件）：**

| 工具 | 每次查询延迟 |
|------|------------|
| ripgrep（spawn） | 3–9 秒 |
| fff（warm） | < 10 ms |

### 1.2 核心特性

| 特性 | 说明 |
|------|------|
| **typo-resistant 模糊匹配** | 比 fzf 更全面的算法，容忍拼写错误 |
| **查询语言** | 支持文件模式匹配 + 约束解析，如 `"*.rs !test/ schema"` |
| **frecency 排序** | 基于访问频率和时效的文件排序 |
| **后台文件观察者** | 自动感知文件系统变化，增量更新索引 |
| **轻量内存内容索引** | 适合频繁搜索的场景 |

### 1.3 可用接口层

| 层 | 说明 |
|----|------|
| **Rust crate (`fff-search`)** | 原生 Rust 库，稳定 API |
| **C library (`libfff_c`)** | 稳定 C ABI，可从 C/C++、Zig、Go (cgo)、Python (ctypes) 等绑定 |
| **Node/Bun SDK (`@ff-labs/fff-node`)** | TypeScript 封装 |
| **MCP Server** | 通过 MCP 协议为 AI agent 提供文件搜索工具 |
| **Pi Agent Extension** | 替换 Pi 原生工具，提供 @-mention 自动补全 |
| **Neovim Plugin** | 编辑器内文件搜索选择器 |

### 1.4 对 Sigil 的适用性

#### 场景 1：替换底层文件搜索

Sigil 的 Agent 在编程任务中需频繁搜索文件（通过 bash 工具调用 `rg`/`grep`）。每次调用 fork 新进程：

- **Erlang/Elixir 进程模型下**，rg 的 fork 开销在大量查询时累积明显
- Agent 单次 turn 可能产生 3–5 次搜索 → 累积延迟达 10–45 秒（大仓库）

**集成方案 A — Rustler NIF（推荐）：**

```
lib/sigil/search/fff_nif.ex  →  Rustler NIF 封装
native/fff_nif/              →  Rust crate, 依赖 fff-search
```

优势：零进程边界开销，直连 BEAM 内存。

**集成方案 B — Port/外部进程：**

通过 Erlang `Port` 持有一个长运行的 fff 后台进程，Elixir 侧通过 port 消息通信。

优势：实现简单，不引入 Rust 编译链；劣势：序列化开销。

#### 场景 2：frecency 驱动的文件浏览

sigil 的 WorkspaceLive 三栏布局可受益于 frecency 排序：

- 文件树/搜索面板按访问频率排序
- @-mention 自动补全优先显示最近/频繁使用的文件

#### 场景 3：MCP 工具集成

fff 已有完整 MCP server 实现。若 sigil 未来支持 MCP 协议，可直接接入。

---

## 二、pi-rtk-optimizer — 工具输出压缩 Pipeline

### 2.1 项目概述

pi-rtk-optimizer 是一个 Pi coding agent 的 TypeScript 扩展，核心功能：

1. **命令重写**：将 bash 工具命令自动重写为 RTK 等效命令
2. **输出压缩**：多阶段 pipeline 压缩工具输出，减少 context window 消耗

### 2.2 输出压缩 Pipeline

| 阶段 | 描述 | Sigil 对应场景 |
|------|------|---------------|
| **ANSI Stripping** | 移除终端颜色/格式码 | `mix test`、`mix compile` 输出的 ANSI 码 |
| **Test Aggregation** | 汇总测试运行输出（pass/fail 计数） | `mix test` → 只保留失败详情 + 计数 |
| **Build Filtering** | 提取编译输出的 error/warning | `mix compile` → 丢弃成功编译模块 |
| **Git Compaction** | 压缩 git status/log/diff | Agent 频繁调用 git 命令 |
| **Linter Aggregation** | 汇总 lint 工具输出 | `mix credo`、`dialyzer` |
| **Search Grouping** | 按文件分组 grep/rg 结果 | 减少重复文件名行 |
| **Source Code Filtering** | 移除注释/空白（可配级别） | read 工具返回的文件内容 |
| **Smart Truncation** | 保留文件边界和关键行 | 保证 80 行 read 精确不截断 |
| **Hard Truncation** | 最终字符数硬限制 | 防止单次工具结果溢出 |

### 2.3 对 Sigil 的适用性

#### 核心价值：Token 节省

Sigil 的 agent loop（`Sigil.Agent.Turn.run_loop/2`）每次工具调用结果都送回 LLM。以一次典型 turn 为例：

```
read file_a.ex   → 300 lines, ~800 tokens
bash "mix test"  → 200 lines, ~600 tokens (大量重复 ANSI 码)
bash "git diff"  → 150 lines, ~450 tokens
─────────────────────────────────────────
未压缩：~1,850 tokens
压缩后：~400 tokens（节省约 78%）
```

#### 架构建议：Middleware 层

在 `lib/sigil/agent/middleware/` 下新增 `OutputCompactor` 中间件，位于 Tool 结果返回前：

```
Tool 执行 → 原始结果 → OutputCompactor Pipeline → 压缩结果 → LLM
```

**模块设计：**

```elixir
# lib/sigil/agent/middleware/output_compactor.ex
defmodule Sigil.Agent.Middleware.OutputCompactor do
  @pipeline [
    ANSIStripper,
    TestAggregator,     # mix test 专用
    BuildFilter,        # mix compile 专用
    GitCompactor,       # git 命令专用
    LinterAggregator,   # credo/dialyzer 专用
    SearchGrouper,      # rg/grep 输出
    SourceCodeFilter,   # read 工具输出
    SmartTruncator,
    HardTruncator
  ]

  def compact(tool_output, tool_name) do
    @pipeline
    |> Enum.reduce(tool_output, fn stage, output ->
      stage.process(output, tool_name)
    end)
  end
end
```

#### Session Metrics

pi-rtk-optimizer 的 session metrics 追踪每个工具类型的压缩节省量。sigil 可通过 PubSub 事件（`Sigil.PubSub.Session`）发布压缩统计，在 WorkspaceLive UI 展示。

---

## 三、综合建议

### 3.1 优先级排序

| 优先级 | 项目 | 内容 | 预期收益 | 预估工作量 |
|--------|------|------|----------|-----------|
| **P0** | pi-rtk-optimizer | Output Compactor 中间件 | Token 消耗降低 50–80% | 2–3 天 |
| **P1** | pi-rtk-optimizer | Session Metrics + UI | 可观测压缩效果 | 0.5 天 |
| **P2** | fff | 通过 Port 集成文件搜索 | 搜索延迟降低 10–100x | 1–2 天 |
| **P3** | fff | Rustler NIF 集成 | 最优性能 | 3–5 天 |
| **P4** | fff | frecency 驱动 UI 自动补全 | UX 提升 | 2–3 天 |

### 3.2 技术决策要点

1. **Output Compactor 是纯 Elixir 实现**：pi-rtk-optimizer 的设计可直接翻译，不需要外部依赖
2. **fff 集成建议先走 Port 方案**：降低引入 Rust 编译链的风险，验证效果后再迁移到 NIF
3. **不引入命令重写功能**：pi-rtk-optimizer 的 bash → RTK 重写依赖外部 `rtk` 二进制，对 Elixir/Mix 生态无意义
4. **pipeline 顺序很重要**：ANSI stripping 必须在最前面，smart truncate 必须在 hard truncate 之前

### 3.3 未覆盖但有价值的点

| 特性 | 来源 | 说明 |
|------|------|------|
| 内容索引 | fff | 对文件内容建索引，支持全文搜索（当前 sigil 只有路径搜索） |
| 并发查询 | fff | fff 内部通过 `crossbeam` 并行化搜索，Elixir 可用 Task.async_stream |
| 可配置 Pipeline | pi-rtk-optimizer | TUI 设置面板实时开关各压缩阶段 → sigil 可在 WorkspaceLive 设置面板实现 |

---

## 四、风险与注意事项

| 风险 | 缓解措施 |
|------|---------|
| fff 的 C ABI 稳定性 | 固定版本依赖，锁定 commit hash |
| 输出压缩误删关键信息 | 每个阶段写单元测试，渐进启用 |
| 压缩增加 CPU 开销 | 正则/字符串处理在 BEAM 上成本低，实测后再优化 |
| Rustler NIF 编译链复杂 | Port 方案先行验证，确认收益后迁移 |

---

## 五、下一步行动

1. 启动 **Output Compactor P0** 实现，参考 pi-rtk-optimizer 的 pipeline 设计
2. 在 `mix test` 输出上先做 Test Aggregation + ANSI Stripping，验证 token 节省效果
3. 根据实测数据决定是否继续推进 fff 集成
