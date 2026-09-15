# Sigil WebUI Redesign — Implementation Task

> 目标：将 Sigil 的 Web UI 从硬编码色值迁移到语义化 CSS Token 体系，支持主题切换架构，先完成 Light 主题。
> 参考：PRD → `sigil/docs/prd-webui-redesign.md`，效果预览 → `sigil/mobile-ux-redesign-preview.html`

---

## 核心设计决策

| 维度 | 决定 |
|------|------|
| 色系 | 暖白底（`#FAF9F7`）+ 正文墨色 accent（`#1A1815`）。不要琥珀金、紫色、蓝色 |
| 深度 | 纯边框分层，不用阴影（除了浮层对话框） |
| 字体 | UI 用系统 sans-serif 栈；代码/数值区用 JetBrains Mono / SF Mono |
| 移动端 | 保持当前底部抽屉+FAB+单面板架构，CSS 响应式适配 |
| sid/cid | 状态栏不显示，URL 里已有 |

---

## 文件变更计划

### Phase 1 — 新建 Token 文件

#### 1a. `sigil/priv/static/assets/css/theme-light.css`

新建，内容为 Light 主题的所有 CSS 自定义属性。**只定义变量，不写组件样式。**

```css
/* Sigil — Light Theme Tokens */
[data-theme="light"] {
  /* Background */
  --sig-bg-page:            #FAF9F7;
  --sig-bg-surface:         #F4F3F0;
  --sig-bg-surface-hover:   #EDEBE7;
  --sig-bg-surface-active:  #E6E3DE;
  --sig-bg-elevated:        #FFFFFF;
  --sig-bg-input:           #EFEEEA;
  --sig-bg-code:            #EEECE8;

  /* Text */
  --sig-text-primary:       #1A1815;
  --sig-text-secondary:     #6B6560;
  --sig-text-tertiary:      #9C9590;
  --sig-text-inverse:       #FFFFFF;

  /* Border */
  --sig-border-default:     #E4E0DA;
  --sig-border-subtle:      #F0EDE8;
  --sig-border-emphasis:    #D4CEC5;

  /* Accent — ink, same as primary text */
  --sig-accent:             #1A1815;
  --sig-accent-hover:       #000000;
  --sig-accent-subtle:      rgba(26, 24, 21, 0.06);
  --sig-accent-strong:      rgba(26, 24, 21, 0.12);
  --sig-accent-border:      rgba(26, 24, 21, 0.22);

  /* Semantic */
  --sig-success:            #1B8A5E;
  --sig-success-bg:         rgba(27, 138, 94, 0.08);
  --sig-warning:            #9A6A0C;
  --sig-warning-bg:         rgba(154, 106, 12, 0.08);
  --sig-error:              #C53030;
  --sig-error-bg:           rgba(197, 48, 48, 0.08);

  /* Messages */
  --sig-msg-user-bg:        var(--sig-bg-surface-active);
  --sig-msg-user-text:      var(--sig-text-primary);
  --sig-msg-assistant-bg:   var(--sig-bg-surface);
  --sig-msg-assistant-border: var(--sig-border-default);

  /* Tool events */
  --sig-tool-running-border: var(--sig-warning);
  --sig-tool-running-bg:     var(--sig-warning-bg);
  --sig-tool-done-border:    var(--sig-success);
  --sig-tool-done-bg:        var(--sig-success-bg);
  --sig-tool-error-border:   var(--sig-error);
  --sig-tool-error-bg:       var(--sig-error-bg);

  /* Diff */
  --sig-diff-add-text:      #1B8A5E;
  --sig-diff-add-bg:        rgba(27, 138, 94, 0.08);
  --sig-diff-remove-text:   #C53030;
  --sig-diff-remove-bg:     rgba(197, 48, 48, 0.08);
  --sig-diff-eq-text:       var(--sig-text-tertiary);

  /* Radius */
  --sig-radius-sm:   4px;
  --sig-radius-md:   6px;
  --sig-radius-lg:  10px;
  --sig-radius-xl:  14px;
  --sig-radius-full: 9999px;

  /* Motion */
  --sig-motion-fast:   120ms;
  --sig-motion-normal: 200ms;
  --sig-motion-slow:   300ms;
  --sig-motion-ease:   cubic-bezier(0.22, 1, 0.36, 1);

  /* Font */
  --sig-font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans SC", sans-serif;
  --sig-font-mono: "JetBrains Mono", "SF Mono", "Cascadia Code", ui-monospace, monospace;

  /* Legacy compat aliases — keep components from breaking during migration */
  --color-primary: var(--sig-accent);
  --color-primary-hover: var(--sig-accent-hover);
  --color-user-message: var(--sig-accent);
  --color-user-message-hover: var(--sig-accent-hover);
  --color-background: var(--sig-bg-page);
  --color-surface: var(--sig-bg-surface);
  --color-surface-hover: var(--sig-bg-surface-hover);
  --color-surface-active: var(--sig-bg-surface-active);
  --color-border: var(--sig-border-default);
  --color-border-light: var(--sig-border-subtle);
  --color-border-hover: var(--sig-border-emphasis);
  --color-text-primary: var(--sig-text-primary);
  --color-text-secondary: var(--sig-text-secondary);
  --color-text-tertiary: var(--sig-text-tertiary);
  --color-success: var(--sig-success);
  --color-success-bg: var(--sig-success-bg);
  --color-warning: var(--sig-warning);
  --color-warning-bg: var(--sig-warning-bg);
  --color-error: var(--sig-error);
  --color-error-bg: var(--sig-error-bg);
  --color-diff-add: var(--sig-diff-add-text);
  --color-diff-add-bg: var(--sig-diff-add-bg);
  --color-diff-rem: var(--sig-diff-remove-text);
  --color-diff-rem-bg: var(--sig-diff-remove-bg);
}
```

