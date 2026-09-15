# PRD: Skill Shortcut Invocation (`/skill:name`)

> 版本: 1.0  
> 状态: Draft  
> 目标迭代: Phase 7 (Skills 接入)  
> 关联: `STATUS-CURRENT.md` → "7. Skills 接入"

---

## 1. 问题陈述

当前 Sigil 的 Skills 系统**仅支持被动加载**：skills 的元数据（name / description）注入到 system prompt 中，由 LLM 在对话中自主决定是否 `read` SKILL.md 文件。

但实际使用中存在以下痛点：

1. **用户无法主动触发特定技能**：用户说"用 review 技能审查这个 PR"，LLM 可能会也可能不会主动读 SKILL.md。
2. **没有快捷语法**：pi agent 支持 `/skill:name args`，Claude Code 支持 `/skill:name`，但 Sigil 的 LiveView CLI 没有等效快捷方式。
3. **现有 Skills 快捷面板（`skills-panel`）体验不佳**：
   - 当前 `handle_event("launch_skill")` 只是往 input 框塞一段自然语言 prompt（`"Use the #{skill.name} skill: #{desc}"`），**没有真正展开 SKILL.md 内容**。
   - 面板本身占用可视区域较大（`border-t px-4 py-3 bg-surface` + flex wrap chip 列表），与三栏布局的紧凑设计不匹配。
   - 底部状态栏的 skills count（⚡ badge）保留了，但**面板本身应当移除**，避免重复展示和空间占用。
4. **Coordinator 入口不识别**：`Coordinator.add_message/3` 和 CLI 入口对 `/skill:` 前缀无特殊处理，直接当普通文本发往 LLM。

> **UI 决策**：移除占地方的 `skills-panel`（`show_skills_panel` toggle 及相关 state/handle_event），Skills 的交互入口退化为：
> - **快捷输入**：`/skill:name [args]` 直接展开 SKILL.md 完整内容
> - **LLM 自主引用**：system prompt 中保留 `<available_skills>` 元数据列表，LLM 可在对话中 `read` 对应的 SKILL.md

---

## 2. 目标

### 核心目标
在用户输入路径（LiveView / CLI）中支持 `/skill:<name> [args]` 快捷语法，在消息进入 LLM 之前将对应 SKILL.md 的**完整内容**展开并注入，使 LLM 立即获得该技能的完整指令。

### 设计原则
- **参考 pi agent 实现**：`_expandSkillCommand` 逻辑作为主要参考。
- **参考 Claude Code 约定**：`/skill:name` 也是其 slash command 命名空间的一部分。
- **参考 Sigil 现有模式**：`/model` 命令的 `parse_model_command` 模式作为输入解析参考。
- **不破坏现有流程**：现有的 `launch_skill` UI 行为、system prompt skill 注入、`skills: true/false` opts 全部保留。

---

## 3. 现状分析

### 3.1 Skills 系统现有模块

| 模块 | 职责 | 现状 |
|------|------|------|
| `Sigil.Skills.Loader` | 从文件系统发现 + 解析 skills | ✅ 完整 |
| `Sigil.Skills.Skill` | 元数据结构体 | ✅ 完整 |
| `Sigil.Skills.PromptFormatter` | 格式化 `<available_skills>` XML 块 | ✅ 完整 |
| `Sigil.Agent.Config` | `maybe_inject_skills/2` 注入 system prompt | ✅ 完整 |
| `SigilWeb.WorkspaceLive` | `load_available_skills/1` + `launch_skill` | ⚠️ `launch_skill` 只填 input |

### 3.2 消息入口

| 入口 | 路径 | 需修改 |
|------|------|--------|
| LiveView `send_message` | `WorkspaceLive.handle_event("send_message")` → `Coordinator.add_message/3` | ✅ |
| LiveView `steer_message` | `WorkspaceLive.handle_event("steer_message")` → `Coordinator.enqueue_candidate/3` | ✅ |
| Coordinator `add_message/3` | 统一入口 | ✅ 拦截层 |
| CLI / API | 通过 `Coordinator.add_message/3` 间接使用 | 通过 Coordinator 层自动覆盖 |

