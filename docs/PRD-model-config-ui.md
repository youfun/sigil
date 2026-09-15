# PRD: UI 内模型 / Provider 配置管理

> 版本: v1.0 | 日期: 2026-05-23 | 状态: Draft

---

## 一、背景与动机

### 当前状态

Sigil 的模型/Provider 配置**完全依赖手动编辑 JSON 文件**，没有 UI 管理能力：

1. **全局配置** `~/.sigil/models.json` — 定义所有可用的 Provider 和 Model，需要用户手动创建和编辑
2. **工作区策略** `<workspace>/.sigil/settings.jsonc` — 限制该工作区可用的模型，同样手动编辑
3. **API Key** — 只能写在 JSON 里或设为环境变量（`env:VAR_NAME`），无法在 UI 中输入/更新

用户必须：
- 知道 `~/.sigil/models.json` 的文件格式
- 手写 JSON（含嵌套结构），容易写错
- 在终端里编辑或通过 `write` 工具操作
- 出错了只能在日志里看到 warning，UI 只显示 "Configure models before sending"

### 目标

将模型/Provider 配置管理**完全搬到 UI 内**，让用户无需碰 JSON 文件即可：
- 添加/删除/编辑 Provider
- 为 Provider 添加/删除 Model
- 管理 API Key
- 管理工作区级别的模型访问策略
- 即时校验、即时生效

---

## 二、涉及文件（现状 + 改动范围）

### 2.1 核心读取路径（现状，基本只读不改）

| 文件 | 当前职责 | 改动类型 |
|------|---------|---------|
| `lib/sigil/agent/model_config.ex` | 读 `models.json`，解析为 provider config map，提供 `available_models` / `resolve_model_for_workspace` 等查询 | **新增写路径**：`write_config/1`、`add_provider/2`、`remove_provider/2`、`add_model/3` 等 |
| `lib/sigil/agent/config.ex` | 从 opts 构建 `%Agent.Config{}`，resolve provider module | 不改（只消费配置，不存储） |
| `lib/sigil/agent/provider.ex` | Provider behaviour | 不改 |
| `lib/sigil/agent/reasoning.ex` | 推理等级 helpers | 不改 |
| `lib/sigil/workspace_settings.ex` | 读 `.sigil/settings.jsonc`，提供 `models_policy` 等 | **新增写路径**：`write_policy/2`、`update_allowlist/2` |
| `lib/sigil/extension/provider_spec.ex` | 扩展声明的 Provider 元数据（不和 ModelConfig 连通） | 不改 |

### 2.2 UI 层（改动重点）

| 文件 | 当前职责 | 改动类型 |
|------|---------|---------|
| `lib/sigil_web/live/workspace_live.ex` | 主 LiveView，mount 时加载 `available_models`，发送时 resolve model | **新增事件处理**：打开/关闭配置面板；**不改 mount 逻辑** |
| `lib/sigil_web/live/workspace_live.html.heex` | 主模板，包含模型选择器 `<select>` | **新增入口**：设置按钮/齿轮图标；不改现有 selector |

### 2.3 新增文件

| 文件 | 职责 |
|------|------|
| `lib/sigil_web/live/model_settings_live.ex` | **模型配置面板 LiveView**（独立 LiveView 或组件） |
| `lib/sigil_web/live/model_settings_live.html.heex` | 配置面板模板 |
| `lib/sigil_web/live/workspace_policy_live.ex` | **工作区策略面板 LiveView**（可选，可合并到上述面板） |
| `lib/sigil_web/live/workspace_policy_live.html.heex` | 工作区策略模板（可选） |

### 2.4 路由

| 文件 | 改动 |
|------|------|
| `lib/sigil_web/router.ex` | 新增路由（如 `/settings/models`） |

---

## 三、配置写入路径设计

### 3.1 `ModelConfig` 新增写方法

```elixir
# 新增模块方法：

@spec write_config(map()) :: :ok | {:error, term()}
def write_config(config_map)

@spec add_provider(String.t(), map()) :: :ok | {:error, term()}
def add_provider(provider_id, provider_config)

@spec remove_provider(String.t()) :: :ok | {:error, term()}
def remove_provider(provider_id)

@spec add_model(String.t(), String.t(), map()) :: :ok | {:error, term()}
def add_model(provider_id, model_id, model_meta)

@spec remove_model(String.t(), String.t()) :: :ok | {:error, term()}
def remove_model(provider_id, model_id)

@spec update_api_key(String.t(), String.t()) :: :ok | {:error, term()}
def update_api_key(provider_id, api_key)
```

