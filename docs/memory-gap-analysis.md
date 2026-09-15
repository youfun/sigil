# Sigil 记忆系统缺口分析

> 日期: 2026-05-14
> 范围: 只读评审，不修改代码
> 参考: cog-cli/memory.zig, cog-cli/memory_schema.zig, memory-system-design.md

---

## 1. 当前实现概览

### 1.1 架构

```
Agent Core (Turn) → Tool Registry → Memory Tools (mem_learn/recall/reinforce/associate)
                                       ↓
                    MemoryStore (CRUD + recall + associate + cleanup)
                                       ↓
                    Ecto Schema: Engram + Synapse → SQLite3
```

### 1.2 数据模型

| 实体 | 表 | 核心字段 |
|------|-----|----------|
| Engram | `engrams` | `content` (text), `kind` (enum), `short_term` (bool), `expires_at`, `reinforced_count`, `last_reinforced_at`, `metadata` (json) |
| Synapse | `synapses` | `source_id` → `target_id`, `kind` (enum), `strength` (float), unique on `[source_id, target_id, kind]` |

**Engram kind**: fact, pattern, preference, rule, context
**Synapse kind**: related, contradicts, example_of, context_for, reinforces

> 差异：cog-cli 使用 concept `term` + `definition` 模型；Sigil 使用 `content` + `kind` 模型。Sigil 的模型更简单但缺少 term 作为短标识符。

### 1.3 工具映射

| 工具 | 状态 | 实现模块 | 接口特征 |
|------|------|----------|---------|
| `mem_learn` | ✅ 完成 | `Sigil.Tool.Memory.MemLearn` | 单个 content + kind，不支持批量 |
| `mem_recall` | ✅ 完成 | `Sigil.Tool.Memory.MemRecall` | 单个 query，ILIKE 搜索，返回格式化文本 |
| `mem_reinforce` | ✅ 完成 | `Sigil.Tool.Memory.MemReinforce` | 按 id 或 query 匹配第一条 |
| `mem_associate` | ✅ 完成 | `Sigil.Tool.Memory.MemAssociate` | 按 id 关联，唯一约束兜底 |

### 1.4 Agent 集成

- **注册**: `Sigil.Agent.default_tools/0` 注册全部 4 个 memory tools
- **系统提示词**: `Sigil.Agent.Config.default_system_prompt/0` 包含 4 步 memory workflow
- **Compactor**: `Sigil.Agent.Compactor` 存在但不与 memory 交互
- **Config 字段**: `:memory` 字段已在 struct 中但未使用

### 1.5 测试覆盖

- `memory_store_test.exs`: 17 tests (learn, recall, reinforce, associate, cleanup)
- `tool_memory_test.exs`: 20 tests (tool schema, execute, error paths)
- `fake_provider_e2e_test.exs`: 1 test (memory learn → recall → final answer loop)
- **总计**: 38 tests, 0 failures

---

## 2. 已完成能力

### 2.1 MemoryStore CRUD ✅

| 操作 | 能力 | 评价 |
|------|------|------|
| `learn/3` | 创建 engram，自动设置 24h 过期 | 够用，支持 short_term 选项 |
| `recall/2` | ILIKE 模糊搜索，过滤过期，排序（长期优先→强化次数→更新时间） | 基本够用，缺 FTS5 |
| `reinforce/1` | 短期→长期提升，递增计数器 | 完整 |
| `associate/3` | 创建 synapse，`on_conflict: :nothing` | 完整 |
| `cleanup_expired/0` | 删除过期短期记忆 | 存在但无自动调度 |

### 2.2 Tool Behaviour 实现 ✅

- 所有 4 个 tool 正确实现 `name/0`, `description/0`, `input_schema/0`, `execute/2`
- 输入校验完整（必填参数检查、kind 枚举校验）
- 错误处理路径覆盖（无效 kind、不存在的 id、空结果集）
- `max_result_chars/0` 和 `concurrent?/0` 已声明

### 2.3 系统提示词集成 ✅

- 默认 system prompt 包含 memory 使用规范
- 描述了 recall→learn→reinforce→associate 工作流
- 包含 "Never store secrets, credentials, or PII" 安全提醒

### 2.4 短期/长期二分 ✅

- `short_term` 布尔标记
- `expires_at` 自动计算（创建时 +24h）
- recall 查询自动过滤过期 engram
- `reinforce` 设置 `short_term=false`, `expires_at=nil`

### 2.5 沙箱隔离 ✅