### 3.3 Pi Agent 参考实现

```js
// pi agent: dist/core/agent-session.js
_expandSkillCommand(text) {
    if (!text.startsWith("/skill:")) return text;
    const spaceIndex = text.indexOf(" ");
    const skillName = spaceIndex === -1 ? text.slice(7) : text.slice(7, spaceIndex);
    const args = spaceIndex === -1 ? "" : text.slice(spaceIndex + 1).trim();
    const skill = this.resourceLoader.getSkills().skills.find(s => s.name === skillName);
    if (!skill) return text; // 未知 skill，原样透传
    try {
        const content = readFileSync(skill.filePath, "utf-8");
        const body = stripFrontmatter(content).trim();
        const skillBlock = `<skill name="${skill.name}" location="${skill.filePath}">\nReferences are relative to ${skill.baseDir}.\n\n${body}\n</skill>`;
        return args ? `${skillBlock}\n\n${args}` : skillBlock;
    } catch (err) {
        this._extensionRunner.emitError(...);
        return text; // 出错原样透传
    }
}
```

**关键行为**：
1. 检测 `/skill:` 前缀
2. 提取 skill name（`/skill:` 后第一个空格前）和剩余 args
3. 从已加载的 skill map 查找
4. 读取 SKILL.md，剥离 frontmatter，用 `<skill>` XML 包裹 body
5. 拼接 args（如有）
6. 未知 skill 或读取失败时原样透传（不报错）

### 3.4 Claude Code 参考

Claude Code 的 `/skill:name` 也是 slash command 命名空间的一部分。当用户输入 `/skill:name` 时，Claude Code 会：
- 查找对应 skill 文件
- 将 skill 内容作为系统级指令注入到本次对话上下文中
- 类似于 pi agent 的展开模式

---

## 4. 功能需求

### FR-1: `/skill:name` 语法解析

**优先级**: P0

在消息进入 LLM 之前，解析用户输入是否符合 `/skill:<name> [args]` 模式。

- `/skill:review` → skill name = `review`, args = `""`
- `/skill:review fix all bugs` → skill name = `review`, args = `fix all bugs`
- `/skill:review-helper check PR #42` → skill name = `review-helper`, args = `check PR #42`
- `use the /skill:review skill` → **不匹配**（`/skill:` 不在行首，按普通文本处理）

### FR-2: Skill 内容展开

**优先级**: P0

当匹配到 `/skill:<name>` 时：

1. 从已加载的 skills 列表中查找 name 匹配的 skill
2. 读取 SKILL.md 文件内容
3. 剥离 YAML frontmatter（`---` 包裹的部分）
4. 用 `<skill>` XML 标签包裹 body，格式：

```
<skill name="review" location="/abs/path/to/SKILL.md">
References are relative to /abs/path/to/.

{SKILL.md body 内容}
</skill>
```

5. 如果有 args，拼接在 skill block 之后，用 `\n\n` 分隔
6. 用展开后的内容**替换**原始用户消息

### FR-3: 兜底行为

**优先级**: P0

- 找不到对应 skill → 原样透传消息（不报错，不阻断）
- 读取 SKILL.md 文件失败 → 原样透传，记录 warning log
- skill name 为空 → 不匹配，按普通文本处理

### FR-4: LiveView 集成

**优先级**: P0

在 `WorkspaceLive` 的消息发送路径中拦截并展开：

```elixir
# send_message 路径
content = build_message_content_blocks(message, attachments)
content = Sigil.Skills.Expander.expand(content, skills)
```

同样在 `steer_message` 路径中处理。

### FR-5: LiveView `launch_skill` 优化（可选）

**优先级**: P1

当前 `handle_event("launch_skill")` 只在 input 填入自然语言 prompt。增强为填入完整展开内容：

