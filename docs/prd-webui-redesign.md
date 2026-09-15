# PRD: Sigil WebUI 重设计

> 版本: 1.1
> 状态: Living
> 目标迭代: mobile-webui-compat
> 关联: 主题架构 → CSS Token 系统 → Light 主题 → 后续深色/自定义主题
>
> 1.1：强调色从琥珀金改为正文墨色 `#1A1815`。用户气泡用中性底，不再用实心 accent。状态点不发光、不脉冲。空状态和状态栏不用 emoji。

---

## 1. 动机

当前 WebUI 的几个问题：

| 问题 | 表现 |
|------|------|
| **色彩无体系** | CSS 变量名混乱（`--color-primary` 实际是 teal，语义不清），inline style 散落大量 hardcode 色值 |
| **无法切换主题** | 仅靠 `prefers-color-scheme` 自动切换浅/深，没有显式的主题切换机制 |
| **视觉同质化** | 看起来像个"标准 AI Chat 面板"，与其他 AI 产品没有区分度 |
| **样式散落** | `workspace.css`（1200行）、`composer.css`、`root.html.heex` 内联 `<style>` 三处各自定义颜色 |

**目标：**
- 建立语义化 CSS Token 体系，所有颜色从 Token 派生
- 主题切换架构（`data-theme` 属性），可扩展到多套主题
- 先完成一套高质量 Light 主题
- 视觉上让 Sigil 看起来像"开发者工作台"而非"又一个 AI 产品"

---

## 2. 设计哲学

### 2.1 定位

Sigil 是**本地运行的开发者工具**，不是 AI 消费品。

类比对象不是 ChatGPT / Claude 网页版，而是：
- **终端分屏器**（tmux / iTerm2 分屏）
- **代码编辑器**（VS Code / Zed）
- **BEAM Observer**（进程可视化）

### 2.2 设计原则

| 原则 | 说明 |
|------|------|
| **工具感** | 色彩退到背景里，让内容和交互成为主角。打开 Sigil 应该像打开终端的本能反应——上手就能干活 |
| **克制** | 不用任何装饰性颜色。颜色只用于：结构分层、状态指示、行动召唤 |
| **终端原生** | 色系来自开发者真实环境：终端的底色、代码的语法高亮、diff 的增删色 |
| **精准排版** | 字体是工具个性的核心。代码区用 Mono，UI 标签/数值也可以用 Mono 增加工具感 |
| **边框分层** | 不用阴影做层级（那是消费级产品的做法）。用细边框区分面板，像 tmux 分屏线 |
| **密度分化** | 工具事件/日志/状态栏→密集；对话消息→有呼吸感。不搞一刀切的留白 |

### 2.3 色彩世界

色系来自开发者的真实工具：

| 来源 | 色感 | 用途 |
|------|------|------|
| 终端底色 | 暖白/暖黑 | 页面背景 |
| 终端分割线 | 浅灰细线 | 面板边界 |
| 正文墨色 | 近黑 `#1A1815` | 主强调色（发送按钮、选中态、运行态）。不要另造暖橙/琥珀 |
| 语法高亮-字符串 | 深绿 | 成功态、工具完成、BEAM 进程存活 |
| 语法高亮-警告 | 暗琥珀 | 仅工具运行中、编译警告，不当品牌色 |
| Git diff 删除行 | 暗红 | 错误态、危险操作 |
| 代码注释 | 中灰 | 辅助文字、placeholder |

---

## 3. 主题架构

### 3.1 切换机制

```html
<!-- 默认 Light 主题 -->
<html data-theme="light">

<!-- 将来扩展到 Dark -->
<html data-theme="dark">

<!-- 将来扩展到自定义主题 -->
<html data-theme="custom-name">
```

切换方式：
- **存储**：`localStorage.setItem('sigil-theme', 'light')`
- **应用**：JS 启动时读取并设置 `document.documentElement.dataset.theme`
- **Fallback**：无存储时默认 `light`
- **系统联动（可选）**：`data-theme="auto"` 时跟随 `prefers-color-scheme`