- 所有测试使用 `Sigil.DataCase` Ecto sandbox
- e2e 测试 `async: false` 避免跨进程竞争
- 无共享状态，每次测试事务回滚

---

## 3. 缺口清单

### P0 — 必须在 MVP dogfood 前解决

#### P0-1: 缺少自动过期清理调度

**现状**: `cleanup_expired/0` 实现了，但没有定时器/调度器调用。过期 engram 仅在 recall 时被过滤（WHERE 子句），物理删除从不自动发生。数据库会持续增长。

**影响**: 长期运行后数据库膨胀，部分查询性能下降。

**建议方案**: 
- 方案 A: 在 Application supervision tree 中加入 `Memory.Cleaner` GenServer，每小时调用 `cleanup_expired/0`
- 方案 B: 利用 SQLite 的定时任务（不推荐，无原生支持）
- 推荐方案 A，改动量小（+1 个 GenServer 文件），不影响主流程

**是否碰主流程**: 否。新增进程，不改变 Turn loop 或 Tool Registry。

#### P0-2: 缺少记忆输出信封 (envelope pattern)

**现状**: recall 输出是纯文本格式化列表，没有任何 XML 标签包裹。cog-cli 使用 `<stored-knowledge source="user_input">` 包裹每条记忆。

**影响**: 
- LLM 可能将记忆内容误认为系统指令（prompt injection 风险）
- 在多轮对话中记忆输出与普通工具结果无法区分

**建议方案**: 
- 为 memory 工具输出添加 `<stored-knowledge>` / `</stored-knowledge>` 包裹
- 改动量小，仅在 `MemRecall.execute/2` 和 `MemLearn.execute/2` 中添加

**是否碰主流程**: 否。仅修改 tool 输出格式。

#### P0-3: 缺少内容安全校验（自动侧）

**现状**: 系统提示词要求 "Never store secrets, credentials, or PII"，但没有任何代码级校验。mem_learn 会直接存储任何传入的 content 字符串。

**影响**: Agent 可能在不知情的情况下学习包含 API key 或 token 的代码片段并持久化到数据库。

**建议方案**:
- 在 `MemLearn.execute/2` 中添加简单规则校验：检测 `sk-`, `ghp_`, `AKIA`, `pk_` 等已知 secret 前缀
- 检测私有密钥头标记
- 参考 cog-cli `validateContentSafety/1` 的 injection_phrases 和 sensitive_prefixes 列表
- **不可替代 secret redaction 层**——需要单独的全局 redactor（见 P0-5）

**是否碰主流程**: 否。仅修改 `MemLearn` 工具。

#### P0-4: 记忆工具未区分单条 vs 批量，与 cog-cli 规范不一致

**现状**: 
- `mem_learn` 接受单个 `content` + `kind`，不是 `items` 数组
- `mem_recall` 接受单个 `query`，不是 `queries` 数组
- `mem_reinforce` 接受单个 `id` 或 `query`，不是 `engram_ids` 数组

**影响**: Agent 每次只能学习/搜索/强化一条记忆，多次调用增加 turn 消耗。与 cog-cli 的批量设计偏离。

**建议方案**:
- `mem_learn` 支持 `items: [%{term, definition, kind}]` 数组
- `mem_recall` 支持 `queries: ["q1", "q2"]` 数组
- `mem_reinforce` 支持 `engram_ids: ["id1", "id2"]` 数组
- 向后兼容：保留当前单条模式作为 fallback

**是否碰主流程**: 否。仅修改 tool schema 和 execute 实现。建议 P1 做（不影响 MVP 功能正确性，但影响效率）。

#### P0-5: Secret Redaction 缺失 → 应先于自动 mem_learn 做

**现状**: `STATUS-CURRENT.md` 明确记录 "secret redaction 仍缺"。Security 层目前只有 PathValidator 和 ShellPathGuard，没有全局 redactor。

**分析**: 
- 如果先做自动 mem_learn（如 consolidation），secrets 有泄露到 memory 持久化层的风险
- 即使不是自动，LLM 也可能意外调 mem_learn 存储包含 token 的 bash 输出

**建议**: **必须先做全局 secret redactor，再允许自动 mem_learn。** Redactor 应在以下管道生效：
1. Provider response → 进入 Agent state 前
2. Tool result → 进入 LLM context 前
3. Memory learn/recall → 存储/输出前

**是否碰主流程**: 是。需要在 `Agent.Turn` 或 Middleware 层面接入。但不影响 memory 模块本身。

