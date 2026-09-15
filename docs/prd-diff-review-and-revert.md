# PRD — WebUI Diff Review + Revert Controls

日期：2026-05-17  
产品：Sigil（Elixir/Phoenix LiveView，本地 Web UI）  
范围：`sigil/`（Workspace 工作台、文件工具结果、transcript/projection）

---

## 1. 背景

当前 Workspace 右侧 diff 区域只支持查看工具返回的 `diff_lines`：

- `edit` 工具会在成功修改后返回 `file_path` 与结构化 `diff_lines`。
- WebUI 支持在工具事件上点击 `Show diff`，右侧展示增删行。
- diff 面板只有 `Close`，没有撤销、回滚、接受、标记已处理等动作。
- `write` 工具当前只返回 `file_path/bytes/lines`，不返回 diff，也没有保存覆盖前内容。

这导致 WebUI coding-agent 场景缺少关键安全感：用户可以看到 Agent 改了什么，但不能在同一界面里快速撤销这次工具造成的修改。

---

## 2. 目标与非目标

### 2.1 目标（Must）

1. WebUI 能展示 agent 对文件造成的变更，并明确区分“可撤销 / 不可撤销”。
2. 对 `edit` 和 `write` 造成的文件变更，保存足够的 before/after 变更快照，用于可靠撤销。
3. diff 面板提供单次变更的 `Revert` 控件，用户确认后恢复该工具调用前的文件内容。
4. 撤销动作必须受 workspace 边界、symlink 逃逸检查、文件状态检查保护。
5. 撤销结果写入 timeline/transcript，用户能复盘“谁在什么时候撤销了哪个文件”。
6. 页面刷新或切换会话后，仍能看到历史 diff 与撤销状态。

### 2.2 目标（Should）

1. 对已被后续修改的文件，撤销前提示冲突，避免静默覆盖用户或 agent 的后续改动。
2. 支持从工具事件卡片和右侧 diff 面板两个入口打开同一个 change review。
3. 支持新建文件的撤销：删除该工具创建的文件。
4. 支持覆盖写入的撤销：恢复覆盖前内容。

### 2.3 非目标（Not Now）

- 按 hunk 接受/拒绝局部 diff。
- 多文件批量撤销。
- Git 集成式回滚、自动创建 commit、自动 stash。
- Monaco/CodeMirror 级别的代码编辑器集成。
- 解决所有外部进程修改文件的问题；本功能只覆盖 Sigil 工具可记录的变更。

---

## 3. 用户故事

- 我让 Agent 修改一个文件后，希望在右侧看到 diff，并能一键撤销这次修改。
- 我让 Agent 覆盖写入一个文件后，希望能恢复到覆盖前状态。
- Agent 创建了一个新文件，但我不满意，希望从 WebUI 删除这个新文件并标记该变更已撤销。
- 如果文件在 diff 生成后又被我手动改过，希望系统提醒我“当前文件已变化”，不要直接覆盖。
- 我刷新页面后，希望还能看到历史变更、撤销按钮状态、撤销记录。

---

## 4. 当前实现观察

### 4.1 WebUI

- `SigilWeb.WorkspaceLive.handle_event("view_diff", ...)` 从 timeline entry 读取 `file_path` / `diff_lines`。
- 右侧 `#diff-view` 只渲染 `@diff_lines`，并提供 `close_diff`。
- `maybe_add_diff_editor_file/3` 会把有 diff 的文件加入右侧 tab。

### 4.2 Tool

- `Sigil.Tool.Builtin.Edit`：
  - 成功后写文件。
  - 返回 `diff_lines` 和 `diff_first_changed_line`。
  - 没有返回 before content、after content、before hash、after hash。
- `Sigil.Tool.Builtin.Write`：
  - 成功后写文件。
  - 返回 `file_path/bytes/lines`。
  - 没有返回 diff，也没有记录覆盖前是否存在。

### 4.3 关键约束