### 3.2 文件架构

```
priv/static/assets/css/
├── theme-system.css     # 主题基础设施（data-theme 作用域、无值变量声明）
├── theme-light.css      # Light 主题 Token 值
├── theme-dark.css       # Dark 主题 Token 值（将来）
├── workspace.css        # 组件样式（改用语义 Token）
├── composer.css         # 输入区样式（改用语义 Token）
└── motion.css           # 动画（不变）
```

### 3.3 Token 命名规范

所有 Token 采用三层语义命名：`--sig-{类别}-{属性}`

| 类别 | 前缀 | 用途 |
|------|------|------|
| 背景 | `--sig-bg-` | 页面、面板、输入框、浮层 |
| 文字 | `--sig-text-` | 主要、次要、辅助、禁用 |
| 边框 | `--sig-border-` | 默认、细微、强调、聚焦 |
| 强调色 | `--sig-accent-` | 主色、hover、背景、边框 |
| 语义 | `--sig-{success/warning/error}-` | 成功/警告/错误及其背景色 |
| 排版 | `--sig-font-` | 字体族、字号、行高、字重 |
| 间距 | `--sig-space-` | 基于 4px 的间距序列 |
| 圆角 | `--sig-radius-` | 小/中/大/全圆 |
| 消息 | `--sig-msg-` | 用户气泡、AI气泡、工具事件 |
| 动效 | `--sig-motion-` | 时长、缓动函数 |

**命名规则：**
- 全小写，用 `-` 分隔
- 语义优先于视觉描述（`--sig-text-secondary` > `--sig-text-gray-600`）
- 不用颜色名（不出现 `blue`、`red`、`gray`）
- 不用具体数值（不出现 `14px`、`1rem`）

### 3.4 Token 作用域

```css
/* theme-system.css — 声明但不赋值（作为文档和 fallback 继承链）*/
:root {
  /* 这些变量在 theme-light.css / theme-dark.css 中赋值 */
}

/* theme-light.css — 仅赋值 */
[data-theme="light"] {
  --sig-bg-page: #FAF9F7;
  /* ... */
}

/* 组件样式引用 Token */
.workspace-shell {
  background: var(--sig-bg-page);
  color: var(--sig-text-primary);
}
```

---

## 4. Light 主题规格

### 4.1 背景层级

背景从深到浅共 5 层，用于表达页面中的层级关系：

| Token | 色值 | 用途 | 说明 |
|-------|------|------|------|
| `--sig-bg-page` | `#FAF9F7` | 页面底色 | 暖白，像纸张 |
| `--sig-bg-surface` | `#F4F3F0` | 面板/卡片底色 | 微妙的层次区分 |
| `--sig-bg-surface-hover` | `#EDEBE7` | 悬停态 | 比 surface 深一点 |
| `--sig-bg-surface-active` | `#E6E3DE` | 按下/选中态 | 比 hover 再深一点 |
| `--sig-bg-elevated` | `#FFFFFF` | 浮层/对话框 | 纯白，最高层级 |
| `--sig-bg-input` | `#EFEEEA` | 输入框底色 | 比 surface 深，提示"可以输入" |
| `--sig-bg-code` | `#EEECE8` | 代码块底色 | 微妙区分于正文 |

### 4.2 文字层级

| Token | 色值 | 用途 |
|-------|------|------|
| `--sig-text-primary` | `#1A1815` | 正文、标题 |
| `--sig-text-secondary` | `#6B6560` | 辅助说明、meta 信息 |
| `--sig-text-tertiary` | `#9C9590` | 占位符、时间戳、disabled |
| `--sig-text-inverse` | `#FFFFFF` | 深色背景上的文字 |

### 4.3 边框层级

| Token | 色值 | 用途 |
|-------|------|------|
| `--sig-border-default` | `#E4E0DA` | 常规面板分割、输入框边框 |
| `--sig-border-subtle` | `#F0EDE8` | 列表中项之间的细微分割 |
| `--sig-border-emphasis` | `#D4CEC5` | 需要强调的分割、hover 边框 |
| `--sig-border-focus` | `var(--sig-accent)` | 聚焦环 |