**注意：** Token 文件末尾需要提供 Legacy compat aliases——把旧的 `--color-*` 变量映射到新的 `--sig-*` 变量。这样组件 CSS 可以渐进迁移，不会因为变量名突然消失而断裂。

#### 1b. `sigil/priv/static/assets/css/theme-system.css`

新建，主题加载基础设施（`data-theme` 选择器、fallback 链）。**极简，只做变量作用域声明。**

```css
/* Sigil — Theme System
 * 主题通过 <html data-theme="light|dark|custom"> 切换
 * 默认 fallback 到 light 主题色值 */
```

> 当前只需要声明默认 `:root` fallback （可以直接复用 `[data-theme="light"]` 的值作为默认），为将来多主题留好 `[data-theme="dark"]` 等选择器空位。

#### 1c. `sigil/assets/js/app.js` 或独立 JS

添加主题初始化逻辑（约 6 行）：

```js
// Theme initialization
const theme = localStorage.getItem('sigil-theme') || 'light'
document.documentElement.setAttribute('data-theme', theme)
```

### Phase 2 — 修改现有 CSS

#### 2a. `sigil/priv/static/assets/css/workspace.css`

**目标：** 所有硬编码色值替换为新 Token 引用。策略：

1. **替换 CSS 变量定义块**（Layer 1 区域）：
   - 删除旧的 `:root { --color-* }` 和 `@media (prefers-color-scheme: dark) { :root { --color-* } }` 两整块
   - 替换为新 `data-theme` 体系，由 `theme-light.css` 提供

2. **替换 Layer 1b "Semantic Token Aliases"**：
   - 删除旧的 alias 映射（`--text: var(--color-text-primary)` 等）
   - 改为直接引用新 Token（待到组件层逐步替换）

3. **渐进替换组件样式中的色值引用**：
   - `#activity-bar` 背景 → `var(--sig-bg-surface)`
   - 文字色 → `var(--sig-text-primary/secondary/tertiary)`
   - 边框 → `var(--sig-border-default/subtle)`
   - accent → `var(--sig-accent)` / `var(--sig-accent-subtle)` 等
   - 用户消息背景 → `var(--sig-msg-user-bg)`
   - AI 消息 → `var(--sig-msg-assistant-bg)` + `var(--sig-msg-assistant-border)`
   - 工具事件 → `var(--sig-tool-*-border)` + `var(--sig-tool-*-bg)`
   - 状态点颜色 → `var(--sig-accent)` / `var(--sig-success)` 等
   - 输入框聚焦环 → `var(--sig-accent-border)` + `box-shadow: 0 0 0 3px var(--sig-accent-subtle)`

4. **删除 `@media (prefers-color-scheme: dark)` 块**

5. **移除 Thinking 指示器相关样式**（`.thinking-block`、`.thinking-dot` 等）——Thinking 状态改为不显示动画。

6. **移除状态栏中的 sid/cid** 相关样式（不需要，因为信息已在 URL 中）。

7. **微调圆角**：输入框/按钮 `var(--sig-radius-sm)`、卡片/面板 `var(--sig-radius-md)`、对话框 `var(--sig-radius-lg)`、composer `var(--sig-radius-xl)`

**注意：** 不要在一次性替换中改动布局和动画逻辑——只换颜色。布局改动放到 Phase 3。

#### 2b. `sigil/priv/static/assets/css/composer.css`

**目标：** 同步替换 Token 引用，保持一致。