`diff_lines` 经过上下文裁剪，不能作为可靠撤销来源。撤销必须依赖完整 before snapshot 或可验证的 inverse operation。

---

## 5. 功能规格

### 5.1 Change Snapshot

新增工具变更详情结构，挂在 tool result `details` 中，并进入 transcript：

```elixir
%{
  change_id: "chg_<uuid>",
  change_type: "edit" | "write",
  file_path: "/abs/path/file.ex",
  existed_before: true | false,
  before_sha256: "hex" | nil,
  after_sha256: "hex",
  before_content: "..." | nil,
  after_content: "...",
  diff_lines: [%{"type" => "del" | "ins" | "eq" | "skip", "text" => "..."}],
  reversible: true | false,
  revert_status: "available" | "reverted" | "conflict" | "unavailable",
  revert_reason: nil | "too_large" | "binary" | "missing_snapshot" | "outside_workspace"
}
```

Rules:

- Text files up to the existing tool size limit are reversible.
- Binary files are not reversible in MVP.
- If a file did not exist before `write`, `before_content=nil` and `existed_before=false`; revert deletes the file.
- If a file existed before `write`, store full before and after content.
- If snapshot content would exceed configured limits, set `reversible=false` with `revert_reason`.

### 5.2 Diff Panel

Right panel states:

1. `No file selected`
2. `File preview`
3. `Diff review`
4. `Revert confirmation`
5. `Revert result / conflict`

Diff review header:

- file basename
- change type (`edit` / `write`)
- status badge (`Available`, `Reverted`, `Conflict`, `Not reversible`)
- action buttons:
  - `Revert`
  - `Close`

`Revert` button:

- Hidden or disabled when `reversible=false`.
- Disabled after successful revert.
- Opens confirmation state before writing files.

### 5.3 Revert Semantics

Before reverting:

1. Validate `file_path` stays inside current workspace.
2. Resolve symlinks and reject workspace escape.
3. Read current file state if it exists.
4. Compare current SHA-256 to `after_sha256`.

Cases:

| Case | Behavior |
|------|----------|
| Current hash equals `after_sha256`, existed_before=true | Write `before_content` back |
| Current hash equals `after_sha256`, existed_before=false | Delete file |
| Current hash differs | Do not modify file; mark conflict and show explanation |
| File missing but existed_before=true | Conflict; do not recreate silently |
| File missing and existed_before=false | Mark reverted/no-op |
| Path invalid/outside workspace | Reject |

### 5.4 Timeline / Transcript

When revert succeeds or conflicts, append a system/tool-style timeline event:

- `content_type: "change_revert"`
- `change_id`
- `file_path`
- `status: "reverted" | "conflict" | "error"`
- `message`
- `timestamp`

The original tool entry should also reflect updated `revert_status` when restored from transcript.

### 5.5 Copy and Tone

Use direct labels:

- `Revert`
- `Confirm revert`
- `Reverted`
- `File changed since this diff`
- `This change is not reversible`

Avoid implying Git-level rollback. This feature reverts the recorded tool change only.

---

## 6. Data and Persistence Design

### 6.1 Preferred Storage

Store change snapshot metadata in the tool event details already flowing through:

`Tool result details → TranscriptPersistence → ConversationTranscriptStore messages.jsonl → WorkspaceLive projection`

Pros:

- Survives refresh and conversation reload.
- Keeps the change attached to the exact tool call.
- Avoids introducing a second store before the workflow stabilizes.

### 6.2 Snapshot Size Guard

Configuration defaults:

- `max_revert_snapshot_bytes = 1_000_000`
- `max_diff_lines_for_ui = existing clipped diff behavior`

For files above snapshot limit:

- still show diff if available
- set `reversible=false`
- show “This change is not reversible because the snapshot is too large.”

### 6.3 Future Store

If transcript size becomes a problem, move snapshots to:

`<workspace>/.sigil/change_snapshots/<conversation_id>/<change_id>.json`