**实现要点**：
- 写入前做**完整校验**（provider 名合法、model id 唯一、base_url 格式等）
- 使用**原子文件写入**（先写临时文件，再 rename），避免并发写入损坏
- 写入后 **broadcast** 变更事件（`Phoenix.PubSub`），让 WorkspaceLive 自动 `refresh_models`
- 同时写 `~/.sigil/models.json` 单一文件

### 3.2 `WorkspaceSettings` 新增写方法

```elixir
@spec write_policy(Path.t(), map()) :: :ok | {:error, term()}
def write_policy(workspace_root, policy_map)
```

**实现要点**：
- 保持 JSONC 注释（需要 parse + 原地修改 `models` 块，不能直接覆盖整个文件）
- 或者简化为：读取 → 修改 models 块 → 重新格式化写入

### 3.3 发布/订阅

```elixir
# ModelConfig 变更广播
Phoenix.PubSub.broadcast(Sigil.PubSub, "models:updated", :models_updated)
```

`WorkspaceLive` 已订阅 `"conversation:#{conv_id}"` 和 `"session:#{conv_id}"`，新增订阅 `"models:updated"` 即可自动刷新。

---

## 四、UI 设计

### 4.1 入口

在主界面顶部/右侧（现有模型选择器旁）添加一个**齿轮图标按钮** `⚙`，点击打开模型配置面板。

位置参考（`workspace_live.html.heex` 中现有模型选择器区域）：

```html
<div :if={@available_models != []} class="right">
  <!-- 新增：设置入口 -->
  <button phx-click="open_model_settings" class="btn icon" title="模型设置">⚙</button>
  <!-- 现有模型选择器 -->
  <select id="model-picker" ...>...</select>
  <!-- 其余不变 -->
</div>
```

### 4.2 配置面板（Modal / 右面板）

#### 布局：侧面板（Slide-over panel）从右侧滑入

**Tab 结构**：
- **Providers** — 管理所有 Provider 和其下的 Model
- **Workspace Policy** — 管理当前工作区的模型访问策略（可选，可后续迭代）

#### 4.2.1 Providers Tab

```
┌────────────────────────────────────┐
│ 模型配置                      [✕] │
├────────────────────────────────────┤
│ [+ 添加 Provider]                 │
├────────────────────────────────────┤
│ ▼ stepfun                         │
│   Base URL: https://api.stepfun.. │
│   API: stepfun-step-plan          │
│   API Key: env:OPENAI_API_KEY     │
│   Models:                         │
│   ┌────────────────────────────┐  │
│   │ step-router-v1            │  │
│   │ Step Router v1  [编辑][删]│  │
│   ├────────────────────────────┤  │
│   │ [+] 添加模型              │  │
│   └────────────────────────────┘  │
│   [编辑 Provider] [删除 Provider] │
├────────────────────────────────────┤
│ ▼ deepseek                        │
│   ...                             │
└────────────────────────────────────┘
```

**Provider 字段**：
- `id` (string, 必填) — Provider 唯一标识（如 `stepfun`, `deepseek`）
- `name` (string, 可选) — 显示名
- `baseUrl` (string, 可选) — API 基础 URL
- `api` (dropdown, 必填) — 可选值：`openai-chat-completions` / `openai-responses` / `anthropic-messages` / `stepfun-step-plan` / `openai`
- `apiKey` (string/password, 可选) — API Key，支持 `env:VAR` 或直接输入
- `provider` (hidden/auto) — 与 `id` 相同或从 `api` 推导

**Model 字段**：
- `id` (string, 必填) — Model ID（如 `step-router-v1`）
- `name` (string, 必填) — 显示名（如 "Step Router v1"）
- `input` (multi-select) — 支持的输入类型：`text`, `image`
- `reasoning` (checkbox) — 是否支持推理
- `defaultReasoning` (dropdown, 如果 reasoning=true) — 默认推理等级
- `thinkingLevelMap` (map, 如果 reasoning=true) — 推理等级映射
- `contextWindow` (number) — 上下文窗口大小（token）
- `maxTokens` (number) — 最大输出 token