### 4.4 强调色（Accent）

墨色——和正文同一支色，不另造品牌橙。

| Token | 色值 | 用途 |
|-------|------|------|
| `--sig-accent` | `#1A1815` | 主强调色，等于 `--sig-text-primary` |
| `--sig-accent-hover` | `#000000` | hover 加深 |
| `--sig-accent-subtle` | `rgba(26, 24, 21, 0.06)` | 微弱强调背景 |
| `--sig-accent-strong` | `rgba(26, 24, 21, 0.12)` | 较强强调背景 |
| `--sig-accent-border` | `rgba(26, 24, 21, 0.22)` | 强调边框 |

### 4.5 语义色

| Token | 色值 | 用途 |
|-------|------|------|
| `--sig-success` | `#1B8A5E` | 成功/完成 |
| `--sig-success-bg` | `rgba(27, 138, 94, 0.08)` | 成功态背景 |
| `--sig-warning` | `#B87A0E` | 警告/运行中 |
| `--sig-warning-bg` | `rgba(184, 122, 14, 0.08)` | 警告态背景 |
| `--sig-error` | `#C53030` | 错误/危险 |
| `--sig-error-bg` | `rgba(197, 48, 48, 0.08)` | 错误态背景 |

### 4.6 消息气泡

| Token | 色值 | 用途 |
|-------|------|------|
| `--sig-msg-user-bg` | `var(--sig-bg-surface-active)` | 用户消息背景（中性底，不是实心 accent） |
| `--sig-msg-user-text` | `var(--sig-text-primary)` | 用户消息文字 |
| `--sig-msg-assistant-bg` | `var(--sig-bg-surface)` | AI 消息背景 |
| `--sig-msg-assistant-border` | `var(--sig-border-default)` | AI 消息边框 |
| `--sig-msg-system-bg` | `var(--sig-error-bg)` | 系统消息背景 |
| `--sig-msg-system-text` | `var(--sig-error)` | 系统消息文字 |

### 4.7 工具事件

| Token | 色值 | 用途 |
|-------|------|------|
| `--sig-tool-running-border` | `var(--sig-warning)` | 运行中左边框 |
| `--sig-tool-running-bg` | `var(--sig-warning-bg)` | 运行中背景 |
| `--sig-tool-done-border` | `var(--sig-success)` | 完成左边框 |
| `--sig-tool-done-bg` | `var(--sig-success-bg)` | 完成背景 |
| `--sig-tool-error-border` | `var(--sig-error)` | 出错左边框 |
| `--sig-tool-error-bg` | `var(--sig-error-bg)` | 出错背景 |

### 4.8 Diff

| Token | 色值 | 用途 |
|-------|------|------|
| `--sig-diff-add-text` | `#1B8A5E` | 新增行文字 |
| `--sig-diff-add-bg` | `rgba(27, 138, 94, 0.08)` | 新增行背景 |
| `--sig-diff-remove-text` | `#C53030` | 删除行文字 |
| `--sig-diff-remove-bg` | `rgba(197, 48, 48, 0.08)` | 删除行背景 |
| `--sig-diff-eq-text` | `#9C9590` | 未变更行 |
| `--sig-diff-skip-text` | `#BFB9B3` | 跳过的行 |

### 4.9 排版

| Token | 值 | 用途 |
|-------|-----|------|
| `--sig-font-sans` | `"IBM Plex Sans", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif` | UI 正文 |
| `--sig-font-mono` | `"JetBrains Mono", "SF Mono", "Cascadia Code", ui-monospace, monospace` | 代码 & 数值 |
| `--sig-font-size-xs` | `0.6875rem` (11px) | 标签、badge |
| `--sig-font-size-sm` | `0.8125rem` (13px) | 辅助文字 |
| `--sig-font-size-base` | `0.9375rem` (15px) | 正文 |
| `--sig-font-size-lg` | `1.0625rem` (17px) | 子标题 |
| `--sig-font-size-xl` | `1.25rem` (20px) | 标题 |
| `--sig-font-size-2xl` | `1.5rem` (24px) | 大标题 |
| `--sig-font-weight-normal` | `400` | 正文 |
| `--sig-font-weight-medium` | `500` | 强调文字 |
| `--sig-font-weight-semibold` | `600` | 标题、按钮 |
| `--sig-font-weight-bold` | `700` | 强强调 |

