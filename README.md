# Sigil

[English](README.md) · [中文](README.zh.md)

A local agent assistant. Chat, tools, and memory stay on the machine. One OTP runtime is shared by [LiveView](lib/sigil_web/live) and [mobile](mobile/) (Android + iOS).

- Read, edit, and write files; run a shell; fuzzy-search files
- Workspace permissions (auto / prompt / deny)
- Streaming replies and tool status
- Anthropic and OpenAI-compatible APIs (StepFun, DeepSeek, OpenRouter, and others)
- MCP, BEAM introspection, and memory across sessions
- Same Coordinator / Runner on Android and iOS

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

## Mobile (Android + iOS)

```bash
cd mobile
mix deps.get
mix test
bash script/pack_android_apks.sh --abi arm64-v8a   # Android
mix ios.native                                     # iOS Simulator (Xcode)
```

See [`mobile/README.md`](mobile/README.md). On ChromeOS use `--abi x86_64`.
iOS bundle id is `com.example.sigil_probe`; the simulator Dist node is
`sigil_probe_ios_<first-8-udid>@127.0.0.1`.

## License

[AGPL-3.0](LICENSE). Copyright (C) 2026 youfun.
