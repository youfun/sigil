# PRD: 设置 / 可用模型 页面

## 元信息

| 字段 | 值 |
|------|-----|
| 状态 | ready |
| 优先级 | P1 |
| 目标分支 | `mobile-webui-compat` |
| 依赖 | `Sigil.Agent.ModelConfig`（CRUD 已完成）、`theme-system.css`（主题变量已完成） |

## 背景

Sigil 当前的模型选择（composer 底部的下拉框）仅允许从已配置的 provider/model 中选一个，但没有集中管理"系统有哪些模型可被选择"的界面。用户需要：

- 知道系统里配置了哪些 provider/model
- 增删改 provider（API 地址、密钥、类型）
- 增删改每个 provider 下的 model
- 设置全局默认 provider

当前 **不可用** 原因：
- `models.json` 手动编辑门槛高
- 没有 UI 可操作
- 工作台的 model picker 只是"选"，不是"管"

## 目标

实现 `设置 / 可用模型` 页面：

1. 全局能力配置，不是某次对话的运行参数
2. 管理 `~/.sigil/models.json`
3. 不影响当前 composer 的 model picker 功能
4. 分开"可用模型（全局 catalog）"和"当前模型（本次运行选哪个）"

## 信息架构

```
设置
├─ 通用
├─ 可用模型   ← 本次实现
├─ 工作区
├─ 工具权限
├─ MCP / 扩展
└─ 日志 / 调试
```

| 页面 | 职责 |
|------|------|
| **设置 / 可用模型** | 管全局 `models.json`（provider + model catalog） |
| 设置 / 工作区 / 模型策略（未来） | 管当前 workspace 的 models allow policy |
| 工作台 / 当前模型（已有） | 管这次 run 选哪个 model |

## 页面布局

三栏：

```
┌── 顶部栏：← 返回工作台  /  设置 / 可用模型 ─────────────┐
├────────────┬──────────────────┬──────────────────────────┤
│ 设置       │ 供应商            │ 供应商详情                 │
│ (180px)    │ (260px)          │ (flex-1)                 │
│            │                  │                          │
│ ⚙️ 通用    │ [+ 添加供应商]    │ Provider ID  stepfun      │
│ 🧠 可用◀   │                  │ 名称         Stepfun      │
│ 📁 工作区   │ StepFun    默认   │ API 类型     stepfun-... │
│ 🔒 工具    │                  │ Base URL     https://...   │
│ 🔌 MCP    │ OpenAI            │ API Key      env:OP...    │
│ 📋 日志    │                  │ 默认供应商   [✓]          │
│            │ Local Ollama      │                          │
│            │                  │ [编辑] [删除供应商]        │
│            │                  ├──────────────────────────┤
│            │                  │ 模型    [+ 添加模型]       │
│            │                  │ ID│名称│类型│ctx│ ✕      │
│            │                  │ step-router-v1 256K      │
└────────────┴──────────────────┴──────────────────────────┘
```

## 功能需求

### 供应商管理

| 功能 | 触发 | 行为 |
|------|------|------|
| 列表展示 | 页面加载 | 从 `models.json` 读取，显示 name + id + 默认标签 |
| 选择供应商 | 点击列表项 | 右侧刷新详情 |
| 添加供应商 | 点击 [+ 添加供应商] | 弹出表单（名称/ID/API类型/Base URL/API Key + 初始模型） |
| 编辑供应商 | 详情区 [编辑] | 弹出表单（名称/API类型/Base URL/API Key），ID 不可改 |
| 删除供应商 | 详情区 [删除] | 二次确认，禁止删到0个（至少保留1个） |
| 设置默认 | 详情区 toggle | 选中即设为全局 defaultProvider，不可取消（始终有默认） |

### 模型管理

| 功能 | 触发 | 行为 |
|------|------|------|
| 模型表格 | 选中供应商 | 显示该 provider 下所有 model（ID/名称/类型/上下文） |
| 添加模型 | [+ 添加模型] | 弹出表单（ID/名称/类型/上下文窗口/最大输出） |
| 删除模型 | 行末 ✕（hover 可见） | 二次确认 |

### 实时同步

- 订阅 `"models:updated"` PubSub
- `ModelConfig.write_config` 写文件后自动广播
- 页面收到广播后重新从 `models.json` 加载

## 路由

```
GET  /settings/available-models  →  SigilWeb.AvailableModelsLive
```

添加到现有 scope，与已有路由共存：
```
live "/", WorkspaceLive, :index
live "/w/:workspace_id/c/:conversation_id", WorkspaceLive, :index
live "/settings/available-models", AvailableModelsLive, :index   ← 新增
```

## 数据流

```
~/.sigil/models.json
  ↓ load_raw_config()
AvailableModelsLive (assigns: config, providers, selected_provider_id, selected_provider)
  ↓ render
available_models_live.html.heex

用户操作 → handle_event → ModelConfig.add_provider / remove_provider / update_provider / ...
  ↓ write_config (atomic write + PubSub broadcast)
handle_info({:models_updated}) → 重新 load_raw_config() → 刷新 assigns → 刷新 UI
```

## CSS 约定

- 所有新样式加 `settings-` 前缀（`.settings-nav`、`.settings-dialog`、`.settings-model-table` 等）
- 颜色使用项目语义变量：`var(--text)`、`var(--muted)`、`var(--border)`、`var(--accent)`、`var(--danger)`、`var(--panel)`、`var(--bg)`
- 所有变量均有 `--sig-*` → legacy compat 双重映射，跟随主题切换
- 不引入硬编码色值（除 `rgba(0,0,0,0.4)` 遮罩）
- 追加到 `workspace.css` 末尾，新开 section `Settings / Available Models Page`

## 编辑

### 新建

| 文件 | 说明 |
|------|------|
| `lib/sigil_web/live/available_models_live.ex` | LiveView：加载/渲染/事件处理/CRUD |
| `lib/sigil_web/live/available_models_live.html.heex` | 模板：三栏布局 + 弹窗表单 |

### 修改

| 文件 | 变更 |
|------|------|
| `lib/sigil_web/router.ex` | 新增 1 行路由，不动 locale 中间件和已有路由 |
| `priv/static/assets/css/workspace.css` | 末尾追加 ~300 行 settings CSS |

## 不涉及

- 不修改 `theme-system.css` / `theme-light.css`
- 不修改 composer / model picker
- 不修改 `Sigil.Agent.ModelConfig`（CRUD API 已就绪）
- 不修改 workspace_live.ex
- 左侧菜单"通用/工作区/工具权限/MCP/日志"仅为占位，无功能

## 验收标准

- [ ] 访问 `/settings/available-models` 渲染三个供应商（StepFun/OpenAI/Local Ollama），其中一个带默认标签
- [ ] 点击供应商，右侧展示详情（ID/名称/API类型/Base URL/脱敏 API Key/默认开关）
- [ ] 右侧模型表格展示该供应商的所有模型（含上下文窗口格式化）
- [ ] 点击 [+ 添加供应商]，弹出表单，填写后成功写入 `models.json`
- [ ] 点击 [编辑]，弹出表单，修改后保存生效
- [ ] 默认供应商 toggle 可切换（不能取消所有默认）
- [ ] 删除供应商需二次确认，不能删到 0 个
- [ ] 添加/删除模型后表格即时刷新
- [ ] 在另一个终端修改 `models.json` → 页面 PubSub 自动刷新
- [ ] 顶部"← 返回工作台"可跳回 `/`
- [ ] dark mode 下颜色随 `data-theme` 正确切换