### 4.10 间距

基础单位 4px，所有间距为 4 的倍数：

| Token | 值 | 用途 |
|-------|-----|------|
| `--sig-space-0` | `0` | 无间距 |
| `--sig-space-1` | `4px` | 图标与文字间距 |
| `--sig-space-2` | `8px` | 紧凑间距 |
| `--sig-space-3` | `12px` | 组件内间距 |
| `--sig-space-4` | `16px` | 标准间距 |
| `--sig-space-5` | `20px` | 区块间距 |
| `--sig-space-6` | `24px` | 大间距 |
| `--sig-space-8` | `32px` | 分区间距 |
| `--sig-space-10` | `40px` | 页面级分区 |
| `--sig-space-12` | `48px` | 页面间留白 |

### 4.11 圆角

| Token | 值 | 用途 |
|-------|-----|------|
| `--sig-radius-sm` | `4px` | 输入框、按钮、小标签 |
| `--sig-radius-md` | `6px` | 卡片、面板、工具事件 |
| `--sig-radius-lg` | `10px` | 编辑器、对话框 |
| `--sig-radius-xl` | `14px` | 模态框、composer |
| `--sig-radius-full` | `9999px` | 仅状态点等真正需要的圆。按钮和 composer 用 lg/xl，不要做成胶囊 |

### 4.12 动效

| Token | 值 | 用途 |
|-------|-----|------|
| `--sig-motion-fast` | `120ms` | 微交互（hover、focus） |
| `--sig-motion-normal` | `200ms` | 标准过渡 |
| `--sig-motion-slow` | `300ms` | 面板展开、页面切换 |
| `--sig-motion-ease` | `cubic-bezier(0.22, 1, 0.36, 1)` | 缓出曲线 |

### 4.13 深度策略

**只用边框，不用阴影**（除了浮层对话框）：

- 页面背景与面板之间：`--sig-border-default` 1px 线
- 面板内部区块之间：`--sig-border-subtle` 1px 线
- 浮层（对话框、下拉菜单）：`--sig-bg-elevated` + `box-shadow: 0 8px 32px rgba(0,0,0,0.08)` + `--sig-border-default`
- 聚焦环：`box-shadow: 0 0 0 3px var(--sig-accent-subtle)` + `border-color: var(--sig-accent-border)`

**不使用**：多层阴影叠加、毛玻璃模糊、渐变背景。

---

## 5. 组件规格

### 5.1 整体布局

保持三栏结构，微调比例：

```
┌──────────────────────────────────────────────────────────────┐
│ Mobile Header (mobile only)                                  │
├────────────┬──────────────────────────┬──────────────────────┤
│ Sidebar    │ Chat Panel              │ File Panel           │
│ 240px      │ flex-1                  │ 480px                │
│            │                          │                      │
│ Workspaces │ Messages                 │ File Tabs            │
│ + Convos   │ Tool Events              │ Diff/Preview         │
│            │ Input Area               │                      │
├────────────┴──────────────────────────┴──────────────────────┤
│ Status Bar (32px)                                            │
└──────────────────────────────────────────────────────────────┘
```

变更点：
- Sidebar: 220px → 240px
- File Panel: 520px → 480px
- Status Bar: 2rem(32px) → 保持

### 5.2 侧栏（Sidebar）

**Workspace 标题行：**
- 字号 `--sig-font-size-xs`，`--sig-font-weight-semibold`
- 文字色 `--sig-text-tertiary`，letter-spacing 0.04em
- 底部 `--sig-border-subtle` 分割线
- 左边加一条 3px 的 accent 竖线标记当前 workspace

