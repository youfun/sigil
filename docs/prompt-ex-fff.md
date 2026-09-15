# pi agent 执行提示词

## 直接执行

复制下面整段命令到终端：

```bash
pi -p '任务：在 sigil 项目中实现 ex_fff（ETS-based 文件搜索引擎）并通过 ToolRegistry 接入。

## 背景

sigil 是一个 Elixir/Phoenix AI 编码助手（位于 sigil/ 目录）。agent loop 通过 ToolRegistry 发现和调用工具。当前文件搜索靠 bash("rg ...")，每次 fork 新进程在大仓库下延迟 3-9 秒。

目标：创建一个独立的 Elixir 库 `ex_fff`（位于 sigil/../ex_fff/），用 ETS + GenServer 实现内存索引文件搜索（毫秒级），并通过 ToolRegistry 接入 Sigil，不影响主流程。

当前项目无 Rust 编译链（打包用 Burrito/Zig），因此本次用纯 Elixir ETS 方案。将来引入 Rust GUI 壳后可将匹配后端替换为 Rustler NIF + fff-search，接口不变。

## 要求

### 1. 创建独立库 `ex_fff/`（位于 sigil/../ex_fff/）

目录结构：
```
ex_fff/
├── mix.exs
├── .formatter.exs
├── test/test_helper.exs
├── lib/
│   ├── ex_fff.ex
│   ├── ex_fff/
│   │   ├── application.ex
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

#### mix.exs

app: ex_fff, elixir ~> 1.15, 零外部 deps。

#### ExFff.Application

OTP Application，supervision tree 挂 `ExFff.Index`。

#### ExFff（主模块）

`ExFff.search/1` 便捷函数，内部调用 Index GenServer。

#### ExFff.Config

结构体字段：
- `:root_path` — 项目根目录
- `:max_files` — 最大索引文件数，默认 50_000
- `:ignore_patterns` — regex 列表，默认忽略 `_build/`、`deps/`、`.git/`、`node_modules/`、`cover/`

#### ExFff.Index（GenServer）

公共 API：
- `start_link(opts)` — 启动，异步扫描文件建 ETS 索引
- `search(pid \\ __MODULE__, query, opts)` — 查询，返回 `%{paths: [%{path, score}], query: query, duration_ms: ms}`
- `touch(pid \\ __MODULE__, path)` — 更新 frecency（Tool 成功调文件后调用）
- `refresh(pid \\ __MODULE__)` — 全量重扫描

内部 struct `%State{root_path, config, frecency_ref, trigram_ref, files_ref}`。

ETS 表（`:named_table` + `:protected`）：
- `ExFff.Trigrams`（`:duplicate_bag`）：trigram → path
- `ExFff.Files`（`:set`）：path → %{mtime, size}
- `ExFff.Frecency`（`:ordered_set`）：{score, path} → true

init 流程：
1. `Path.wildcard(Path.join(root, "**/*"))` 获取文件列表
2. 用 `Path.relative_to(path, root)` 存相对路径
3. 排除 `ignore_patterns`（用 `String.match?` 匹配 path）
4. 限制 `max_files`
5. 对每个文件：stat → 写 Files 表，分词取 trigram → 写 Trigrams 表
6. 执行搜索任务 -> 返回结果

分词逻辑（`ExFff.Matcher.tokenize/1`）：
- 用 `String.split(path, ["/", "_", "-", "."])` 分割路径
- 再按大小写边界拆分（如 `UserController` → `user`, `controller`）
- 每个 token 取 sliding window trigram（不足 3 字符的 token 跳过）
- 结果去重

frecency 公式：`new_score = old_score * @decay + @boost`，decay 默认 0.9，boost 默认 100。frecency 表按 score 降序排列。

#### ExFff.Query

`parse(string)` → `%ExFff.Query{terms, include_patterns, exclude_patterns, limit}`

支持语法：
- `"schema"` → terms（模糊匹配文件名）
- `"*.ex"` → include_patterns（glob 只匹配后缀）
- `"!test/"` → exclude_patterns（排除路径含该子串）
- `"user controller"` → 多词 AND（terms = ["user", "controller"]）

#### ExFff.Matcher

`match(query, files_tab, trigram_tab, frecency_tab)` → `[%{path, score}]`

流程：
1. 对 query.terms 每个词取 trigram
2. 从 Trigrams 表查每个 trigram 对应的路径集合
3. 所有路径集合取交集（`:ets.select` + `MapSet.intersection`）→ 候选文件集
4. 对候选文件用 `String.jaro_distance/2` 算相似度（query term vs 文件名/路径各分量）
5. 取出 frecency 分数，加权合并相似度和 frecency（默认权重 0.7 similarity + 0.3 frecency → 归一化）
6. apply include/exclude 过滤
7. 按 score 降序排序，limit 截断

### 2. Sigil 接入

**新建：** `sigil/lib/sigil/tool/builtin/file_search.ex`