- 所有 `var(--color-*)` → 对应的 `var(--sig-*)` 或保持 Legacy compat alias
- 所有 `var(--accent)`, `var(--panel)`, `var(--border)` 等') → 对应的新 Token
- 聚焦环颜色 → `var(--sig-accent-border)` + `var(--sig-accent-subtle)`
- Send 按钮背景 → `var(--sig-accent)` / hover `var(--sig-accent-hover)`
- Steer 按钮 → `var(--sig-warning-bg)` + `var(--sig-warning)`
- Stop 按钮 → `var(--sig-error-bg)` + `var(--sig-error)`

#### 2c. `sigil/lib/sigil_web/components/layouts/root.html.heex`

1. **在 `<head>` 中按顺序引入新 CSS 文件：**
   ```html
   <link phx-track-static rel="stylesheet" href={~p"/assets/css/theme-system.css"} />
   <link phx-track-static rel="stylesheet" href={~p"/assets/css/theme-light.css"} />
   ```
   位置：放在 `app.css` 之后、`workspace.css` 之前。

2. **移出内联 `<style>` 中的硬编码色值：**
   - 内联 style 中所有 `.bottom-sheet`, `.sheet-*`, `.mobile-*` 的颜色 → 移到 `workspace.css` 或用 Token 替换
   - 底部抽屉背景 `white` → `var(--sig-bg-elevated)`
   - 抽屉文字色 `#6b7280` 等 → `var(--sig-text-*)`
   - 分割线和 hover 背景 → `var(--sig-border-*)` / `var(--sig-bg-surface-hover)`
   - 移动端 header 背景/边框 → `var(--sig-bg-surface)` / `var(--sig-border-default)`

3. **移除状态栏中的 sid/cid 显示** —— 这两个 span 在 URL 里已有，状态栏不需要。

4. **移除 Thinking 指示器** —— 删除 `:if={@thinking_active}` 的 thinking-block div。

5. **保留 "Agent is working…" 指示器** —— `:if={@running and @timeline != []}` 的部分。静止点，不要 glow / pulse。

### Phase 3 — 视觉调优

这些是"感觉"层面的微调，不需要改功能逻辑：

| 调整 | 说明 |
|------|------|
| 侧栏宽度 | 220px → 240px |
| 文件面板宽度 | 520px → 480px |
| 消息气泡最大宽度 | 85% → 78% |
| 用户消息圆角 | 保持右下小圆角，但圆角值统一到 `--sig-radius-*` |
| 工具事件左边框 | 3px → 统一用 `--sig-tool-*-border` |
| 输入框 focus 态 | 边框色 + 3px 扩散阴影，颜色用 accent token |
| 状态栏高度 | 保持 32px |

### Phase 4 — 清理 & 验证

- `grep` 全项目 `sigil/priv/static/assets/css/` 目录检查无残留十六进制色值（`#` 开头的颜色）
- `grep` 全项目 `sigil/lib/sigil_web/` 检查 heex 模板中无 hardcode `color:` / `background:` 
- `mix test` 全量通过
- 手动在浏览器验证桌面端和移动端

---

## 禁止事项

- ❌ 不要动 BEAM/Agent/Coordinator/Turn/Provider 等后端代码
- ❌ 不要动 LiveView 的事件处理逻辑（`handle_event`、`handle_info`）
- ❌ 不要改动 `.heex` 模板的 `:for`、`:if`、`phx-*` 等动态逻辑，只改 CSS class 和 inline style
- ❌ 不要删改 `motion.css`
- ❌ 不要引入新的 npm 依赖或外部字体 CDN——字体用系统栈
- ❌ 不要重新引入已经移除的 sid/cid 显示
- ❌ 不要重新引入 Thinking 动画块

---

## 验证清单

实施完成后逐项自查：

- [ ] `theme-light.css` 和 `theme-system.css` 文件存在且被 `root.html.heex` 引用
- [ ] `app.js` 中有主题初始化代码
- [ ] `workspace.css` 中无旧的 `:root { --color-* }` 定义块
- [ ] `workspace.css` 中无 `@media (prefers-color-scheme: dark)` 块
- [ ] `root.html.heex` 内联 style 中无硬编码色值（`#xxxxxx`）
- [ ] 桌面端三栏正常渲染，颜色为暖白色系 + 墨色强调
- [ ] 移动端单面板正常，底部抽屉交互正常
- [ ] 输入框 focus 为墨色聚焦环，不是琥珀
- [ ] 状态栏无 sid/cid，MCP/Skills 用文字不用 emoji
- [ ] 无 Thinking 动画块
- [ ] 有 "Agent is working…" 指示器（静止点，无 glow）
- [ ] `mix test` 通过