# KB: PhoenixTest Feature Patterns

> 适用于 Sigil 当前 Phoenix/LiveView UI 层测试。PhoenixTest 只覆盖用户可见行为，不覆盖 Agent Runtime、Tool、Memory、Security 等后端契约。

## 项目现状

- PhoenixTest 版本：`~> 0.10.0`
- 配置入口：`config/test.exs`
- 测试基类：`SigilWeb.FeatureCase`
- 当前 feature 测试目录：`test/feature/`
- 当前主测试文件：`test/feature/workspace_feature_test.exs`

`SigilWeb.FeatureCase` 已导入：

```elixir
use SigilWeb, :verified_routes
import PhoenixTest
@endpoint SigilWeb.Endpoint
```

测试中直接从 `%{conn: conn}` 开始：

```elixir
conn
|> visit("/")
|> assert_has("#ai-panel")
```

## 测试边界

PhoenixTest 用来验证浏览器用户能看到和完成的流程：

| 场景 | 推荐测试 |
|------|----------|
| 路由可访问、页面可挂载 | PhoenixTest |
| Workspace 三栏布局、状态栏、空状态 | PhoenixTest |
| 输入消息、点击按钮、消息出现在聊天区 | PhoenixTest |
| 新建会话、归档按钮、回收站入口等 UI 流程 | PhoenixTest |
| 下拉框、输入框、按钮等可见交互 | PhoenixTest |
| Agent loop、Provider、Tool Registry | ExUnit |
| PubSub 事件、Session 快照/回放 | ExUnit |
| Memory、Security、PathValidator、ShellPathGuard | ExUnit |
| LiveView 内部 assigns、handle_info、push_event | Phoenix.LiveViewTest |

原则：PhoenixTest 写“用户视角”的断言，不直接测试内部实现细节。内部状态、纯函数和跨模块契约放在 `test/sigil/**` 或 `test/sigil_web/**` 的 ExUnit/LiveViewTest。

## 文件结构

当前保持简单：

```text
test/feature/
└── workspace_feature_test.exs
```

后续页面增多时再按功能拆分：

```text
test/feature/
├── workspace_feature_test.exs
├── settings_feature_test.exs
└── extensions_feature_test.exs
```

命名建议：`<area>_feature_test.exs`。不要沿用其他项目的 `master_data/`、`trade/`、`finance/` 等业务目录。

## 基础模板

```elixir
defmodule SigilWeb.Feature.SomeFeatureTest do
  use SigilWeb.FeatureCase, async: false

  describe "some page" do
    test "renders expected UI", %{conn: conn} do
      conn
      |> visit("/")
      |> assert_has("h2", "专案")
      |> assert_has("#ai-panel")
      |> assert_no_error_flash()
    end
  end
end
```

Sigil 的 Workspace 测试通常使用 `async: false`，因为部分流程会触碰本地会话存储、环境变量或 PubSub 状态。只有确认测试完全隔离后再改成 `async: true`。

## 常用写法

### 页面和元素断言

```elixir
conn
|> visit("/")
|> assert_path("/")
|> assert_has("#activity-bar")
|> assert_has("#editor-group")
|> assert_has("#ai-panel")
|> assert_has("#status-label", "idle")
```

优先选择稳定 selector：

- 已有 DOM id：`#ai-panel`、`#status-bar`、`#model-picker`
- 行为相关属性：`button[phx-click='new_conversation_in_workspace']`
- 必要时再用可见文本：`assert_has("button", "New chat")`

### 输入和点击

```elixir
conn
|> visit("/")
|> fill_in("#ai-input", "消息", with: "Hello, world!", exact: false)
|> click_button("Send")
|> assert_has(".msg-bubble.msg-user", "Hello, world!")
```

Sigil 当前输入框可能同时依赖 selector 和 label，因此可沿用现有写法：

```elixir
fill_in("#ai-input", "消息", with: "Read config file", exact: false)
```

### 否定断言

```elixir
conn
|> visit("/")
|> fill_in("#ai-input", "消息", with: "   ", exact: false)
|> click_button("Send")
|> refute_has(".msg-bubble.msg-user")
```

### 限定作用域

当页面上有多个同名按钮或重复列表时，用 `within/2` 缩小范围：

```elixir
conn
|> visit("/")
|> within(".workspace-group:first-child .conversations-list", fn session ->
  session
  |> click_button("button[phx-click='archive_conversation']", "")
end)
```

## Workspace 重点覆盖

当前 `workspace_feature_test.exs` 已覆盖这些用户行为：

- 页面挂载后显示三栏布局：`#activity-bar`、`#editor-group`、`#ai-panel`
- 状态栏显示模型、token、session、状态
- 空消息状态显示
- 发送消息后聊天区出现用户消息
- 发送后输入框清空
- 空白消息不会新增聊天气泡
- 模型选择器可见
- 新建会话按钮可见并能重置界面
- 归档按钮可见，归档后会话从活跃列表移除
- 回收站入口可见

新增 Workspace UI 行为时，优先在这个文件里补一条用户流测试。若只是改内部函数，优先写普通 ExUnit。