```elixir
expanded = Sigil.Skills.Expander.expand("/skill:#{skill_name}", [skill])
socket = assign(socket, :input_value, expanded)
```

### FR-6: Coordinator 层兜底

**优先级**: P1

在 `Coordinator.add_message/3` 中也做一次展开，确保非 LiveView 入口（CLI、webhook、MCP）也能受益。

---

## 5. 非功能需求

### NFR-1: 性能

- Skill 内容读取**不走 LLM**，本地文件 IO，SKILL.md 通常 < 10KB，IO 开销可忽略。
- Skill 列表已在启动时加载，查找操作为 O(n)（skills 数量通常 < 20），无需额外缓存。
- 展开操作在用户发送消息的同步路径中，延迟 < 5ms。

### NFR-2: 安全性

- 展开的 SKILL.md body 作为**用户消息**发送给 LLM，不走 system prompt，因此不受 system prompt token 预算限制。
- SKILL.md 内容从本地文件系统读取，不走网络。
- 已有的 PathValidator / Redactor 中间件对展开后的内容同样生效。

### NFR-3: 向后兼容

- `/skill:` 前缀不在行首时，按普通文本处理。
- 不修改现有 `skills: true/false` opts、system prompt 注入、`launch_skill` UI 行为。
- 未知 skill 透传，不报错，不阻断用户发送消息。

### NFR-4: 可观测性

- 展开成功：debug log `[Skills] expanded /skill:<name> → {byte_size} bytes`
- 未知 skill：debug log `[Skills] unknown skill "<name>", passing through`
- 读取失败：warning log `[Skills] failed to read SKILL.md for "<name>": {reason}`

---

## 6. 设计方案

### 6.1 新增模块：`Sigil.Skills.Expander`

```
lib/sigil/skills/expander.ex
```

```elixir
defmodule Sigil.Skills.Expander do
  @moduledoc """
  Expands /skill:name shortcut syntax into full SKILL.md content.

  Parses user input for `/skill:<name> [args]` patterns, reads the
  corresponding SKILL.md from disk, strips frontmatter, and wraps the
  body in a <skill> XML block. Unknown skills and read errors pass
  through unchanged (no errors thrown).
  """

  @skill_prefix "/skill:"

  @doc """
  Expand skill shortcuts in a text string.

  Returns the expanded text, or the original text if no skill shortcut
  was found or the skill could not be loaded.
  """
  @spec expand(String.t(), [Sigil.Skills.Skill.t()]) :: String.t()
  def expand(text, skills) when is_binary(text) and is_list(skills) do
    case parse_skill_command(text) do
      {:match, skill_name, args} ->
        expand_skill(skill_name, args, text, skills)

      :no_match ->
        text
    end
  end

  # ... implementation details
end
```

### 6.2 修改点清单

| 文件 | 修改 | 类型 |
|------|------|------|
| `lib/sigil/skills/expander.ex` | 新增 Expander 模块 | 新增 |
| `lib/sigil_web/live/workspace_live.html.heex` | **移除** `skills-panel` 面板 HTML；保留底部 ⚡ badge | 删除 |
| `lib/sigil_web/live/workspace_live.ex` | `send_message` / `steer_message` 中调用 expand；**移除** `show_skills_panel`/`toggle_skills_panel`/`launch_skill`/`load_available_skills` 相关 state 和 handler | 修改 |
| `lib/sigil/agent/coordinator.ex` | `add_message/3` 中调用 expand（兜底） | 修改 |
| `test/sigil/skills/expander_test.exs` | Expander 单元测试 | 新增 |
| `test/sigil/agent/skills_shortcut_test.exs` | 集成测试（LiveView + Coordinator 路径） | 新增 |

### 6.3 数据流

