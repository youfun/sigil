# Sigil Usage Guide

> Self-hosted AI Coding Assistant — Elixir/Phoenix + SQLite3

## 1. Overview

Sigil is a **local-first** AI coding assistant running on the BEAM VM (Erlang/Elixir). It provides an interactive programming experience through a **Phoenix LiveView Web Workbench**, supports multiple LLM providers (Anthropic Claude, OpenAI, DeepSeek, StepFun, ZenMux, and more), and includes a comprehensive tool system for file I/O, command execution, code search, memory management, BEAM runtime introspection, and cross-session operations.

### Key Features

| Feature | Description |
|---------|-------------|
| Multi-Provider | Unified interface for Claude / GPT / DeepSeek / ZenMux / OpenRouter / StepFun |
| Local-First | All data, config, and tool execution runs locally. No cloud dependency. |
| Extensible Tools | Built-in file/shell/search tools, BEAM introspection, MCP protocol extensions, terminal tools |
| Workspace Permissions | File access confined to workspace, configurable tool approval policies (auto/deny/prompt) |
| Multi-Channel | LiveView / CLI / Webhook / SNS unified entry point |
| Streaming UX | Real-time streaming Markdown rendering with typewriter animation |
| Memory System | Cross-session fact/pattern/preference memory (short-term → long-term) |
| Cross-Session Ops | List sessions, capture transcripts, send steer messages — like `tmux` for agents |
| AGENTS.md Aware | Auto-discovers and injects project-level `AGENTS.md` instructions into prompts |
| Diff Review & Revert | View file changes in diff viewer, revert on file-hash validation |
| Reasoning Levels | Configurable thinking levels (off/minimal/low/medium/high/xhigh) per model |
| Context Compaction | Automatic summarization when approaching token limits |
| Skills System | YAML-frontmatter Markdown skill files injected into system prompt |

### Product Positioning

Sigil is currently a **WebUI-first coding-agent MVP**, suitable for:

- **Personal use** — coding tasks on real local repositories
- **Small-team dogfooding** — controlled collaboration & debugging
- **Moderate coding work** — on Git-revertible repos

The WebUI main path covers: workspace selection, agent runs, streaming display, tool event cards, file read/write/edit, command execution, transcript persistence, model switching, diff viewing, and diff revert.

> ⚠️ **Usage boundaries**: Not recommended for external users or unattended heavy use. Tool approval UI / Runner resume UI are still in development. Always keep your repo under Git for easy rollback.

## 2. Quick Start

### 2.1 Requirements

| Dependency | Minimum Version |
|------------|----------------|
| Elixir | >= 1.20.0-rc.5 |
| Erlang / OTP | >= 28 |
| SQLite3 | System-installed |

### 2.2 Install & Launch

```bash
cd sigil
mix deps.get
mix ecto.create && mix ecto.migrate
mix phx.server
```

Visit **http://localhost:5002** after startup.

Custom port via environment variable:

```bash
PORT=8080 mix phx.server
```

## 3. Configuration Files 🔑

Sigil uses a three-layer configuration system. Understanding each layer is essential.

### 3.1 Global Model Config (`models.json`)

**Path: `~/.sigil/models.json`**

This is the most important config file. Without it, Sigil cannot call any LLM.

Override path via `SIGIL_MODELS_FILE` env var.

```json
{
  "defaultProvider": "stepfun",
  "defaultModel": "step-router-v1",
  "providers": {
    "stepfun": {
      "baseUrl": "https://api.stepfun.com/step_plan/v1",
      "api": "stepfun-step-plan",
      "apiKey": "env:MY_STEPFUN_KEY",
      "provider": "stepfun",
      "models": [
        { "id": "step-router-v1", "name": "Step Router v1" }
      ]
    },
    "openai": {
      "baseUrl": "https://api.openai.com/v1",
      "api": "openai-chat-completions",
      "apiKey": "env:OPENAI_API_KEY",
      "provider": "openai",
      "models": [
        { "id": "gpt-4o", "name": "GPT-4o" },
        { "id": "gpt-4o-mini", "name": "GPT-4o Mini" }
      ]
    },
    "deepseek": {
      "baseUrl": "https://api.deepseek.com",
      "api": "openai-chat-completions",
      "apiKey": "sk-your-deepseek-key",
      "provider": "deepseek",
      "models": [
        { "id": "deepseek-chat", "name": "DeepSeek Chat" }
      ]
    },
    "anthropic": {
      "baseUrl": "https://api.anthropic.com",
      "api": "anthropic-messages",
      "apiKey": "env:ANTHROPIC_API_KEY",
      "provider": "anthropic",
      "models": [
        { "id": "claude-sonnet-4-20250514", "name": "Claude Sonnet 4" }
      ]
    },
    "zenmux": {
      "baseUrl": "https://openai.zenmux.ai/v1",
      "api": "openai-chat-completions",
      "apiKey": "env:ZENMUX_API_KEY",
      "provider": "zenmux",
      "models": [
        { "id": "openai/gpt-5", "name": "ZenMux GPT-5" }
      ]
    },
    "openrouter": {
      "api": "openai-chat-completions",
      "apiKey": "env:OPENROUTER_API_KEY",
      "provider": "openrouter",
      "models": [
        { "id": "openai/gpt-4o", "name": "OpenRouter GPT-4o" }
      ]
    }
  }
}
```

