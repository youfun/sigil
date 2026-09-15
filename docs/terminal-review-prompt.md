# Code Review Request: Sigil 嵌入式终端功能

## 范围

Branch: `mobile-webui-compat`
Commits to review: `ce72068` → `5d8bcec` (5 commits)

### 新增文件（7 个）

| 文件 | 用途 |
|------|------|
| `lib/sigil/terminal/registry.ex` | 工作区级终端注册表 `{ws_id, name} → pid` |
| `lib/sigil/terminal/session.ex` | 单终端 owner GenServer，持有 Ghostty.Terminal + PTY |
| `lib/sigil/terminal/supervisor.ex` | DynamicSupervisor，管理 Session 生命周期 |
| `lib/sigil/tool/extension/terminal.ex` | ext__term_list / ext__term_output / ext__term_send |
| `lib/sigil_web/live/terminal_panel.ex` | LiveComponent：标签/创建/关闭/预置命令/活动指示 |
| `test/sigil/terminal/session_test.exs` | Registry 单元测试（7 个） |
| `test/sigil/tool/extension/terminal_test.exs` | 工具 + 权限测试（10 个） |

### 修改文件（7 个）

| 文件 | 变更 |
|------|------|
| `mix.exs` | + `{:ghostty, "~> 0.4"}` |
| `lib/sigil/agent.ex` | `run/2` 和 `resume` 中注册终端工具 |
| `lib/sigil/application.ex` | 挂载 Terminal.Registry + Terminal.Supervisor |
| `lib/sigil/permissions/tool_policy.ex` | + `@builtin_prompt_tools` 列表，ext__term_send 默认 prompt |
| `lib/sigil_web/live/workspace_live.ex` | + `toggle_terminal` handler + catch-all handle_info |
| `lib/sigil_web/live/workspace_live.html.heex` | 底部终端面板 + 状态栏 toggle 按钮 |
| `priv/static/assets/css/workspace.css` | 终端标签/状态点/活动脉冲 CSS |

### 前端文件（2 个）

| 文件 | 变更 |
|------|------|
| `assets/vendor/ghostty.js` | Ghostty 终端前端 hook（vendor 自 deps） |
| `assets/js/app.js` | 注册 GhosttyTerminal hook |

## 架构

```
Sigil.Supervisor
├─ Terminal.Registry    ← GenServer, {workspace_id, name} → pid
└─ Terminal.Supervisor  ← DynamicSupervisor (one_for_one)
     └─ Terminal.Session (per-terminal)
          ├─ Ghostty.Terminal (VT 仿真器，GenServer)
          └─ Ghostty.PTY (真实 PTY 子进程)

Web UI:
  WorkspaceLive
  ├─ 状态栏 "▸_ Terminal" 按钮 → toggle_terminal
  └─ 底部面板 (:if={@show_terminal})
       └─ TerminalPanel (LiveComponent)
            ├─ 标签栏（名称 + 状态点 + 活动指示点）
            ├─ 创建表单 + 预置命令
            ├─ 关闭/重启确认对话框
            └─ Ghostty.LiveTerminal.Component（终端渲染）
```

## 关键设计决策

1. **Session 为 owner process** — Ghostty 的 effect/output message 发给 `start_link` 调用者。Session 作为 owner 转发 PTY output → Terminal、Terminal effects → PTY。Supervisor 不直接管理 Terminal/PTY。

2. **cwd 包装** — Ghostty.PTY 无 cwd 选项，通过 `sh -c "cd <path> && exec <cmd> <args>"` 包装。

3. **macOS PTY close hang** — Ghostty.PTY.close/1 和 Process.exit(pty, :kill) 在 macOS aarch64 上 hang。Session.do_cleanup 跳过 PTY close，靠进程树自然清理。

4. **权限默认 prompt** — ext__term_send 通过 `@builtin_prompt_tools` 默认 `:prompt`，ext__term_list/output 默认 `:auto`。用户可在 `.sigil/settings.jsonc` 覆盖。

5. **底部面板布局** — 不再与文件面板切换，而是独立底部 dock（280px），状态栏按钮 toggle。

6. **输出持久化** — PTY 输出追加写入 `workspace/.sigil/terminals/<name>.log`。

## Review 关注点

### 高优先级
- [ ] **Terminal.Session 进程生命周期** — `init/1` 中 Registry 注册和 Ghostty 启动的失败场景是否完整处理
- [ ] **PTY 清理** — macOS hang 问题的替代方案是否安全（跳过 close，靠进程树）
- [ ] **cwd 安全** — `shell_escape/1` 和命令包装是否有注入风险
- [ ] **PubSub 主题隔离** — `"terminal:#{workspace_id}"` 是否正确隔离工作区
- [ ] **WorkspaceLive catch-all handle_info** — 是否可能吞掉重要消息
- [ ] **GhosttyTerminal hook** — `assets/vendor/ghostty.js` 版本是否与 deps 一致

### 中优先级
- [ ] **Register 接口设计** — `GenServer.call` 用于 lookup 是否应该 cache（频繁调用）
- [ ] **ext__term_send 审计** — 工具调用参数（terminal name + input）进入 transcript 但未做 input 截断
- [ ] **Supervisor list_terminals** — 通过 `Session.info(pid)` 同步调用所有 session，大量终端时性能
- [ ] **预置命令硬编码** — `@preset_commands` 是否应可配置
- [ ] **CSS 类名** — 与现有 BEM/utility 风格是否一致

### 低优先级
- [ ] **测试覆盖** — 缺少 PTY 集成测试（macOS hang 导致无法测试），建议添加 mock
- [ ] **移动端适配** — 底部面板在移动端是否可用
- [ ] **错误提示国际化** — gettext 未覆盖终端面板文本

## 测试命令

```bash
# 终端相关测试
mix test test/sigil/terminal/session_test.exs
mix test test/sigil/tool/extension/terminal_test.exs

# 权限测试
mix test test/sigil/permissions/

# 全量（排除 slow/e2e）
mix test --exclude slow --exclude e2e --exclude external_api
```

## 已知限制

- macOS aarch64: Ghostty.PTY close hang，依赖进程树清理
- PTY 集成测试因 hang 问题未覆盖
- 终端面板无 resize 拖拽（固定 280px）
- 移动端未适配

## 验证结果

浏览器实测通过：底部面板切换、预置命令创建、Ghostty 终端渲染、输出持久化、活动指示器。无 view crash。