```
用户输入 "/skill:review fix all bugs"
  │
  ▼
WorkspaceLive.send_message  OR  Coordinator.add_message
  │
  ▼
Skills.Expander.expand(text, loaded_skills)
  │
  ├─ 解析: skill_name = "review", args = "fix all bugs"
  ├─ 查找: skills 列表中找到 name = "review" 的 Skill
  ├─ 读取: /path/to/review/SKILL.md
  ├─ 剥离: frontmatter
  ├─ 包裹: <skill name="review" location="...">\n...body...\n</skill>
  └─ 拼接: + "\n\nfix all bugs"
  │
  ▼
展开后的消息 → LLM
```

---

## 7. 测试策略

### 7.1 单元测试（`expander_test.exs`）

| 测试 | 预期 |
|------|------|
| `/skill:review` → 展开对应 skill body | body 包含在 `<skill>` 标签内 |
| `/skill:review some args` → skill + args 拼接 | args 出现在 skill block 之后 |
| 普通文本 → 原样返回 | 不变 |
| `/skill:` 不在行首 → 原样返回 | 不变 |
| 未知 skill → 原样返回 | 不变，无报错 |
| SKILL.md 读取失败 → 原样返回 | 不变，warning log |
| 空 skill name → 不匹配 | 原样返回 |

### 7.2 集成测试（`skills_shortcut_test.exs`）

| 测试 | 覆盖路径 |
|------|---------|
| Coordinator.add_message + /skill: 展开 | Coordinator 兜底层 |
| LiveView send_message + /skill: 展开 | LiveView 发送路径 |
| LiveView steer_message + /skill: 展开 | steer 路径 |

---

## 8. 实施阶段

### Phase 1: Core Expander（P0）

1. 新增 `Sigil.Skills.Expander` 模块
2. 单元测试全绿
3. 不修改任何现有文件

### Phase 2: LiveView 集成 + 面板清理（P0）

4. `WorkspaceLive.send_message` / `steer_message` 中调用 expand
5. **移除** `skills-panel` 面板 HTML（`workspace_live.html.heex`）
6. **移除** `show_skills_panel`、`toggle_skills_panel`、`launch_skill`、`load_available_skills` 相关 state/handler（`workspace_live.ex`）
7. 保留底部 ⚡ badge（skills count）
8. LiveView 集成测试

### Phase 3: Coordinator 兜底（P1）

9. `Coordinator.add_message/3` 调用 expand
10. CLI / Webhook 路径验证

### Phase 4: 回归验收

11. `mix test --exclude slow --exclude e2e` 全绿
12. 手动验证 LiveView 快捷发送

---

## 9. 与 Pi Agent 的差异对照

| 维度 | Pi Agent | Sigil（本 PRD 实现） |
|------|---------|---------------------|
| 语法 | `/skill:name [args]` | 相同 |
| 展开位置 | `AgentSession`（LLM 调用前） | `Expander`（消息发送前） |
| 查找方式 | `resourceLoader.getSkills()` map | `Loader.load/1` 列表 + Enum.find |
| 读取方式 | `readFileSync(skill.filePath)` | `File.read!/1` |
| Frontmatter 剥离 | `stripFrontmatter(content)` | 自行实现（`---\n` 分割） |
| XML 包裹格式 | `<skill name="..." location="...">\nReferences are relative to ...\n\n{body}\n</skill>` | 相同 |
| Args 处理 | `args ? skillBlock + "\n\n" + args : skillBlock` | 相同 |
| 兜底行为 | 原样透传 | 相同 |
| 错误处理 | `emitError` + 透传 | warning log + 透传 |

---

## 10. 参考

- Pi Agent: `dist/core/agent-session.js` → `_expandSkillCommand()`
- Pi Agent: `dist/core/skills.js` → `loadSkills()` / `formatSkillsForPrompt()`
- Agent Skills Spec: https://agentskills.io/specification
- Claude Code: `/skill:name` slash command
- Sigil 现有代码：`lib/sigil/skills/` 全套 + `lib/sigil/agent/coordinator.ex` + `lib/sigil_web/live/workspace_live.ex`
