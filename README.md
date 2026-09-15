# Sigil

[English](README.md) · [中文](README.zh.md)

A local agent assistant. Chat, tools, and memory stay on the machine. One OTP runtime is shared by [LiveView](lib/sigil_web/live) and [Android](android/).

- Read, edit, and write files; run a shell; fuzzy-search files
- Workspace permissions (auto / prompt / deny)
- Streaming replies and tool status
- Anthropic and OpenAI-compatible APIs (StepFun, DeepSeek, OpenRouter, and others)
- MCP, BEAM introspection, and memory across sessions
- Same Coordinator / Runner on Android

Requires Elixir 1.20, OTP 28+, and Node.

## Run

```bash
cp models.example.json models.json   # set apiKey, or use env:OPENAI_API_KEY
npm install
mix setup
mix phx.server                       # http://localhost:5002
```

Pick a workspace and chat. Frontend assets are not in git. Run `mix setup` (or at least build assets) once, or replies look like unrendered markdown.

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

See [`android/README.md`](android/README.md). On ChromeOS use `--abi x86_64`.

## License

[AGPL-3.0](LICENSE). Copyright (C) 2026 youfun.