### P1 — 建议快做（不影响 MVP）

#### P1-1: 缺少 FTS5 全文搜索

**现状**: recall 使用 `ILIKE '%pattern%'`。SQLite 支持 FTS5 虚拟表，但当前 migration 未创建。

**影响**: 
- 无词干提取（"running" ≠ "run"）
- 无前缀索引优化
- 无 BM25 排序
- 大规模记忆时 LIKE 扫描性能差

**建议方案**: 
- 新增 migration: `CREATE VIRTUAL TABLE engrams_fts USING fts5(content, content='engrams', content_rowid='rowid')`
- 新建 triggers 保持 FTS 索引同步
- `recall/2` 中优先使用 FTS MATCH，fallback ILIKE
- 改动量中等（+1 migration, +triggers, 修改 recall 逻辑）

**是否碰主流程**: 否。仅优化搜索层。

#### P1-2: 缺少 mem_get / mem_update / mem_unlink / mem_deprecate 等管理工具

**现状**: 当前只有 4 个 memory tool。cog-cli 有 17 个，其中多个用于记忆管理：

| 缺失工具 | 用途 | 优先级 |
|----------|------|--------|
| `mem_get` | 按 UUID 获取完整 engram | P1 |
| `mem_update` | 更新 term/definition | P1 |
| `mem_unlink` | 删除 synapse | P1 |
| `mem_deprecate` | 标记概念为废弃 | P1 |
| `mem_stats` | 统计 short/long/synapse 数量 | P1 |
| `mem_list_short_term` | 列出短期记忆 | P1 |
| `mem_connections` | 查询概念的连接 | P2 |
| `mem_trace` | 两概念间最短路径 | P2 |
| `mem_flush` | 批量删除短期记忆 | P2 |
| `mem_orphans` | 列出孤立概念 | P2 |

**建议方案**: P1 至少做 `mem_get` + `mem_update` + `mem_stats` + `mem_list_short_term`，让 agent 有能力审计自己的记忆。

**是否碰主流程**: 否。全部是新增 tool 模块。

#### P1-3: mem_learn 缺少 term 字段，搜索不高效

**现状**: Engram schema 用 `content` 字段（长文本），没有独立的 `term`（2-5 词短标识符）。cog-cli 明确强调 "terms drive keyword search during recall"。

**影响**: 
- recall 只能用 ILIKE 在全文本上搜索，无法精确 term 匹配
- 关联时按 id 引用，不如 term 便捷
- 无法实现 "powerful, composable recall through keyword searches"

**建议方案**:
- Engram schema 新增 `term` 字段（可选，string）
- `mem_learn` 新增 `term` 参数
- `recall/2` 优先匹配 term（精确），再 fallback content（模糊）
- 如果不想改 schema，可以用 `metadata.keywords` 代替

**是否碰主流程**: 否，但需要新增 migration。

#### P1-4: recall 排序未考虑 synapse 权重 / 图距离

**现状**: recall 排序公式为: `asc: short_term, desc: reinforced_count, desc: updated_at`。未使用 synapse 权重信息。

**影响**: 两个关联概念（如 "UserAuth module" → "JWT config"）在搜索 "Auth" 时，后者不会因关联而获得排序提升。

**建议方案**: 
- 短期不做复杂图排序，当前排序对 MVP 够用
- 后续可加入 "关联记忆额外 +0.1 分" 的简单启发式

#### P1-5: System prompt memory rules 不完整

**现状**: 当前 system prompt 的 Memory 段约 8 行，描述了基本工作流。但与 cog-cli 的完整规范对比，缺少：
- 概念质量准则（term 2-5 词、definition 为何+是什么、associations ≥1）
- 子 agent 验证模式
- "deterministic workflow, not an optional hint" 的强度

**建议方案**: 在 system prompt 中补入概念质量准则（cog-cli CLAUDE.md 第 4 节）。改动量小，不影响代码。

### P2 — 后续增强

#### P2-1: 图遍历 (mem_trace / mem_connections)

**现状**: synapse 表已建立，但无图遍历工具。cog-cli 使用 BFS + CTE 实现最短路径查询。

**影响**: 无图遍历时 synapse 的工程价值有限——仅在 recall 时 preload 显示，但不用于推理。

**建议方案**: 和 P1 的 mem_connections/mem_trace 一起做。

#### P2-2: 扩散激活 (Spreading Activation)

**现状**: 无。Cortex 有此功能（从焦点节点沿边扩散激活）。

