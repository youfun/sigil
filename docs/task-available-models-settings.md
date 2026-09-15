# 任务：实现「设置 / 可用模型」页面

## 要求

在 `mobile-webui-compat` 分支上实现设置面板中的"可用模型"页面，三栏布局管理 `~/.sigil/models.json` 的 provider 和 model。

## 具体步骤

### 1. 新建 `lib/sigil_web/live/available_models_live.ex`

LiveView 模块 `SigilWeb.AvailableModelsLive`：

- `mount/3`：调用 `ModelConfig.ensure_config()` 确保配置文件存在，从 `ModelConfig.config_file_path()` 读取 `models.json` 并解析为 `assigns`（config, providers, selected_provider_id, selected_provider）
- 订阅 `Phoenix.PubSub.subscribe(Sigil.PubSub, "models:updated")`
- `handle_info({:models_updated})`：重新加载 providers 并刷新 assigns
- 事件处理：`select_provider`、`toggle_default_provider`、`open_add_provider`/`close_add_provider`、`submit_add_provider`（调用 `ModelConfig.add_provider/2`）、`open_edit_provider`/`close_edit_provider`、`submit_edit_provider`（调用 `ModelConfig.update_provider/2`）、`confirm_delete_provider`/`execute_delete`（调用 `ModelConfig.remove_provider/1`）、`open_add_model`/`close_add_model`、`submit_add_model`（调用 `ModelConfig.add_model/3`）、`confirm_delete_model`/`execute_delete`（调用 `ModelConfig.remove_model/2`）
- 弹窗表单全部使用 `<form phx-change>`（非 `phx-keyup`）捕获输入
- API Key 脱敏显示（`obscured_api_key/1`）：`env:VAR` 原样，长密钥首6+...尾4
- 上下文窗口格式化（`format_context/1`）：≥1M→"XM"，≥1K→"XK"
- `settings_menu_items/0` 返回菜单列表（仅 `available_models` 为 active，其余占位）

### 2. 新建 `lib/sigil_web/live/available_models_live.html.heex`

模板，三栏布局：

**顶部栏**：`← 返回工作台` 链接（`href="/"`）+ 面包屑 `设置 / 可用模型`

**左栏（180px）**：设置一级菜单
- 六项（通用/可用模型/工作区/工具权限/MCP扩展/日志调试）
- 可用模型高亮（`bg-accent-bg` + `border-l-accent`）
- 其余灰色可 hover

**中栏（260px）**：供应商列表
- 顶部 [+ 添加供应商] 按钮
- 每个供应商一行：name + 默认标签 + id（monospace 小字）
- 选中项高亮

**右栏（flex-1）**：详情 + 模型
- 供应商详情区：Provider ID / 名称 / API 类型 / Base URL / API Key(脱敏) / 默认开关
- [编辑] [删除供应商] 按钮（仅1个供应商时禁用删除）
- 模型区：[+ 添加模型] + 表格（ID/名称/类型/上下文/✕）
- 未选中供应商时显示空状态

**弹窗**（fixed overlay + 白色卡片）：
- 添加供应商：名称/ID/API类型下拉/Base URL/API Key + 初始模型(ID/名称/上下文/最大输出)
- 编辑供应商：名称/API类型/Base URL/API Key（ID不可改）
- 添加模型：ID/名称/类型下拉/上下文/最大输出
- 删除确认：标题 + 说明 + [取消] [确认删除]

所有 CSS class 使用 `settings-` 前缀。

### 3. 修改 `lib/sigil_web/router.ex`

在已有 scope 内新增一行：

```elixir
live "/settings/available-models", AvailableModelsLive, :index
```

**不要动** locale 中间件（`put_locale` 及其辅助函数），**不要动** `live "/w/:workspace_id/c/:conversation_id"` 路由。

### 4. 修改 `priv/static/assets/css/workspace.css`

在文件末尾追加新的 CSS section：

```css
/* ═══════════════════════════════════════════════════════════════════
   Settings / Available Models Page
   ═══════════════════════════════════════════════════════════════════ */
```

包含以下样式组：

| 组件 | 主要 class |
|------|-----------|
| 导航菜单 | `.settings-nav`、`.settings-nav-item`、`.settings-nav-item-active` |
| 详情面板 | `.settings-detail-section`、`.settings-detail-heading`、`.settings-detail-grid`、`.settings-detail-row`、`.settings-detail-label`、`.settings-detail-value` |
| 按钮 | `.settings-btn`、`.settings-btn-primary`、`.settings-btn-danger` |
| Toggle | `.settings-toggle`、`.settings-toggle-slider` |
| 模型表格 | `.settings-model-table`、`.settings-model-delete` |
| 弹窗 | `.settings-overlay`、`.settings-dialog`、`.settings-dialog-sm`、`.settings-dialog-title` |
| 表单 | `.settings-form-group`、`.settings-form-label`、`.settings-form-hint`、`.settings-form-row`、`.settings-input`、`.settings-form-divider`、`.settings-dialog-actions` |
| Badge | `.settings-badge` |
| 工具类 | `.bg-error-subtle`、`.border-l-accent`、`.bg-accent-bg`、`.text-accent`、`.text-accent-hover` |

颜色全部使用 CSS 变量，不写死色值（遮罩 `rgba(0,0,0,0.4)` 除外）。

## 已有的 ModelConfig API（无需修改）

- `config_file_path/0` → 配置文件路径
- `ensure_config/0` → 确保文件存在
- `add_provider/2` → 添加供应商
- `remove_provider/1` → 删除供应商
- `update_provider/2` → 更新供应商
- `add_model/3` → 添加模型
- `remove_model/2` → 删除模型
- `update_model/3` → 更新模型
- `write_config/1` → 写入完整配置（含 PubSub 广播）

## 验收

- [ ] 页面在 `/settings/available-models` 可访问
- [ ] 供应商列表显示 StepFun（带默认标签）
- [ ] 点击供应商切换右侧详情
- [ ] 添加/编辑/删除供应商生效
- [ ] 默认供应商 toggle 正常工作
- [ ] 添加/删除模型生效
- [ ] 弹窗表单输入正常（phx-change）
- [ ] 外部修改 models.json 后页面自动刷新
- [ ] 顶部返回链接可用
- [ ] `mix compile` 无报错