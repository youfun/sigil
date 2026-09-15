# PRD — Scoped Memory: Global + Workspace SQLite

日期：2026-05-17  
产品：Sigil（Elixir/Phoenix LiveView，本地 Web UI + Agent Runtime）  
范围：`sigil/`（Memory tools、MemoryStore、SQLite 持久化边界、测试）

---

## 1. 背景

当前 Sigil 的 Memory 系统使用单个 Ecto Repo：

- dev: 项目根目录 `sigil_dev.db`
- test: 项目根目录 `sigil_test.db`
- prod: `DATABASE_PATH`

这套配置让所有 memory 数据共享同一个 SQLite 文件，无法区分“用户全局偏好”和“某个 workspace/project 的局部知识”。但 Sigil 当前产品边界已经明确：

- conversation transcript 是全局用户可见历史，存储在 `~/.sigil/conversations/`
- runtime session snapshot 存储在 `~/.sigil/sessions/`
- event audit/debug 存储在 `~/.sigil/events/`
- workspace-local 配置和 workspace 记忆应存储在 `<workspace_path>/.sigil/`

因此 Memory 需要从“隐式单 Repo”升级为“显式 scoped memory”。全局记忆和 workspace 记忆都存在，但读写必须清楚标注 scope，避免跨项目污染或丢失用户长期偏好。

核心产品场景：

- 通用、可迁移、跨项目稳定的记忆存全局。例如 Elixir 编码规范、常见 bash 命令格式、用户长期偏好、通用工具使用习惯。
- 项目特有、依赖当前 workspace 的记忆存工作区。例如当前项目架构、模块职责、本仓库测试命令、本项目已知问题。

存储采用“全局文件 + 工作区文件”分离，而不是单 SQLite 内部加 scope 字段，主要是为了多设备同步开发：

- `~/.sigil/memory.sqlite3` 是用户 profile 层，随个人设备/账号同步。
- `<workspace_path>/.sigil/memory.sqlite3` 是项目本地层，随项目目录同步、备份、迁移或删除。
- workspace memory 可以跟随 Git checkout、Syncthing、iCloud/Dropbox、远程工作区、devcontainer volume 等项目目录流动。
- global memory 不会混入项目目录，避免用户私有偏好或跨项目知识被项目同步/共享出去。

---

## 2. 目标与非目标

### 2.1 目标（Must）

1. Memory 支持两个 scope：`global` 与 `workspace`。
2. `workspace` memory 存储在 `<workspace_path>/.sigil/memory.sqlite3`。
3. `global` memory 存储在用户级目录，例如 `~/.sigil/memory.sqlite3`。
4. `mem_learn` 能显式写入 `global` 或 `workspace`。
5. `mem_recall` 默认同时检索 `global` 与当前 `workspace`，并在结果中标注 scope。
6. `mem_recall` 支持按 scope 过滤：只查 `global` 或只查 `workspace`。
7. `mem_reinforce` 与 `mem_associate` 不允许因为不同 SQLite 中 id 相同而误操作；必须基于 scope 定位。
8. 首次访问某个 scope 的 SQLite 时自动创建目录、初始化 schema。
9. TDD 覆盖跨 workspace 隔离、global 可见性、默认 recall 合并、scope 标注、reinforce/associate 安全边界。

### 2.2 目标（Should）

1. 保留现有 Memory schema：`engrams` 与 `synapses`。
2. 尽量保留现有 `MemoryStore.learn/recall/reinforce/associate` 的语义，只扩展 scope 参数。
3. 提供向后兼容路径，让旧测试可以逐步迁移。
4. 对当前项目根目录的 `sigil_dev.db`/`sigil_test.db` 不做隐式数据迁移，除非有明确迁移命令。

### 2.3 非目标（Not Now）

- 多用户/账号级权限模型。
- conversation/session 级 memory scope。
- memory UI 管理界面。
- 向量检索、embedding、全文索引。
- 自动判断所有记忆的最佳 scope。MVP 只提供明确规则与可控默认值。
- 自动迁移已有 `sigil_dev.db` / `sigil_test.db` 数据到新 scoped 数据库。

---

## 3. 用户故事

- 我在项目 A 中告诉 Sigil “这个项目使用 SQLite 文件作为主存储”，不希望项目 B 召回这条项目局部事实。
- 我告诉 Sigil “我偏好简洁回复”，希望所有 workspace 都能召回这条全局偏好。
- 我在项目 A 中学到一个 memory 后，切到项目 B，默认 recall 只能看到 global 与项目 B 的 workspace memory。
- 我希望 memory 工具结果清楚显示每条结果来自 `global` 还是 `workspace`。
- 我强化某条 memory 时，不希望因为另一个 SQLite 文件里有同样的 id 而强化错对象。

---

## 4. Scope 模型

### 4.1 Scope 定义