#### 4.2.2 Workspace Policy Tab（可后续迭代）

```
┌────────────────────────────────────┐
│ 工作区模型策略                [✕] │
├────────────────────────────────────┤
│ 当前工作区: /path/to/workspace    │
│                                    │
│ ○ 无限制（所有全局模型可用）      │
│ ● 仅允许选定的 Provider/模型      │
│                                    │
│ ┌────────────────────────────┐     │
│ │ ☑ stepfun                 │     │
│ │   ☑ step-router-v1        │     │
│ │   ☐ step-other            │     │
│ │ ☐ deepseek                │     │
│ │   ☐ deepseek-chat         │     │
│ └────────────────────────────┘     │
│                                    │
│ 默认模型: [dropdown]              │
│                                    │
│ [保存] [取消]                      │
└────────────────────────────────────┘
```

### 4.3 交互流程

```
用户点击 ⚙ → 打开右侧配置面板
  → 读取当前 ~/.sigil/models.json 数据
  → 渲染 Provider 列表 + Model 列表
  → 用户编辑 → 即时前端校验
  → 点击"保存" → LiveView event → ModelConfig.write_config/1
  → 写入成功 → broadcast "models:updated"
  → WorkspaceLive 收到 broadcast → reload_workspace_models
  → 关闭面板 / 显示成功提示
```

### 4.4 状态管理

**WorkspaceLive assigns 新增/修改**：

```elixir
# 新增
assign(socket, :show_model_settings, false)   # 是否显示配置面板

# 不修改现有 assigns：
# - :selected_model — 当前选中的模型
# - :available_models — 可用模型列表（通过 broadcast 自动刷新）
# - :available_reasoning_levels — 可用推理等级（模型切换时更新）
```

**ModelSettingsLive assigns**（新组件）：

```elixir
assign(socket,
  providers: [],          # 从 models.json 解析的 provider 列表
  editing_provider: nil,  # 正在编辑的 provider id
  editing_model: nil,     # 正在编辑的 model (provider_id/model_id)
  form_errors: %{},       # 校验错误
  dirty: false            # 是否未保存
)
```

---

## 五、校验规则

### 5.1 Provider 校验

| 字段 | 规则 |
|------|------|
| `id` | 必填，`/^[a-z0-9_-]+$/`，唯一 |
| `baseUrl` | 可选，如填写必须是合法 URL（`https?://`） |
| `api` | 必选，必须是已知 api 类型之一 |
| `apiKey` | 可选，支持 `env:VAR_NAME` 格式或纯文本 |
| `models` | 至少一个 model |

### 5.2 Model 校验

| 字段 | 规则 |
|------|------|
| `id` | 必填，同一 provider 下唯一 |
| `name` | 必填，非空 |
| `input` | 至少选择一个（`text` 默认选中） |
| `contextWindow` | 可选，正整数 |
| `maxTokens` | 可选，正整数，≤ contextWindow |

### 5.3 工作区策略校验

| 字段 | 规则 |
|------|------|
| `allow.providers` | 如有限制，至少允许一个 provider |
| `default.provider` | 必须在 allowlist 中 |
| `default.model` | 必须在 allowlist 对应 provider 的 models 中 |

---

## 六、安全考虑

### 6.1 API Key 处理

- **不在 UI 中显示已保存的 API Key**（用 `••••••••` 脱敏）
- 支持 `env:VAR_NAME` 方式引用环境变量（推荐）
- 如用户直接在输入框中输入明文 Key：
  - 存储时**不额外加密**（保持与当前行为一致，key 存于 `~/.sigil/models.json`）
  - 在 JSON 文件中明文存储（当前已如此）
  - 如需加密，后续迭代可引入 `:crypto` 或 OS keychain

### 6.2 文件权限

- 写入 `~/.sigil/models.json` 时设置 `0o600` 权限
- 已存在的文件保持原权限

### 6.3 并发写入

- 使用原子写入（temp file + rename）避免并发问题
- 写入前重新读取最新文件内容做 merge，避免覆盖他人的并发修改

