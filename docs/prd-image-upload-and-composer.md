# PRD — 本地 WebUI 图片上传 + 输入框重设计（含粘贴图片）

日期：2026-05-16  
产品：Sigil（Elixir/Phoenix LiveView，本地 Web UI）  
范围：`sigil/`（Workspace 工作台与相关 UI 组件）  

---

## 1. 背景

当前 Workspace Web UI 的消息输入区仅支持纯文本发送。与此同时，Sigil 的 Agent/Provider 层已经具备“内联图片块（base64）”能力：用户消息可以由 `text + image` content blocks 组成，并被 OpenAI/Anthropic 等 provider 格式化为可识图的输入。

因此需要补齐 Web UI 侧：

- 图片上传与预览
- 复制/粘贴图片（从剪贴板直接粘贴截图）
- 本地落盘（不接 S3/对象存储）
- 发送时将“文字 + 图片”注入模型（vision input）
- 输入框重设计：更接近现代 agent 产品的 composer（工具条、模型选择、Stop、快捷键语义）

---

## 2. 目标与非目标

### 2.1 目标（Must）

1) 两个输入框/通道都支持上传图片（选择文件、拖拽、粘贴）。  
2) 支持“文字 + 多张图片”一起发送到 Agent（模型可见）。  
3) `running=true`（Agent 正在运行）时仍支持上传并发送（作为 steer/follow-up）。  
4) 图片落盘到本地（workspace 目录内隔离优先），对话历史可回看缩略图。  
5) 输入框 UI 重设计：从单行输入升级为多行 composer，并包含工具条与附件预览条。  

### 2.2 非目标（Not Now）

- 音频/视频上传与作为模型输入（可预留 UI 位置）
- 图片编辑、标注、OCR、裁剪
- 云端同步与多端共享
- S3/OSS 等外部对象存储

---

## 3. 用户故事

- 我希望粘贴一张截图（Cmd/Ctrl+V）并附带文字，发送给 Agent 让它解释图片内容/指出问题。
- 我希望拖拽 1~N 张图片到输入框即可发送，不用额外配置。
- Agent 正在生成回复时，我希望能补充一张图并 steer，让 Agent “基于这张图继续”。
- 我希望历史消息中能看到我发过的图片，方便复盘。

---

## 4. 输入框重设计（UI/UX）

### 4.1 布局（自上而下）

1) 主输入区：`textarea`（多行）
- 默认提示：`Enter 发送 · Shift+Enter 换行（支持拖拽/粘贴图片）`
- `running=true` 时视觉强调（例如 warning ring），并可将按钮文案从 `Send` 切换为 `Steer`

2) 工具条（单行）
- 左侧：附件按钮（`+` 或 `📎`）、（可选）“权限/模式”占位下拉
- 右侧：模型选择器、Stop（运行中）、Send/Steer

3) 附件预览条（有附件才显示）
- 缩略图 chip（包含文件名、大小）
- 支持逐个移除
- 显示限制：`N/max_entries · max_file_size`

### 4.2 键盘交互（Must）

- `Enter`：发送
- `Shift+Enter`：换行

### 4.3 粘贴图片（Must）

当 `textarea` 聚焦，用户 `Cmd/Ctrl+V`：

- 剪贴板含图片：将图片作为附件追加（不把乱码插入文本）
- 剪贴板含文本：保持原行为
- 同时含文本 + 图片：**推荐两者都保留**（文本粘入输入框，图片进入附件预览条）

---

## 5. 上传能力（功能规格）

### 5.1 支持类型

- 图片：`png/jpg/jpeg/gif/webp`
- 入口：点击选择（Must）、拖拽（Should）、粘贴（Must）

### 5.2 限制（默认值，可配置）

- `max_entries = 4`
- `max_file_size = 5MB`

### 5.3 错误提示

- 非图片类型：拒绝并提示
- 超过大小：拒绝并提示
- 超过数量：拒绝并提示

---

## 6. 本地存储与访问

### 6.1 推荐方案（B：workspace 内隔离 + Controller）

- 存储：`<workspace_path>/.sigil/uploads/<conversation_id>/<uuid>.<ext>`
- 访问：`GET /uploads/:conversation_id/:file`（Controller）
  - 校验路径必须在 `<workspace_path>/.sigil/uploads/<conversation_id>/` 内
  - 通过 `send_file` 返回图片

优点：不污染 `priv/static`，天然按 workspace+conversation 隔离，可控且便于清理。

### 6.2 备选方案（A：priv/static/uploads + Plug.Static）

- 存储：`priv/static/uploads/...`
- 访问：`/uploads/...` 静态直出

优点：实现快；缺点：静态目录通常用于构建产物，且隔离弱。

---

## 7. 模型兼容性（Vision 支持）

不是所有模型都支持图片输入。策略（PRD 推荐）：

- 若当前模型不支持 vision：禁用附件入口并提示原因
- 或允许落盘但发送时不注入模型（转成文本提示）；此为备选

---

## 8. 数据结构（产品层）

### 8.1 Timeline entry（建议扩展）

在 `user_msg` entry 中增加：

- `attachments: [%{id, kind: "image", mime_type, size_bytes, filename, url}]`

用于 UI 历史展示（缩略图/点击打开）。

### 8.2 Agent message content（必须支持）

对 Agent 的 user message 支持两种形态：

- `String.t()`（纯文本，兼容现状）
- `content_blocks :: [ %{type: "text", text: ...} | %{type: "image", mime_type: ..., data: base64} ]`

---

## 9. 参考与草图

本 PRD 的输入框布局与交互草图见：

- `sigil/tmp/upload_composer_sketch.html`

说明：

- 草图用于确认布局与粘贴/拖拽行为；
- 实际接入 Sigil 后，颜色与 UI token 必须遵循 Sigil 现有色系（见 `sigil/priv/static/assets/css/workspace.css` 的语义变量 `--bg/--panel/--text/--muted/--accent/...`）。

---

## 10. 验收标准（Acceptance Criteria）

1) 两个输入框/通道都出现：附件按钮 + 附件预览条。  
2) 点击选择图片 → 预览条出现缩略图 chip，可移除。  
3) 拖拽图片到输入区 → 预览条出现缩略图 chip。  
4) 聚焦输入框粘贴截图（Cmd/Ctrl+V） → 图片进入预览条，文本粘贴不受影响。  
5) 发送“文字+图片”后：timeline 内可回看缩略图，点击可打开原图。  
6) 发送后 Agent 可感知图片（vision input 生效）。  
7) running=true 时也可发送附件消息，并在后续输出中体现收到附件上下文。  
8) 非图片/超大/超数量会被拒绝并提示。  

---

## 11. 迭代计划

### MVP

- 输入框重设计 + 图片选择上传
- 附件预览条 + 删除
- 粘贴图片（clipboard）与拖拽上传
- 本地落盘 + 可访问预览

### 后续

- 图片点击放大/画廊
- 上传清理策略（按会话/按天数/手动清理）
- 更细的模型兼容提示与自动降级策略