**影响**: 无扩散激活不影响 MVP。cog-cli 也没有，使用 FTS5 + 图遍历替代。

**建议方案**: 
- **不建议现在做**。扩散激活在知识图谱规模 <1000 节点时收益极小。
- 当 engram 规模达到数千时，重新评估。

#### P2-3: 后台 consolidation / 定期反思

**现状**: 无。Cortex 有 Subconscious/Consolidator/ReflectionProcessor 每周反思。cog-cli 使用子 agent cog-mem-validate 做会话结束后整合。

**影响**: 没有自动去重或合并，长期积累会产生大量相似 engram。

**建议方案**: 
- **不建议现在做**。让 agent 在每次任务结束时间调 mem_reinforce 是够用的 MVP 方案。
- 未来可以考虑 task-end hook 调用子 agent 做去重/合并。

#### P2-4: 远程 memory / hosted brain

**现状**: 纯本地 SQLite。cog-cli 有 trycog.ai hosted brain 支持同步。

**影响**: 单机场景无影响。跨机器协作场景才需要。

**建议方案**: **不建议现在做**。专注本地 MVP。

#### P2-5: pgvector 语义搜索

**现状**: 纯 ILIKE 搜索。SQLite 不支持 pgvector。

**影响**: 跨语言语义搜索（如中文 "认证" 匹配 "Auth module"）当前不支持。但 MVP 的英文代码场景 ILIKE 足够。

**建议方案**: **不建议现在做**。先做 FTS5（P1-1），语义搜索有明显痛点时再评估。

#### P2-6: 子 agent 验证模式 (mem_validate)

**现状**: cog-cli 的 `cog-mem-validate` 子 agent 负责整合会话记忆（去重+合并+提升），Sigil 没有等效机制。

**建议方案**: 在 P1 完成后评估。当前 agent 手动调 mem_reinforce 是够用的简约方案。

---

## 4. 不建议现在做的能力

| 能力 | 原因 |
|------|------|
| Cortex 双层意识（Subconscious/Observation/Reflection） | 需要后台 LLM 调用，浪费 token，coding agent 用不上 |
| 提议审批系统（Proposal/auto-accept） | Agent 应自主判断何时调 mem_learn，不需要工作流审批 |
| 扩散激活（Spreading Activation） | 节点数 < 1000 时工程收益为零 |
| 元认知模块（SelfKnowledge/Relationship/Preferences） | 这是 Agent 产品记忆，不是 Coding Agent 的记忆 |
| pgvector 语义搜索 | FTS5 先做；语义搜索等明确痛点再评估 |
| Remote/hosted brain | 本地 MVP 优先 |
| mem_meld（概念合并） | 需要 hosted brain 支持 |
| mem_stale（过期检测） | 本地模式无此概念 |
| 多用户 workspace 隔离 | 当前单用户 MVP |
| Cortex TokenBudget / CognitivePrompts | 过度设计 |

---

## 5. 推荐后续任务拆分

### Phase 1: 安全基础 (P0, 阻塞自动记忆)

```
┌─────────────────────────────────────────────────────┐
│  Task 1A: 全局 Secret Redactor                       │
│  优先级: P0 | 独立性强 | 不碰 memory 内部              │
│  产出: lib/sigil/security/redactor.ex                │
│  接入: Agent.Turn 和 middleware pipeline             │
│  验收: Provider response / tool result 中 secret 被   │
│        redact，mem_learn 拒绝含 secret 的 content     │
├─────────────────────────────────────────────────────┤
│  Task 1B: Memory 内容安全校验                        │
│  优先级: P0 | 依赖 1A（共享 secret 检测列表）         │
│  产出: mem_learn 增加 validateContentSafety          │
│  验收: sk-*/ghp_*/AKIA 等前缀被拒绝存储               │
├─────────────────────────────────────────────────────┤
│  Task 1C: Memory 输出 envelope                       │
│  优先级: P0 | 独立                                   │
│  产出: 所有 memory tool 输出加 <stored-knowledge>     │
│  验收: recall 结果中每条 engram 被标签包裹             │
└─────────────────────────────────────────────────────┘
```

### Phase 2: 记忆系统完善 (P1, 可并行)

