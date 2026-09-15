# ex_fff — ETS 文件搜索引擎库 实施计划

> 日期：2026-05-15  
> 策略：独立 Elixir 库（纯 ETS，零编译链）→ Sigil 通过 ToolRegistry 接入  
> 原则：不影响主流程（Agent Loop 零改动）  
> 未来：Rust GUI 壳引入 Rust 工具链后，可替换为 Rustler NIF + fff-search（接口不变，见 `plan-fff-nif.md`）

## 一、架构概览

```
ex_fff（独立 Elixir 库）
├── ExFff.Index           — GenServer，长驻进程
│   ├── ETS table         — 文件路径 + 内容 trigram 分词缓存
│   ├── FileSystem watcher — 后台监听文件变化，增量更新 ETS
│   └── frecency heap     — 访问频率排序
├── ExFff.Query           — 查询语法解析 + 模糊匹配执行
├── ExFff.Matcher         — trigram 索引 + string_distance 算法
└── ExFff.Config          — 配置结构体

Sigil（接入层，只改 2 处）
├── mix.exs               — 加一行 dep
└── lib/sigil/tool/builtin/file_search.ex — Tool 行为实现，桥接到 ExFff
```

## 二、Phase 分解

### Phase 1：`ex_fff` 库骨架

**文件**（位于 `sigil/../ex_fff/`）：

```
ex_fff/
├── mix.exs
├── .formatter.exs
├── test/test_helper.exs
├── lib/
│   ├── ex_fff.ex
│   ├── ex_fff/
│   │   ├── config.ex
│   │   ├── index.ex
│   │   ├── query.ex
│   │   └── matcher.ex
└── test/
    ├── ex_fff_test.exs
    ├── index_test.exs
    ├── query_test.exs
    └── matcher_test.exs
```

**`mix.exs` 关键内容：**

```elixir
def project do
  [
    app: :ex_fff,
    version: "0.1.0",
    elixir: "~> 1.19",
    deps: []
  ]
end
```

**`ExFff.Config`** — 配置结构体：

```elixir
defmodule ExFff.Config do
  defstruct [
    root_path: nil,        # 项目根目录
    max_files: 50_000,     # 最大索引文件数
    ignore_patterns: [     # 忽略模式
      ~r/_build\//,
      ~r/deps\//,
      ~r/\.git\//,
      ~r/node_modules\//
    ],
    trigram_size: 3,       # trigram 分词长度
    frecency_decay: 0.9,   # frecency 衰减系数
    watcher_enabled: true  # 是否启用文件变化监听
  ]
end
```

### Phase 2：ETS 索引 + GenServer

**ETS 表设计**（`ExFff.Index`）：

| 表名 | 类型 | 键 | 值 | 作用 |
|------|------|----|----|------|
| `ex_fff_files` | `:set` | `path` (full) | `%{path, mtime, size, ext}` | 文件元数据 |
| `ex_fff_trigrams` | `:duplicate_bag` | trigram | `path` | 倒排索引 |
| `ex_fff_frecency` | `:ordered_set` | `{score, path}` | `true` | 排序用 |
| `ex_fff_content` | `:set` | `path` | `binary` | 文件内容缓存（可选） |

**GenServer 生命周期：**

```
start_link(root_path, opts)
  → init: scan_files(root_path)
    → 排除 ignore_patterns
    → 对每个文件：写 files ETS + 分词写 trigrams ETS
    → 启动 FileSystem watcher（如果开启）
  → handle_call :search → ETS 内查 trigram → 合并 frecency → 返回结果
  → handle_call :refresh → 全量重新扫描
  → handle_call :touch(path) → 更新 frecency 分数
  → handle_info :fs_event → 增量更新单文件索引
```

**启动扫描关键逻辑：**

```elixir
defp scan_files(root_path, config) do
  root_path
  |> Path.join("**/*")
  |> Path.wildcard()
  |> Enum.reject(fn p -> ignored?(p, config.ignore_patterns) end)
  |> Enum.take(config.max_files)
  |> Enum.each(&index_file/1)
end

defp index_file(path) do
  case File.stat(path) do
    {:ok, stat} ->
      :ets.insert(@table_files, {path, %{mtime: stat.mtime, size: stat.size, ext: Path.extname(path)}})
      tokenize(path)
      |> Enum.each(fn trigram ->
        :ets.insert(@table_trigrams, {trigram, path})
      end)
    {:error, _} -> :skip
  end
end
```

### Phase 3：模糊匹配 + 查询语法

**`ExFff.Matcher`** — trigram 查找 + 距离计算：

```
"user_controller" → ["use", "ser", "er_", "r_c", ...]
查询 "usr_cntrl" → ["usr", "rs_", "s_c", ...]
trigram 交集 → 候选文件列表
string_distance("usr_cntrl", "user_controller") → 排序分数
```

实现选型：
- **路径匹配**：纯 Elixir，`String.jaro_distance/2` 或更精确的 `String.jaro_winkler_distance/2`（需 `jason` 但已在 deps）
- **内容匹配**：trigram 倒排 + 文件名匹配双重打分
- **Typo 容忍**：n-gram 交集自带拼写容错

**`ExFff.Query`** — 查询语法解析：