| Scope | 含义 | 存储位置 | 示例 |
|---|---|---|---|
| `global` | 用户级、跨 workspace 生效的长期信息 | `~/.sigil/memory.sqlite3` | 用户偏好、通用编码习惯、长期规则 |
| `workspace` | 当前 workspace/project 局部信息 | `<workspace_path>/.sigil/memory.sqlite3` | 项目架构、测试命令、当前仓库约定 |

### 4.1.1 Workspace Scope 与 Git Project Scope

MVP 的 `workspace` scope 以 Sigil 当前选择的 `workspace_path` 为边界。未来可以扩展为 git project scope：

```bash
git rev-parse --show-toplevel
```

git project scope 的含义是：以当前 Git 仓库根目录作为项目边界。用户在 repo 的任意子目录中工作，都共享同一份项目记忆。

两者差异：

| 边界 | 含义 | 适用情况 |
|---|---|---|
| `workspace_path` | Sigil UI 当前选择的工作区目录 | 一个 workspace 就是一个项目 |
| Git repo root | `git rev-parse --show-toplevel` 得到的仓库根目录 | 一个大 workspace 内包含多个 repo |

MVP 先使用 `workspace_path`，因为它与当前 UI、Coordinator、Tool context 已经一致。若后续用户常把 monorepo 父目录或多 repo 目录作为 workspace，再引入 git project scope 作为可选策略。

### 4.2 默认规则

MVP 推荐默认：

- `mem_learn` 默认写入 `workspace`。
- `mem_recall` 默认查询 `global + current workspace`。
- `mem_reinforce` 必须明确 scope，或使用 recall 返回的 scoped reference。
- `mem_associate` 必须明确 source/target scope，MVP 只支持同 scope 关联。

原因：

- 写入默认 workspace 可以降低跨项目污染。
- recall 默认合并 global + workspace 可以保留全局偏好价值。
- reinforce/associate 是写操作，必须避免 id 碰撞。
- 通用知识可以通过显式 `scope=global` 复用到所有项目；项目知识默认隔离在当前 workspace。

### 4.3 Scope 选择建议

`global` 适合：

- 用户长期偏好：回复风格、命名偏好、常用工具偏好。
- 跨项目都成立的规则。
- 与具体代码库无关的稳定事实。
- 通用语言/框架规范：Elixir style guide、Phoenix 常见约定、Ecto changeset 使用偏好。
- 通用命令格式：常见 bash 命令写法、git 查看/比较命令习惯、测试命令组织方式。

`workspace` 适合：

- 项目架构、模块边界、测试命令、已知 bug。
- 特定仓库的代码风格。
- 特定 workspace 的业务背景或本地运行约束。
- 当前项目的存储边界、运行机制、模块入口。
- 只在当前代码库成立的排查路径或实现细节。

### 4.4 Scope 决策矩阵

| 记忆内容 | Scope | 示例 |
|---|---|---|
| 通用语言规范 | `global` | Elixir 文件命名用 snake_case，模块名用 PascalCase |
| 通用开发命令习惯 | `global` | 优先使用 `rg` 搜索文本；bash 命令避免无意义 `cd` |
| 用户长期偏好 | `global` | 用户偏好简洁结论、中文说明、先 TDD |
| 跨项目稳定工具规则 | `global` | 常见 git diff/log/status 查看方式 |
| 当前项目架构 | `workspace` | Sigil 的 ConversationTranscript 是 durable source of truth |
| 当前项目测试命令 | `workspace` | 本项目用 `mix test test/sigil/memory/...` 验证 memory |
| 当前项目存储路径 | `workspace` | Sigil conversation 存在 `~/.sigil/conversations/` |
| 当前仓库临时 bug/排查结论 | `workspace` | 某个 LiveView projection 热重载问题的排查路径 |

当模型不确定时，MVP 默认写入 `workspace`，并可在输出里说明需要用户确认是否提升为 `global`。宁可先局部保存，也不要把项目私有事实污染到全局记忆。

---

## 5. 功能规格

### 5.1 `mem_learn`

输入 schema 增加：

```json
{
  "scope": {
    "type": "string",
    "enum": ["workspace", "global"],
    "default": "workspace"
  }
}
```

行为：

- 未传 `scope`：写入当前 workspace memory。
- `scope="workspace"`：要求 tool context 中存在有效 `working_directory`。
- `scope="global"`：写入全局 memory DB。
- 返回结果包含 `id`、`kind`、`scope`。

示例输出：

```text
Learned: [workspace/preference] User prefers snake_case naming
```

### 5.2 `mem_recall`

输入 schema 增加：

```json
{
  "scope": {
    "type": "string",
    "enum": ["all", "workspace", "global"],
    "default": "all"
  }
}
```

行为：