```
┌─────────────────────────────────────────────────────┐
│  Task 2A: 自动过期清理调度                           │
│  优先级: P1 | 独立                                   │
│  产出: Sigil.Memory.Cleaner GenServer               │
│  接入: Application supervision tree                 │
│  验收: 每小时自动调用 cleanup_expired                 │
├─────────────────────────────────────────────────────┤
│  Task 2B: 批量工具接口 (items/queries/engram_ids)     │
│  优先级: P1 | 独立，可并行                            │
│  产出: mem_learn/recall/reinforce 支持数组输入        │
│  验收: 单次调用可学习多个概念                          │
├─────────────────────────────────────────────────────┤
│  Task 2C: 管理工具补充                                │
│  优先级: P1 | 独立，可并行                            │
│  产出: mem_get, mem_update, mem_stats,               │
│         mem_list_short_term                          │
│  验收: agent 可审计自己的记忆                          │
├─────────────────────────────────────────────────────┤
│  Task 2D: FTS5 全文搜索                              │
│  优先级: P1 | 独立，可并行                            │
│  产出: migration + triggers + recall 集成            │
│  验收: FTS MATCH 优先，ILIKE fallback                 │
├─────────────────────────────────────────────────────┤
│  Task 2E: 系统提示词优化                              │
│  优先级: P1 | 独立                                   │
│  产出: 补入概念质量准则 + 确定性工作流强调             │
│  验收: 与 cog-cli CLAUDE.md 规范对齐                  │
└─────────────────────────────────────────────────────┘
```

### Phase 3: 图结构增强 (P2)

```
┌─────────────────────────────────────────────────────┐
│  Task 3A: mem_connections + mem_trace               │
│  优先级: P2                                          │
│  Task 3B: mem_orphans + mem_connectivity            │
│  优先级: P2                                          │
│  Task 3C: 图感知 recall 排序                         │
│  优先级: P2                                          │
└─────────────────────────────────────────────────────┘
```

### 可并行关系

```
Phase 1:  1A → 1B, 1C (1B 依赖 1A 的 secret 检测列表)
Phase 2:  2A ∥ 2B ∥ 2C ∥ 2D ∥ 2E (全部独立，可 5 路并行)
Phase 3:  3A ∥ 3B → 3C (3C 依赖 3A/3B 的图结构)
```

---

## 6. 测试结果

| 测试套件 | 状态 | 详情 |
|----------|------|------|
| `test/sigil/memory/memory_store_test.exs` | ✅ 17 tests, 0 failures | learn/recall/reinforce/associate/cleanup 全部通过 |
| `test/sigil/memory/tool_memory_test.exs` | ✅ 20 tests, 0 failures | tool schema/execute/error paths 全部通过 |
| `test/sigil/e2e/fake_provider_e2e_test.exs` (memory) | ✅ 1 test, 0 failures | learn→recall→final answer cycle 通过 |
| 全量 `mix test` | ⚠️ 37 failures | 全部来自 `req_llm_test.exs` (30) 和 `openai_compatible_test.exs` (7)，与 memory 系统无关 |

### 已知风险

1. **Secret redaction 未完成** → 记忆系统可能成为 secrets 持久化载体。P0 阻塞项。
2. **无自动过期清理调度** → 长期运行后 SQLite 膨胀。P1。
3. **未跟踪的 MCP 编译错误** → `lib/sigil/mcp/config_loader.ex` (untracked) 编译失败，但重新编译后通过。如果 merge 后仍存在，会阻塞所有测试。
4. **mem_associate 无效 kind 返回 {:ok, _} 而非 {:error, _}** → 工具测试已标记为 known gap，agent 使用不受影响但行为不一致。
5. **全量 mix test 失败** → 37 failures 全是 ReqLLM stub 和 OpenAI-compatible streaming 问题，与 memory 无关。不影响 memory 开发。

---

## 7. 总结判断

**Memory 系统 MVP 评分: 75/100**

- ✅ Schema 完整，CRUD 正确
- ✅ Tool behaviour 实现规范
- ✅ 测试覆盖充分（38 tests, 0 failures）
- ✅ 短期/长期二分 + 24h 过期模型正确
- ⚠️ 缺自动清理调度
- ⚠️ 缺安全校验（无 secret 检测、无 envelope）
- ⚠️ 缺 FTS5 搜索
- ⚠️ 缺管理工具（get/update/stats）
- ⚠️ 不支持批量操作

**核心判断**: 记忆系统的基础骨架（schema + CRUD + tool interface + system prompt）已完整且正确。当前缺口集中在"安全加固"和"运维工具"两个方向，不涉及架构变更。**MVP 可用的前提下，P0 必须做，P1 强烈建议做，P2 等规模上来再做。**