**`api` field → Provider module mapping:**

| api value | Provider Module | Notes |
|-----------|----------------|-------|
| `"stepfun"` / `"stepfun-step-plan"` | StepFun | StepFun Plan mode |
| `"openai-chat-completions"` | OpenAI | Standard Chat Completions API |
| `"openai"` / `"openai-responses"` | OpenAI Responses | OpenAI Responses API |
| `"anthropic-messages"` | Anthropic | Claude Messages API |

**`apiKey` formats:**
- `"env:VAR_NAME"` → read from environment variable (**recommended**)
- `"sk-xxx..."` → plaintext key (not recommended)

> ⚠️ `OPENAI_API_KEY` etc. are NOT implicitly used — must be declared in `models.json`.

### 3.2 Global Settings (`settings.json`)

**Path: `~/.sigil/settings.json`**

Stores global Model/AI preferences (default model, reasoning level, observational memory settings). Can be managed via the Web Settings page (`/settings`).

Override path via `SIGIL_GLOBAL_SETTINGS_FILE` env var.

```json
{
  "model_ai": {
    "default_model": "stepfun/step-router-v1",
    "reasoning": "off",
    "om_enabled": false
  }
}
```

### 3.3 Workspace Settings (`settings.jsonc`)

**Path: `<workspace>/.sigil/settings.jsonc`**

JSONC format (supports `//` comments). Auto-created on first workspace use.

> ⚠️ **Note: The Web UI Settings panel is read-only placeholder** (shows workspace/model/status/session/MCP info). All tool permission config must be done by manually editing `.sigil/settings.jsonc`.

```jsonc
{
  // Restrict available models in this workspace (empty = no restriction)
  "models": {
    "allow": {
      "providers": {
        "stepfun": { "models": ["step-router-v1"] }
      }
    }
  },

  // Tool permission control (manual JSON editing, no UI yet)
  "tools": {
    // Default approval mode: "auto" | "prompt" | "deny"
    "default_mode": "auto",

    // Allowlist pattern matching
    "allow": ["read", "write", "edit", "file_search"],

    // Denylist pattern matching
    "deny": ["bash(rm:*)", "bash(sudo:*)"],

    // Per-tool approval mode
    "per_tool": {
      "bash": "prompt",
      "edit": "prompt"
    },

    // BEAM extension tool toggles
    "beam": {
      "auto": true,
      "eval": false
    },
    "explicit": []
  }
}
```

**Three approval modes:**

| Mode | Behavior | Status |
|------|----------|--------|
| `auto` | Tool executes directly, no user confirmation | ✅ Fully available |
| `deny` | Tool call intercepted, returns error, not executed | ✅ Fully available |
| `prompt` | Backend generates interrupt event, waits for user approval | ⚠️ Backend done, approval card UI pending |

**`allow`/`deny` pattern matching syntax:**

| Syntax | Rule | Example |
|--------|------|---------|
| `"tool_name"` | Exact tool name match | `"bash"` matches all bash calls |
| `"prefix_*"` | Wildcard match | `"mem_*"` matches `mem_recall`, `mem_learn`, etc. |
| `"tool(arg:*)"` | Match tool + argument value | `"bash(rm:*)"` matches commands containing `rm` |
| `"edit(.env)"` | Match tool + file path | `"edit(.env)"` matches edits to `.env` files |

> Pattern matching logic (`Sigil.Permissions.Matcher`) is unit-tested. Edit `.sigil/settings.jsonc` and restart or next run will take effect.

---