- 未传 `scope` 或 `scope="all"`：查询 global + 当前 workspace。
- `scope="workspace"`：只查询当前 workspace。
- `scope="global"`：只查询全局。
- 结果按 relevance/order 规则合并，并标注 scope。

格式要求：

```text
1. <stored-knowledge id="12" kind="preference" scope="global">
...
</stored-knowledge>

2. <stored-knowledge id="7" kind="fact" scope="workspace">
...
</stored-knowledge>
```

注意：`id` 只在同 scope 的 SQLite 内唯一，跨 scope 不唯一。

### 5.3 `mem_reinforce`

输入 schema 调整：

```json
{
  "id": {"type": "integer"},
  "query": {"type": "string"},
  "scope": {
    "type": "string",
    "enum": ["workspace", "global"]
  }
}
```

行为：

- `id` 模式必须提供 `scope`。
- `query` 模式如果未提供 `scope`，可以按默认 recall 查询 `all`，但若命中多条不同 scope 的候选，必须返回歧义错误，要求用户提供 scope。
- 强化结果必须显示 scope。

### 5.4 `mem_associate`

MVP 输入 schema：

```json
{
  "source_id": {"type": "integer"},
  "target_id": {"type": "integer"},
  "kind": {"type": "string"},
  "scope": {
    "type": "string",
    "enum": ["workspace", "global"]
  }
}
```

行为：

- MVP 只允许同 scope 内关联。
- 必须提供 `scope`。
- 后续可以扩展为 `source_scope` + `target_scope` 的跨 scope 关联，但不在 MVP。

---

## 6. 数据与存储设计

### 6.1 文件位置

全局 memory：

```text
~/.sigil/memory.sqlite3
```

workspace memory：

```text
<workspace_path>/.sigil/memory.sqlite3
```

不得把 conversation index、session snapshot、events 存入 workspace `.sigil/`。

### 6.1.1 为什么文件分离

不采用单个 SQLite + `scope` 字段作为产品默认存储，原因：

1. 多设备同步：workspace memory 可以跟着项目目录同步，global memory 可以跟着用户 profile 同步。
2. 备份/迁移清晰：删除或迁移某个 workspace 时，只影响该 workspace 的 memory。
3. 泄漏风险更低：项目私有知识不会进入全局 DB，用户私有偏好也不会进入项目目录。
4. 边界可观察：看到 `<workspace>/.sigil/memory.sqlite3` 就知道这是该项目的 Sigil local state。
5. 后续策略灵活：团队可以选择忽略、备份或共享 workspace memory，但 global memory 始终属于用户个人层。

默认建议：workspace SQLite 是机器生成的运行态记忆，通常不应直接提交到 Git。若团队需要共享稳定项目规则，优先使用 repo 内文档、`AGENTS.md` 或未来的 workspace rules 文件；SQLite memory 更适合个人 agent 在该项目里的经验积累。

### 6.2 Schema

沿用当前迁移创建的表：

- `engrams`
- `synapses`

可继续使用 `schema_migrations` 记录 migration version。

### 6.3 初始化

首次访问某个 DB 时：

1. 创建父目录。
2. 打开 SQLite。
3. 执行 migration 或确保 schema 存在。
4. 继续本次 memory 操作。

初始化必须是并发安全的：同一个 workspace 同时触发多个 memory tool 时，不应造成 schema 创建冲突。

### 6.4 Ecto Repo 边界

当前 `Sigil.Repo` 是全局 supervised Repo，并被测试 sandbox 使用。MVP 推荐不要直接把它改成动态切库，而是新增 Memory 专用边界：

- `Sigil.Memory.Database`：负责 scope -> database path、初始化、连接配置。
- `Sigil.Memory.MemoryStore`：接受 `scope`/`workspace_path`，在对应 DB 中执行 CRUD。

实现可选方案：

1. 使用动态 Repo/checkout，每次按 SQLite path 操作。
2. 使用 Memory 专用 Repo supervisor，按 database path 缓存连接。
3. 使用 `Ecto.Adapters.SQL` 动态配置或底层 SQLite 操作封装。

选择标准：

- 优先保证 scope 正确、并发稳定、测试清晰。
- 不让 application-level `Sigil.Repo` 继续决定 memory 存储位置。

---

## 7. Agent 流程接入

当前上游已具备 workspace 传递链路：

```text
WorkspaceLive current_workspace_path
  -> Coordinator opts[:workspace_path]
  -> Agent run opts[:working_directory]
  -> Agent.Config.working_directory
  -> Tool.Executor context[:working_directory]
  -> Memory tools
```

需要补齐的是最后一步：

```text
Memory tools read context[:working_directory]
  -> resolve scoped memory database
  -> MemoryStore operation
```

不需要改 conversation transcript、session store、event recorder 的存储路径。

---

## 8. TDD 计划

### 8.1 第一组：Database path 与初始化