The transcript then stores only `snapshot_ref`.

---

## 7. Implementation Plan

### Phase 1 — Snapshot Foundation

1. Add `Sigil.ChangeSnapshot` helper:
   - `sha256/1`
   - `build_edit_snapshot/4`
   - `build_write_snapshot/4`
   - `reversible?/1`
2. Update `Sigil.Tool.Builtin.Edit`:
   - capture full normalized/restored before and after text
   - include `change_id`, hashes, before/after content, `reversible`
3. Update `Sigil.Tool.Builtin.Write`:
   - read existing file before write if present
   - compute diff for text content
   - include snapshot fields
4. Add unit tests for snapshot shape and non-reversible cases.

### Phase 2 — WebUI Review State

1. Replace `@diff_lines`-only state with `@active_change`.
2. Update `view_diff` to load full change details from timeline entry.
3. Render status badge and `Revert` button.
4. Keep existing `diff_lines` rendering compatible for old transcript entries.

### Phase 3 — Revert Action

1. Add `handle_event("confirm_revert_change", ...)`.
2. Add `handle_event("revert_change", %{"change_id" => id}, socket)`.
3. Implement revert service, e.g. `Sigil.ChangeReverter.revert(change, workspace_root)`.
4. Append revert result to timeline/transcript.
5. Update original change status in current projection.

### Phase 4 — Recovery and E2E

1. Verify reload restores:
   - diff lines
   - active file tab
   - reversible status
   - reverted/conflict status
2. Add LiveView tests for:
   - edit revert success
   - write-created-file revert deletes file
   - write-overwrite revert restores previous content
   - conflict when current hash differs
   - old diff entries without snapshot remain review-only

---

## 8. Acceptance Criteria

MVP is complete when:

1. A successful `edit` tool call shows a diff and a working `Revert` button.
2. Reverting an `edit` restores the exact previous text when file hash still matches `after_sha256`.
3. A `write` that creates a file can be reverted by deleting that file.
4. A `write` that overwrites a file can be reverted by restoring previous content.
5. If the file changed after the tool call, revert is blocked with a visible conflict message.
6. Refreshing the browser preserves diff visibility and revert status via transcript reload.
7. Old transcript entries with only `diff_lines` continue to render as review-only.
8. Revert never writes outside the workspace, including symlink escape cases.

### 8.1 Implementation Status

MVP implemented on 2026-05-17:

- `edit` and `write` now emit reversible change snapshots for text changes.
- WebUI diff review now supports `Revert` with confirmation.
- Revert validates the current file hash before writing/deleting.
- Conflict, reverted, and review-only states are rendered in the diff panel.
- Focused unit and LiveView tests cover edit revert, created-file delete, overwrite restore, conflict handling, and legacy review-only behavior.

---

## 9. Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Transcript bloat from before/after content | Snapshot byte limit; future snapshot file store |
| Reverting over user changes | Hash check against `after_sha256`; conflict instead of overwrite |
| Diff is clipped and cannot reverse | Use full snapshot, not UI diff, as source of truth |
| Binary or large files | Mark non-reversible in MVP |
| Symlink path escape | Reuse `PathValidator.validate_within_workspace/2` before every revert |
| Old messages lack snapshots | Render as review-only |

---

## 10. Open Questions

1. Should `Revert` be available only when the agent run is idle, or also while a run is active?
2. Should a successful revert send a follow-up user-visible message to the agent context, or only write transcript/UI state?
3. Should revert actions be exposed to the model as tool results, or remain strictly user-side UI actions?
4. Should snapshot content be redacted before transcript persistence if files contain secrets, or should revert snapshots move directly to local snapshot files?

Recommended initial decisions:

- Disable revert while `running=true`.
- Record revert in transcript but do not inject it into the model conversation for MVP.
- Keep snapshots local; add byte limits now and evaluate file-backed snapshot storage before external users.