实现 `Sigil.Agent.Tool` behaviour：
- `name/0` → `"file_search"`
- `description/0` → "Fast fuzzy file search in the workspace. Supports typo-tolerant matching, file extension filters (e.g. *.ex), and path exclusions (e.g. !test/)."
- `input_schema/0` → JSON schema: query (string, required) + limit (integer, default 20)
- `max_result_chars/0` → 10_000
- `execute/2`：
  1. 检查 working_directory，调用 `ExFff.Index.ensure_started(root)`
  2. 调用 `ExFff.Index.search(pid, query, limit: limit)`
  3. 结果格式化为 "1.\tlib/sigil/agent/turn.ex\n2.\t..." 文本
  4. 对每个返回的 path 调用 `ExFff.Index.touch(pid, path)` 更新 frecency
  5. 返回 `{:ok, formatted_text}` 或 `{:error, reason}`

**ExFff.Index.ensure_started/1** 需要新增：如果 Index 已启动（`Process.whereis(ExFff.Index)` + `Process.alive?` 判断）则返回 `{:ok, pid}`，否则 `start_link(root)`。如果 start_link 失败返回 `{:error, reason}` —— agent 会回退到 bash("rg ...")。

**修改文件：**
- `sigil/mix.exs`：deps 列表末尾加 `{:ex_fff, path: "../ex_fff"}`
- `sigil/lib/sigil/tool/registry.ex`：`@known_tools` 追加 `Sigil.Tool.Builtin.FileSearch`

### 3. 不改的内容（必须遵守）

- `Sigil.Agent.Turn` — 零改动
- `Sigil.Agent.Tool.Executor` — 零改动
- `Sigil.Agent.Tool` behaviour — 零改动
- `SigilWeb.WorkspaceLive` — 不接 UI
- `Sigil.Security` — 不改
- `Sigil.PubSub` — 不改
- `Sigil.Application` — 不改（ex_fff 有自己的 Application）

### 4. 测试要求

**ex_fff 测试（用 ExUnit，在临时目录中创建测试文件）：**

- `index_test.exs` — 创建 tmp 目录 + 测试文件 → start_link、search 返回正确结果、touch 更新 frecency 影响排序
- `query_test.exs` — parse 空字符串、单 term、glob 模式、排除模式、多词 AND、混合模式
- `matcher_test.exs` — tokenize 路径分词、jaro_distance 匹配、frecency 加权、include/exclude 过滤、limit 截断

**Sigil 测试：**

- 在 `sigil/test/sigil/tool/builtin/` 下创建 `file_search_test.exs`
- 验证 Tool behaviour 回调（name / description / input_schema 返回值非空）
- 验证 execute 对缺少 query 返回 error

### 5. 开发约定

- SnAkE_cAsE 文件名 / PascalCase 模块名
- 谓词函数以 `?` 结尾（如 `ignored?/2`）
- `:ok/:error` tuple 模式
- 禁止 `IO.inspect`，用 `dbg/2`
- 禁止 `Process.sleep` 掩盖并发问题
- 不可变数据、显式管道、信任 BEAM

### 6. 完成后

1. 运行 `cd ex_fff && mix test` 确保全部通过
2. 运行 `cd sigil && mix test` 确保无 regression
3. 如果全量 mix test 有失败，区分是本任务引入的 failure 还是既有 unrelated failure
4. 运行 `mix compile` 确保无 warning
5. 运行 `mix format` 确保格式一致
6. 写执行报告到 `sigil/reports/2026-05-15-ex-fff-execution-report.md`

报告格式要求：
- 包含：任务目标、实际完成内容、修改/新增文件列表、未完成或刻意未做的内容
- 测试命令与结果、已知风险、后续建议
- 必须写清楚是否改动主流程、是否接入 UI、是否引入网络调用或外部进程
- 不得写入 API key、token、cookie、真实密钥或敏感配置
- 如果全量 mix test 失败，必须区分是本任务引入的问题还是既有 unrelated failure' --provider stepfun-anthropic --model step-router-v1 --no-session
```

## 提示词要点

| 维度 | 内容 |
|------|------|
| 策略 | 纯 Elixir ETS，零外部编译链依赖 |
| 不改动 | Agent loop / Executor / UI / Security / PubSub |
| 新增 8 文件 | ex_fff 库（7 文件）+ sigil FileSearch Tool（1 文件） |
| 修改 2 文件 | sigil/mix.exs（dep）+ registry.ex（@known_tools） |
| 测试 | ex_fff 独立测试 + sigil FileSearch Tool 单元测试 |
| 交付物 | 代码 + 执行报告 |

## 未来扩展（不在本次范围）

当 Sigil 引入 Rust GUI 壳后，可将 `Matcher` 后端替换为 Rustler NIF + fff-search。`Sigil.Tool.Builtin.FileSearch.execute/2` 无需改动，接口不变。详见 `sigil/docs/plan-fff-nif.md`。