```elixir
# 支持语法（从 fff 简化）：
#   "schema"            → 模糊匹配文件名 + 路径
#   "*.ex"              → 按扩展名过滤
#   "!test/"            → 排除路径模式
#   "user schema"       → 多词 AND 匹配

defmodule ExFff.Query do
  defstruct [
    terms: [],            # 搜索词列表
    include_patterns: [], # "*.ex", "lib/"
    exclude_patterns: [], # "!test/", "!_build/"
    limit: 20
  ]

  @spec parse(String.t()) :: %__MODULE__{}
  def parse(input) do
    tokens = String.split(input, " ", trim: true)
    # ... 解析逻辑
  end
end
```

### Phase 4：Sigil 接入 — `file_search.ex`

**只加一个新 Tool 模块，不改 Agent Loop：**

```elixir
# lib/sigil/tool/builtin/file_search.ex
defmodule Sigil.Tool.Builtin.FileSearch do
  @behaviour Sigil.Agent.Tool

  @impl true
  def name, do: "file_search"

  @impl true
  def description do
    "Search files by path or name with fuzzy matching. " <>
      "Supports patterns like '*.ex' and excludes like '!test/'."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Search query with optional patterns"},
        limit: %{type: "integer", description: "Max results", default: 20}
      },
      required: ["query"]
    }
  end

  @impl true
  def max_result_chars, do: 10_000

  @impl true
  def execute(input, context) do
    query = input["query"]
    limit = Map.get(input, "limit", 20)
    root = Map.get(context, :working_directory)

    with {:ok, index} <- ExFff.Index.ensure_started(root),
         results <- ExFff.Index.search(index, query, limit: limit) do
      formatted = format_results(results)
      {:ok, formatted}
    end
  end

  defp format_results(results) do
    results
    |> Enum.map(fn %{path: p, score: s} ->
      "#{Float.round(s, 2)}\t#{p}"
    end)
    |> Enum.join("\n")
  end
end
```

**改 `Sigil.Tool.Registry` — 加一行 `@known_tools`：**

```elixir
@known_tools [
  # ... existing ...
  Sigil.Tool.Builtin.FileSearch  # ← 新增
]
```

**改 `mix.exs` — 加 deps：**

```elixir
{:ex_fff, path: "../ex_fff"}
```

### Phase 5：衰退策略

当 ex_fff 不可用时的兜底：

```elixir
# ExFff.Index.ensure_started/1 内部
def ensure_started(root) do
  case start_link(root) do
    {:ok, pid} -> {:ok, pid}
    {:error, _reason} ->
      Logger.warning("[ExFff] Failed to start index, file_search will fall back")
      {:error, "file index unavailable"}
  end
end
```

Agent 侧 Tool 执行时收到 `{:error, _}` → LLM 会回退到 `bash("rg ...")`。

### Phase 6：Output Compactor（下一阶段）

不阻塞 ex_fff 交付，作为独立任务。

在 `lib/sigil/agent/middleware/` 下新增 `output_compactor.ex`，实现 pipeline：

```
ANSIStripper → TestAggregator → BuildFilter → GitCompactor → SmartTruncator → HardTruncator
```

此 Phase 不在本次交付范围内。

### 未来：Rustler NIF 替换（Phase 2）

当 Sigil 引入 Rust GUI 壳（Rust 工具链就绪）后，可替换 Match 后端为 fff-search：

```
Sigil.FFF.Index.search/2   ← 接口不变
  Phase 1: ETS + jaro_distance（本次）
  Phase 2: Rustler NIF + fff-search（将来）
```

参考 `docs/plan-fff-nif.md`。

## 三、不动清单

以下模块 **本任务期间不修改**：

| 模块 | 原因 |
|------|------|
| `Sigil.Agent.Turn.run_loop/2` | Agent loop 不变，工具发现走 Registry |
| `Sigil.Agent.Tool.Executor` | 统一执行入口，新 Tool 天然适配 |
| `Sigil.Web.WorkspaceLive` | 本次不接入 UI |
| `Sigil.PubSub.Session` | 不改事件结构 |
| `Sigil.Security` 层 | 新 Tool 内部做路径校验即可 |

## 四、测试命令

```bash
# ex_fff 独立测试
cd ../ex_fff
mix test

# Sigil 集成测试
cd ../sigil
mix test
```

## 五、已知风险

| 风险 | 缓解 |
|------|------|
| 大仓库首次扫描耗时 | GenServer 异步 init，不阻塞调用方 |
| ETS 内存占用 | `max_files: 50_000` 上限 + file_content 可选 |
| 文件变化 watcher 不可靠（macOS fsevent 限制） | 降级为定时全量 refresh（默认 60s） |
| trigram 索引膨胀 | ETS `:duplicate_bag` + 定期清理死文件 |
| ex_fff crash | Supervisor 隔离 + Tool 侧 `{:error, _}` 回退 |

## 六、交付物

1. `ex_fff/` — 独立 Elixir 库，含 mix.exs / lib / test
2. `sigil/mix.exs` — 加 `{:ex_fff, path: "../ex_fff"}` dep
3. `sigil/lib/sigil/tool/builtin/file_search.ex` — Tool 适配器
4. `sigil/lib/sigil/tool/registry.ex` — `@known_tools` 加一行
5. `reports/2026-05-15-ex-fff-execution-report.md` — 执行报告