## 涉及本地存储的测试

归档、恢复等流程会写 `Sigil.ConversationStore`。测试中应使用临时文件隔离：

```elixir
setup do
  store_file =
    Path.join(
      System.tmp_dir!(),
      "sigil_feature_test_#{System.unique_integer([:positive])}.json"
    )

  System.put_env("SIGIL_CONVERSATIONS_FILE", store_file)

  on_exit(fn ->
    System.delete_env("SIGIL_CONVERSATIONS_FILE")
    dir = Sigil.ConversationStore.storage_dir()
    if File.exists?(dir), do: File.rm_rf!(dir)
  end)

  :ok
end
```

注意：这种测试不要 `async: true`，避免环境变量和文件路径互相影响。

## 文件上传测试

有页面引入上传能力时，优先用 PhoenixTest 覆盖用户可见流程：

- 文件 input 或上传按钮可见
- 选择文件后页面出现文件名、进度或待上传状态
- 点击提交后出现成功/失败反馈
- 上传结果出现在列表、详情、预览区或其他用户可见区域

不要只断言 flash。上传成功后应继续断言 UI 上能看到上传结果。

### 推荐组件约定

为了让 PhoenixTest 能直接定位上传控件，上传组件应尽量满足：

- `<label>` 文案稳定，例如 `"上传文件"`、`"选择文件"`、`"添加文件"`
- label 通过 `for` 关联到 file input
- file input 不依赖浏览器 JS 才能创建
- 上传完成后有稳定 selector 可断言，例如 `#files-list`、`.uploaded-file`

推荐结构示例：

```heex
<label for={@uploads.files.ref}>上传文件</label>
<.live_file_input upload={@uploads.files} />
```

### PhoenixTest 写法

```elixir
conn
|> visit("/")
|> upload("上传文件", "test/fixtures/sample.txt")
|> click_button("保存")
|> assert_has(".uploaded-file", "sample.txt")
|> assert_no_error_flash()
```

如果 label 含有额外说明或必填标记，可放宽匹配：

```elixir
upload(session, "上传文件", "test/fixtures/sample.txt", exact: false)
```

同一页面有多个上传入口时，用 selector 和 `within/2` 消歧：

```elixir
conn
|> visit("/")
|> within("#file-uploader", fn session ->
  session
  |> upload("上传文件", "test/fixtures/sample.txt")
  |> click_button("保存")
end)
|> assert_has("#files-list", "sample.txt")
```

### hidden input 或 JS hook 上传

PhoenixTest 不执行真实浏览器 JavaScript。如果上传入口是 hidden input，并且完全依赖 JS hook 点击触发，`upload/3` 可能无法定位。

这种场景优先调整组件结构，让 label 和 input 保持可测试关联。确实需要测试 LiveView 上传底层行为时，改用 `Phoenix.LiveViewTest`：

```elixir
{:ok, view, _html} = live(conn, "/")

file =
  file_input(view, "form", :files, [
    %{
      name: "sample.txt",
      content: "hello",
      type: "text/plain"
    }
  ])

render_upload(file, "sample.txt")
```

### 上传常见踩坑

| 问题 | 处理方式 |
|------|----------|
| `upload` 找不到控件 | 检查 label 文案和 `for` 是否关联到 file input |
| hidden input 无法被 PhoenixTest 操作 | 优先改组件可访问性；否则用 LiveViewTest |
| 文件类型被拒绝 | 使用 `allow_upload` 允许的 fixture，或专门断言拒绝行为 |
| 上传后 UI 无变化 | 确认是否还需要点击提交按钮 |
| 测试依赖大文件 | 放小 fixture 到 `test/fixtures/`，避免提交真实大文件 |

## PhoenixTest 不适合的场景

PhoenixTest 不执行真实浏览器 JavaScript。以下情况不要硬塞 PhoenixTest：

- 需要验证 JS hook、拖拽、复杂键盘事件
- 需要读取 `socket.assigns`
- 需要直接触发 `handle_info`
- 需要断言 `push_event`
- 需要隔离测试 LiveComponent 内部事件

这些场景改用 `Phoenix.LiveViewTest`，或把可测试逻辑下沉到普通模块后用 ExUnit 覆盖。

## 常见踩坑

| 问题 | 处理方式 |
|------|----------|
| 同名按钮点错 | 用 `within/2` 或更具体 selector |
| 文案变化导致测试脆弱 | 对结构用 id/属性，对用户可见语义才断言文本 |
| 只断言按钮存在但没验证结果 | 点击后继续断言 UI 状态变化 |
| 测试依赖会话存储 | 使用 `SIGIL_CONVERSATIONS_FILE` 指向临时文件 |
| 测试间互相影响 | 清理 env 和临时目录，必要时保持 `async: false` |
| 想验证内部 Agent 状态 | 改写 `test/sigil/agent/**` ExUnit |

## 运行命令

```bash
mix test test/feature/workspace_feature_test.exs
mix test test/feature
mix test
```

改 feature 测试后至少运行对应文件。涉及共享 UI、LiveView mount 或会话存储时，再运行 `mix test test/feature`。