**对话列表：**
- 缩进用左边 1px 竖线（`--sig-border-subtle`），渐变淡入淡出
- 每个对话项：圆角 `--sig-radius-md`，hover 背景 `--sig-bg-surface-hover`
- 当前对话：背景 `--sig-accent-subtle` + 边框 `--sig-accent-border`
- 圆点指示器：`--sig-accent` 色，6px 直径
- 归档按钮：hover 才显示，hover 为 `--sig-error-bg`

**回收站：**
- 保持 toggle 展开/折叠
- 已归档项半透明 `opacity: 0.75`

### 5.3 聊天面板

**消息气泡：**
- 用户消息：`--sig-msg-user-bg` 中性底，正文色文字，右对齐，右下角小圆角
- AI 消息：`--sig-msg-assistant-bg` 背景，`--sig-msg-assistant-border` 边框，左对齐，左下角小圆角
- 系统消息：全宽，`--sig-msg-system-bg` 背景，小字号
- 最大宽度 80%（从 85% 微调）

**工具事件卡片：**
- 左边 3px 色条 + 浅色背景（running=warning, done=success, error=error）
- 标题行：等宽字体 tool name + 输入摘要 + 耗时
- Running 态：左边框 pulse 动画
- Diff 链接：accent 色，hover 加下划线

**空状态：**
- 居中，标题 + 副标题
- 不用 emoji 或装饰图标

**Thinking 指示器：**
- 运行中显示静止点 + "Agent is working..." 文字。不要 glow，不要脉冲

### 5.4 输入区（Composer）

**容器：**
- `--sig-bg-elevated` 背景（白色）
- `--sig-border-default` 边框
- `--sig-radius-xl` 圆角
- 无投影；层级靠边框

**输入框：**
- `--sig-bg-input` 底色（比外面深一层，表示"可输入"）
- `--sig-border-default` 边框，focus 时 `--sig-accent-border` + 聚焦环
- `--sig-font-size-base` 字号
- 最小高度 72px，最大 200px
- Running 态：边框变 `--sig-warning` 色系

**工具栏：**
- 左侧：附件按钮（icon）+ 权限 Pill
- 右侧：Model 下拉 + Reasoning 下拉 + Stop/Steer/Send 按钮
- Send 按钮：`--sig-accent` 背景，`--sig-text-inverse` 文字，圆角 `--sig-radius-lg`
- Steer 按钮：`--sig-warning-bg` + `--sig-warning` 文字
- Stop 按钮：`--sig-error-bg` + `--sig-error` 文字

**附件区：**
- 保持当前 chip 布局
- 图片缩略图、文件名、大小、移除按钮

### 5.5 文件面板

**Tab 栏：**
- 文件 tab：字号 `--sig-font-size-xs`，底部 2px 下划线
- 活跃 tab：`--sig-accent` 色下划线 + `--sig-font-weight-semibold`
- 非活跃 tab：`--sig-text-secondary`，hover 变 `--sig-text-primary`

**Diff 视图：**
- 保持当前行内 diff 显示
- 新增行：`--sig-diff-add-bg` 背景 + `--sig-diff-add-text` 文字
- 删除行：`--sig-diff-remove-bg` 背景 + `--sig-diff-remove-text` 文字
- Revert 按钮：`--sig-error` 色，hover 加深

**文件预览：**
- 等宽字体，`--sig-bg-code` 背景

### 5.6 状态栏

- 高度 32px，`--sig-bg-surface` 背景
- 顶部 `--sig-border-default` 分割线
- 文字字号 `--sig-font-size-xs`，颜色 `--sig-text-tertiary`
- 左侧：设置齿轮 + Model + Tokens + Turns + Workspace + `MCP n` / `Skills n` 文字计数（不用 emoji）
- 右侧：Session ID + Conversation ID + 状态点
- 状态点颜色：idle=tertiary, running=ink（静止）, error=error, completed=accent。不要 glow / pulse

### 5.7 设置面板

