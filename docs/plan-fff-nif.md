# fff-search + Rustler NIF 集成实施计划

> 日期：2026-05-15  
> 策略：Rustler NIF 封装 fff-search crate → Sigil 内 GenServer + ToolRegistry 接入  
> 注意：此文档为**未来参考**。当前 Sigil 无 Rust 编译链（打包用 Burrito/Zig），
> 本次实施走纯 Elixir ETS 方案（`plan-ex-fff.md`）。
> 待 Rust GUI 壳引入 Rust 工具链后，再评估切换。

## 一、为什么不用 ETS 自建

| 维度 | ETS + jaro_distance（本次） | Rustler + fff-search（将来） |
|------|---------------------------|---------------------------|
| 模糊匹配 | `String.jaro_distance`，typo 容忍弱 | typo-resistant，专为文件搜索优化 |
| 查询语法 | 自己写 parser | `"*.rs !test/ schema"` 原生支持 |
| 编译链 | 零 | Rust（需 Rust 工具链就绪） |
| 先例 | 无 | `elixir_files` 已验证可行 |

## 二、架构

```
sigil/
├── mix.exs                        → deps 加 {:rustler, "~> 0.36"}
├── native/fff/
│   ├── Cargo.toml                  → 依赖 fff-search crate
│   └── src/lib.rs                  → NIF: init, find_files, destroy
├── lib/sigil/fff/
│   ├── nif.ex                      → Rustler 自动生成或手写 binding（~use Rustler~）
│   └── index.ex                    → GenServer（参考 elixir_files ElixirFiles.FFF）
├── lib/sigil/tool/builtin/
│   └── file_search.ex              → Tool 行为实现
└── lib/sigil/tool/registry.ex      → @known_tools 加一行
```

## 三、Phase 分解

### Phase 1：Rust NIF (`native/fff/`)

**`native/fff/Cargo.toml`：**

```toml
[package]
name = "fff_nif"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
rustler = "0.36"
fff-search = "0.1"   # 或具体 commit hash
```

**`native/fff/src/lib.rs`：**

```rust
use rustler::{Env, Term, NifResult, ResourceArc};
use fff_search::FileFinder;

struct FffResource {
    finder: FileFinder,
}

#[rustler::nif]
fn init(path: String) -> NifResult<ResourceArc<FffResource>> {
    let finder = FileFinder::create(&path)
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    Ok(ResourceArc::new(FffResource { finder }))
}

#[rustler::nif]
fn find_files(
    resource: ResourceArc<FffResource>,
    query: String,
    max_results: usize,
) -> NifResult<Vec<String>> {
    let results = resource.finder.search(&query, max_results)
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    Ok(results) // Vec<String> of file paths
}

rustler::init!("Elixir.Sigil.FFF.Nif", [init, find_files]);
```

> **注意**：`fff-search` 的具体 API（`FileFinder::create`、`.search`）需要查阅 fff-search crate 文档对齐。`elixir_files` 的 Rust 侧代码因 GitHub API rate limit 未完全读取，实现时直接查 fff-search docs。

### Phase 2：Elixir NIF 绑定 (`lib/sigil/fff/nif.ex`)

参考 `elixir_files` 的 `ElixirFiles.FFF.Nif` 模块：

```elixir
defmodule Sigil.FFF.Nif do
  use Rustler, otp_app: :sigil, crate: "fff_nif"

  # Returns {:ok, resource} or {:error, reason}
  def init(_path), do: :erlang.nif_error(:nif_not_loaded)

  # Returns {:ok, [path_string]} or {:error, reason}
  def find_files(_resource, _query, _max_results), do: :erlang.nif_error(:nif_not_loaded)
end
```

### Phase 3：GenServer 封装 (`lib/sigil/fff/index.ex`)

直接参考 `elixir_files` 的 `ElixirFiles.FFF`（代码已验证），适配为 Sigil 模块：

```elixir
defmodule Sigil.FFF.Index do
  use GenServer
  require Logger
  alias Sigil.FFF.Nif

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def search(query, max_results \\ 20) do
    GenServer.call(__MODULE__, {:search, query, max_results}, 5_000)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("[FFF] Search timed out: #{query}")
      {:error, :timeout}
  end

  @impl true
  def init(_opts) do
    path = File.cwd!()
    case Nif.init(path) do
      {:ok, resource} ->
        {:ok, %{resource: resource, indexed_path: path}}
      {:error, reason} ->
        Logger.error("[FFF] NIF init failed: #{reason}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:search, query, max_results}, _from, state) do
    case Nif.find_files(state.resource, query, max_results) do
      {:ok, paths} -> {:reply, {:ok, paths}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end
end
```

### Phase 4：Tool 适配器 (`lib/sigil/tool/builtin/file_search.ex`)

```elixir
defmodule Sigil.Tool.Builtin.FileSearch do
  @behaviour Sigil.Agent.Tool

  @impl true
  def name, do: "file_search"

  @impl true
  def description do
    "Fast fuzzy file search using in-memory index. " <>
      "Supports typo-resistant matching and patterns like '*.ex !test/'."
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
  def execute(%{"query" => query} = input, _context) do
    limit = Map.get(input, "limit", 20)

    case Sigil.FFF.Index.search(query, limit) do
      {:ok, paths} ->
        output =
          paths
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {path, i} -> "#{i}.\t#{path}" end)
        {:ok, output}

      {:error, reason} ->
        {:error, "File search failed: #{reason}"}
    end
  end

  def execute(_input, _context), do: {:error, "query is required"}
end
```

### Phase 5：注册 + dep 接入

**`mix.exs` deps 加：**

```elixir
{:rustler, "~> 0.36"}
```

> Burrito 已有，无需重复声明。

**`lib/sigil/tool/registry.ex` 的 `@known_tools` 加：**

```elixir
Sigil.Tool.Builtin.FileSearch
```

**`lib/sigil/application.ex` 的 supervision tree 加：**

```elixir
{Sigil.FFF.Index, []}
```

## 四、不动清单

| 模块 | 原因 |
|------|------|
| `Sigil.Agent.Turn.run_loop/2` | Agent loop 不变 |
| `Sigil.Agent.Tool.Executor` | 统一 Tool 执行，天然兼容 |
| `Sigil.Web.WorkspaceLive` | 不接 UI |
| `Sigil.PubSub.Session` | 不改事件 |
| `Sigil.Security` | 路径校验在 fff-search 内部 |

## 五、测试

```bash
# 编译 NIF
mix compile

# 全量测试
mix test
```

## 六、已知风险

| 风险 | 缓解 |
|------|------|
| fff-search API 可能不匹配 elixir_files | 先读 fff-search docs，必要时读其源码 |
| NIF crash 拖垮 BEAM | GenServer 隔离 + try/catch + 衰退回 bash(rg) |
| 大仓库首扫慢 | fff 异步扫描，不阻塞 |
| Burrito(Zig) + Rustler 双编译链 | 需 CI 装两个交叉编译工具链，验证 priv/native 正确打入 release |

## 七、交付物

1. `sigil/native/fff/` — Cargo.toml + lib.rs
2. `sigil/lib/sigil/fff/nif.ex` — NIF 绑定
3. `sigil/lib/sigil/fff/index.ex` — GenServer
4. `sigil/lib/sigil/tool/builtin/file_search.ex` — Tool
5. `sigil/mix.exs` — deps 加 rustler
6. `sigil/lib/sigil/tool/registry.ex` — @known_tools 加一行
7. `sigil/lib/sigil/application.ex` — supervisor 加 Index
8. `sigil/reports/2026-05-15-fff-nif-execution-report.md`