---

## 七、兼容性与降级

### 7.1 向后兼容

- `models.json` 格式不变，现有配置文件无需迁移
- 新增的 UI 写入逻辑与现有 CLI/手动编辑完全兼容
- 环境变量覆盖（`OPENAI_MODEL`, `OPENAI_BASE_URL` 等）继续生效且优先级不变

### 7.2 降级策略

- 如果 `models.json` 不存在且用户打开配置面板：显示引导，提示用户创建第一个 Provider
- 如果 `models.json` 解析失败（JSON 格式错误）：面板显示错误信息 + 原始内容编辑模式
- 如果写入失败（磁盘满/权限问题）：面板显示错误，不静默丢弃

### 7.3 无配置文件时

- 首次使用 Sigil 时 `~/.sigil/models.json` 不存在
- `ModelConfig.provider_config/1` 使用**内置默认值**（StepFun Step Plan v1）
- 此时 `available_models == []`（因为没有全局配置），UI 显示 "Configure models before sending"
- 用户点击 ⚙ → 面板引导创建第一个 Provider → 写入 `models.json` → 刷新后模型选择器正常工作

---

## 八、实施优先级建议

### Phase 1（核心 — 必须有）

- [ ] `ModelConfig` 写路径：`write_config/1`、`add_provider/2`、`add_model/3`、`remove_provider/1`、`remove_model/2`
- [ ] 配置面板 LiveView（Provider + Model CRUD）
- [ ] 入口按钮 + 面板 UI 模板
- [ ] PubSub broadcast → WorkspaceLive 自动刷新

### Phase 2（完善）

- [ ] Provider 字段完整编辑（baseUrl、api、apiKey）
- [ ] Model 字段完整编辑（reasoning、contextWindow 等）
- [ ] 前端校验 + 服务端校验
- [ ] API Key 脱敏显示
- [ ] JSON 原始编辑模式（高级用户直接编辑 JSON）

### Phase 3（工作区策略）

- [ ] `WorkspaceSettings` 写路径
- [ ] 工作区策略管理面板
- [ ] 默认模型选择（工作区级别）

### Phase 4（体验优化）

- [ ] Provider 导入（从环境变量或 URL 一键导入，如 OpenRouter、DeepSeek 等常用 provider 模板）
- [ ] 连接测试（"Test Connection" 按钮，发送最小请求验证 API Key / Base URL 可用）
- [ ] 模型自动发现（部分 API 支持 `/v1/models` 端点）

---

## 九、测试策略

### 单元测试

- `ModelConfig` 写方法：读写一致性、校验、原子写入
- `WorkspaceSettings` 写方法：JSONC 注释保持、原地修改

### 集成测试

- LiveView 测试：打开/关闭面板、添加/删除 Provider/Model、保存后刷新
- PubSub：broadcast 触发 WorkspaceLive 刷新

### 手动测试场景

1. 首次使用 Sigil → 无 `models.json` → 打开面板创建第一个 Provider
2. 添加多个 Provider → 模型选择器正确分组
3. 修改已保存的 Provider → 刷新后生效
4. 删除 Provider → 模型选择器中对应 optgroup 消失
5. 工作区策略限制 → 只有被允许的模型显示
6. JSON 手动编辑后 → 面板正常加载（不覆盖手动修改的格式）

---

## 十、关键文件清单

```
# 读取路径（不改 or 微改）
lib/sigil/agent/model_config.ex        — 新增写方法
lib/sigil/agent/config.ex             — 不改
lib/sigil/agent/reasoning.ex          — 不改
lib/sigil/workspace_settings.ex       — 新增写方法

# UI 层
lib/sigil_web/live/workspace_live.ex          — 新增事件处理
lib/sigil_web/live/workspace_live.html.heex   — 新增入口按钮
lib/sigil_web/live/model_settings_live.ex     — 🆕 配置面板
lib/sigil_web/live/model_settings_live.html.heex — 🆕
lib/sigil_web/router.ex                       — 新增路由

# 配置文件（用户数据，不改代码）
~/.sigil/models.json                  — 全局模型配置（UI 管理）
.sigil/settings.jsonc                 — 工作区策略（UI 管理）
```