- 模态覆盖层：`rgba(0,0,0,0.35)` 半透明背景
- 白色模态框：`--sig-bg-elevated` + `--sig-radius-xl` + 微弱阴影
- 左侧菜单（11rem 宽）+ 右侧内容区
- 菜单项：hover `--sig-bg-surface-hover`，active `--sig-accent-subtle`

### 5.8 移动端

保持当前移动端架构（底部抽屉 + FAB + 单栏），视觉同步更新：
- 底部抽屉底色与桌面侧栏一致
- 移动 Header 使用相同的 Token
- 对话导航与滚到底是一组方角按钮，颜色跟随 ink accent，不要全圆 FAB + 琥珀投影

---

## 6. 实现计划

### Phase 1: Token 基础设施

**新建文件：**
- `priv/static/assets/css/theme-system.css` — 主题加载机制、默认 fallback
- `priv/static/assets/css/theme-light.css` — Light 主题所有 Token 值

**引入方式：** 在 `root.html.heex` 中加载（确保优先级高于组件 CSS）

**新建 JS：**
- 在 `app.js` 中添加主题初始化逻辑：
  ```js
  // 从 localStorage 读取主题，默认 light
  const theme = localStorage.getItem('sigil-theme') || 'light'
  document.documentElement.dataset.theme = theme
  ```

### Phase 2: 迁移现有样式

**修改文件：**
- `workspace.css` — 替换所有硬编码色值为 Token 引用
- `composer.css` — 同上
- `root.html.heex` — 将内联 `<style>` 中的颜色迁移到 CSS 文件中，改用 Token

**不改变：**
- 布局结构（HTML 层级不变）
- 动画关键帧定义
- 移动端响应式断点和逻辑

### Phase 3: 视觉调优

- 调整侧栏比例、圆角、间距细节
- 调整消息气泡样式
- 调整工具事件卡片
- 调整输入框焦点态

### Phase 4: 清理 & 验证

- 删除旧的 CSS 变量定义
- 确保无 hardcode 色值残留
- 全量测试（`mix test`）
- 可视化检查（桌面端 + 移动端）

---

## 7. 文件变更清单

| 操作 | 文件 | 说明 |
|------|------|------|
| 新建 | `priv/static/assets/css/theme-system.css` | 主题基础设施 |
| 新建 | `priv/static/assets/css/theme-light.css` | Light 主题 Token |
| 修改 | `priv/static/assets/css/workspace.css` | 迁移至 Token |
| 修改 | `priv/static/assets/css/composer.css` | 迁移至 Token |
| 修改 | `lib/sigil_web/components/layouts/root.html.heex` | 引入新 CSS、移出内联颜色 |
| 修改 | `assets/js/app.js` | 主题初始化 JS |
| 修改 | `lib/sigil_web/live/workspace_live.html.heex` | 少量 class 调整 |

---

## 8. 成功标准

- [ ] 所有颜色从 CSS Token 派生，无 hardcode 色值
- [ ] `data-theme="light"` 切换机制可用，修改属性后全站颜色生效
- [ ] Light 主题视觉统一，符合 PRD 色值
- [ ] 桌面端三栏 + 移动端单栏均正常渲染
- [ ] 深色模式（`prefers-color-scheme: dark`）有合理的 fallback（不崩）
- [ ] 全量 `mix test` 通过
- [ ] 无新增 JS/CSS console 错误

---

## 9. 风险 & 待定

| 风险 | 缓解 |
|------|------|
| 旧 inline style 遗漏 | Phase 4 做全局 grep 检查 hardcode 色值 |
| CSS 优先级冲突 | 新 Token 文件在旧 CSS 之前加载 |
| 移动端样式断裂 | 移动端已在 CSS 中有较完整覆盖，迁移时保持选择器不变 |
| 字体加载 | IBM Plex Sans / JetBrains Mono 为 Web 安全字体后备，非必需网络加载 |

**待定（后续迭代）：**
- Dark 主题完整设计
- 主题 UI 切换控件（设置面板中的主题选择器）
- 自定义主题支持（用户可编辑 Token 值）
- 中文字体优化（思源黑体 / 阿里巴巴普惠体）