# 更新日志 (CHANGELOG)

## [2026-05-20] - Workspace 权限管理与弹窗修复

### 新增功能
- **动态工作区权限控制**: 
  - 在 Web UI 的输入框工具栏左侧新增了权限状态 Pill 按钮。
  - 支持下拉选择三种权限模式：
    - **完整存取 (Auto)**: 自动运行所有工具（相当于之前模式）。
    - **安全模式 (Prompt)**: 运行修改类/命令类等敏感工具前会弹出二次确认窗口。
    - **只读模式 (Deny)**: 拒绝所有写文件或命令执行工具。
  - 权限模式的变更会自动、非破坏性地同步写入对应工作区目录下的 `.sigil/settings.jsonc` 配置文件，完整保留用户现有的注释和格式。

### 修复 (Bug Fixes)
- **权限弹窗丢失/隐藏问题**:
  - 修复了 `SigilWeb.WorkspaceLive` 中 `safe_atom/1` 在遇到 `"interrupted"` 和 `"awaiting_approval"` 状态时会被错误重置为 `:idle` 的 Bug。该修复恢复了在“安全模式”下触发敏感工具时审批确认弹窗（Tool Approval Modal）的正常呈现。
  - 修复了在关闭其他手机弹窗/侧边面板时，没有隐藏权限切换下拉菜单的视觉问题。

### 开发与验证
- 引入了针对 `Sigil.WorkspaceSettings.update_default_mode/2` 修改配置文件的单元测试，确保修改符合非破坏性预期。
- 引入了 LiveView 交互集成测试，覆盖了下拉菜单展开、点击切换、自动收起、UI 状态同步以及 settings.jsonc 文件的落盘更新验证。