先写失败测试：

1. `global_path/0` 返回 `~/.sigil/memory.sqlite3` 或测试覆盖路径。
2. `workspace_path(workspace)` 返回 `<workspace>/.sigil/memory.sqlite3`。
3. 首次 learn 会创建对应 SQLite 文件与 schema。
4. workspace memory 不创建或修改 `~/.sigil/conversations/`、`~/.sigil/sessions/`、`~/.sigil/events/`。

### 8.2 第二组：learn/recall scope 行为

先写失败测试：

1. workspace A learn，workspace A recall 能看到。
2. workspace A learn，workspace B recall 看不到。
3. global learn，workspace A/B recall 默认都能看到。
4. default recall 返回 global + current workspace。
5. `scope="workspace"` 只返回 workspace。
6. `scope="global"` 只返回 global。
7. recall 输出包含 `scope="global"` / `scope="workspace"`。

### 8.3 第三组：写操作安全

先写失败测试：

1. `mem_reinforce id without scope` 返回错误。
2. `mem_reinforce id + global scope` 只强化 global DB。
3. `mem_reinforce id + workspace scope` 只强化当前 workspace DB。
4. 不同 scope 中相同 id 不会互相影响。
5. `mem_associate without scope` 返回错误。
6. `mem_associate` 只能关联同 scope engram。

### 8.4 第四组：Agent pipeline

先写失败测试：

1. `Agent.run/2` 在 workspace A 通过 fake provider 调用 `mem_learn`，创建 workspace A memory DB。
2. `Agent.run/2` 在 workspace B recall 不返回 workspace A memory。
3. global memory 可被两个 workspace 的 Agent.run recall。

---

## 9. 验收标准

1. `mem_learn` 支持 `scope=workspace/global`，默认 workspace。
2. `mem_recall` 支持 `scope=all/workspace/global`，默认 all。
3. recall 结果明确标注 scope。
4. workspace A 的 workspace memory 不会出现在 workspace B 的 workspace recall 中。
5. global memory 会出现在 workspace A/B 的默认 recall 中。
6. `mem_reinforce` by id 不提供 scope 时拒绝执行。
7. `mem_associate` 不提供 scope 时拒绝执行。
8. 首次使用 memory 时自动创建目标 DB 与 schema。
9. conversation/session/events 默认路径不受 workspace memory 改造影响。
10. 测试覆盖 scoped memory 的隔离与合并行为。

---

## 10. 迁移与兼容策略

### 10.1 旧数据库

现有 `sigil_dev.db` / `sigil_test.db` / `DATABASE_PATH` 不再作为 Memory 产品默认存储。

MVP 不自动迁移旧数据，原因：

- 当前本地数据库可能为空或仅用于开发测试。
- 自动判断旧 memory 属于 global 还是 workspace 风险较高。

后续可提供显式 Mix task：

```bash
mix sigil.memory.migrate --from sigil_dev.db --to-scope global
mix sigil.memory.migrate --from sigil_dev.db --to-workspace /path/to/workspace
```

### 10.2 测试兼容

现有 `Sigil.DataCase` 依赖 `Sigil.Repo` sandbox。Scoped memory 测试应优先使用临时目录和真实 SQLite 文件，避免 sandbox 掩盖跨文件隔离问题。

可保留少量旧 `MemoryStore` 单库测试作为 schema/changeset 层测试，但产品行为测试必须走 scoped DB。

---

## 11. 风险与决策点

### 11.1 Repo 连接管理

风险：每个 workspace 一个 SQLite 文件，如果每次工具调用都启动新连接，可能带来开销或并发锁问题。

决策：MVP 可以先保证正确性；若发现性能问题，再引入按 database path 缓存的 supervised Repo/connection。

### 11.2 Scope 自动判断

风险：让模型自动决定 global/workspace 可能误把项目细节写入 global。

决策：默认写 workspace。只有明确用户偏好、跨项目规则，或工具输入显式 `scope=global` 才写 global。

### 11.3 ID 碰撞

风险：global 与 workspace SQLite 都从 id=1 开始。

决策：任何写操作都必须携带 scope；recall 输出必须展示 scope；内部引用应视为 `{scope, id}`，不是裸 id。

---

## 12. Open Questions

1. global memory 是否允许配置到 `SIGIL_GLOBAL_MEMORY_DB`，方便测试与便携部署？
2. workspace memory 文件名是否固定为 `memory.sqlite3`，还是使用 `memory.db`？
3. `mem_learn` 是否需要增加 `scope_reason` 或 metadata，记录为何写入 global/workspace？
4. `mem_recall scope=all` 合并排序时，global 与 workspace 同时匹配是否需要 workspace 优先？
5. 是否需要在 system prompt 中明确教模型：项目事实默认写 workspace，用户长期偏好才写 global？
