# Sigil

[English](README.md) · [中文](README.zh.md)

本地 agent 助手。对话、工具、记忆都在本机；一套 OTP runtime，[LiveView](lib/sigil_web/live) 和 [Android](android/) 共用。

- 读、改、写文件，跑 shell，模糊搜文件
- 工作区权限（auto / prompt / deny）
- 流式回复和工具状态
- Anthropic / OpenAI 兼容协议（StepFun、DeepSeek、OpenRouter 等）
- MCP、BEAM 内省、跨会话记忆
- Android 共用同一套 Coordinator / Runner

需要 Elixir 1.20、OTP 28+、Node。

## 运行

```bash
cp models.example.json models.json   # 填 apiKey，或用 env:OPENAI_API_KEY
npm install
mix setup
mix phx.server                       # http://localhost:5002
```

选一个工作区即可聊天。前端资源不进 git，第一次要先 `mix setup`（或至少编过 assets），否则回复 markdown 出不来。

```bash
mix test --exclude slow --exclude e2e
```

## Android

```bash
cd android
mix deps.get
mix test
bash script/pack_android_apks.sh --abi arm64-v8a
```

说明见 [`android/README.md`](android/README.md)。ChromeOS 用 `--abi x86_64`。

## 许可

[AGPL-3.0](LICENSE)。Copyright (C) 2026 youfun。
