# Windows 支持

Sigil 的 `bash` tool 在 Windows 10/11 上通过 Git Bash（或 Cygwin/MSYS2）提供兼容的 bash 运行环境。

## 前置要求

安装 Git for Windows 即可：

```powershell
winget install --id Git.Git -e --source winget
```

或从 https://git-scm.com/download/win 下载安装。

> 其他兼容 shell 也会被自动检测：MSYS2 (`C:\msys64\usr\bin\bash.exe`)、Cygwin (`C:\cygwin64\bin\bash.exe`)、以及 PATH 上任何 `bash.exe`。

## Shell 查找顺序

`bash` tool 执行时，按以下优先级查找可用的 bash：

1. 用户在代码中显式指定 `shell_path` 参数
2. 工作区设置 `.sigil/settings.jsonc` 中的 `tools.bash.shellPath`
3. 全局设置 `~/.sigil/settings.json` 中的 `tools.bash.shellPath`
4. 应用配置 `config :sigil, :shell_path`
5. 自动检测：
   - `%ProgramFiles%\Git\bin\bash.exe`
   - `%ProgramFiles(x86)%\Git\bin\bash.exe`
   - PATH 上的 `bash.exe`（通过 `where bash.exe`）
6. 找不到 → 返回明确错误，包含安装指引

## 自定义 Shell 路径

### 工作区级别（推荐）

编辑 `<workspace>/.sigil/settings.jsonc`：

```jsonc
{
  "tools": {
    "bash": {
      "shellPath": "C:\\Program Files\\Git\\bin\\bash.exe"
    }
  }
}
```

### 全局级别

编辑 `~/.sigil/settings.json`：

```json
{
  "tools": {
    "bash": {
      "shellPath": "C:\\Program Files\\Git\\bin\\bash.exe"
    }
  }
}
```

### 应用级别

编辑 `config/config.exs`（需要重新编译）：

```elixir
config :sigil, :shell_path, "C:\\Program Files\\Git\\bin\\bash.exe"
```

## LLM 命令兼容性

Sigil 的 `bash` tool 从不对 LLM 暴露宿主 OS。工具名称为 `bash`，描述中明确要求使用 Unix 风格命令和 `/` 路径分隔符。因此 LLM 在任何平台（包括 Windows）都会输出 `ls`、`cat`、`grep` 等 bash 命令，不会输出 `dir`、`type` 等 Windows 原生命令。

> **为何不支持 cmd / PowerShell？** bash 命令（`ls | grep foo`、`export`、管道、重定向）无法可靠翻译为 Windows 原生命令。保持 bash 抽象层是最可靠的方式。

## 进程管理

| 操作 | macOS/Linux | Windows |
|------|------------|---------|
| Shell 二进制 | `/bin/bash` 或 PATH 上的 `bash` | Git Bash / Cygwin / MSYS2 的 `bash.exe` |
| 进程树终止 | `kill -9 -<pid>` | `taskkill /F /T /PID <pid>` |
| Port 执行 | `{:spawn_executable, bash}` | 同左 |

## 已知限制

- 未安装 Git for Windows 等 bash 环境时，`bash` tool 返回错误（而非 crash）
- WSL 不会自动检测；如需使用，在设置中手动配置 `shellPath` 指向 WSL bash 路径
- Windows Terminal 的 `Shift+Enter` / `Alt+Enter` 可能需要单独配置键位