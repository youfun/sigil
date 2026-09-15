# Sigil Native Chat experiment

Mob 0.7.39 native controls. Android renders Jetpack Compose; iOS renders
SwiftUI. The chat and settings pages no longer embed LiveView or WebView.
Sigil runs on-device unchanged: Coordinator owns input, Runner owns tasks,
and ConversationTranscriptStore owns history. Phoenix remains available on
loopback for existing runtime services.

Implemented: text chat, streamed replies, tool status, stop, new/history chats,
notification conversation routing; add/edit provider/model, HTTPS base URL,
API protocol and masked API key input, workspace default model and reasoning.
Other settings and attachments are explicit placeholders. Markdown, OAuth login,
model deletion and workspace management are not part of this experiment.

API keys use the existing app-private `models.json` storage (not Keystore).
Existing keys are never prefilled, and blank edits retain them. Provider edits
affect every model belonging to that provider. No credentials are imported from
the original app.

See [AGENTS.md](AGENTS.md).

```bash
cd mobile
mix deps.get
mix test
```

## Android

Independent package: `com.example.sigil_probe.nativechat` (launcher: **Sigil Native**).
Does not replace or share data with `com.example.sigil_probe`.
Debug node: `:"sigil_probe_android_nativechat@127.0.0.1"`, Dist **9200**.
Inspect handlers using `Mob.Test` / `:rpc`; screenshots verify layout only.

ChromeOS ARC cannot `run-as`. Persist OTP with `mix mob.pack_apk --device arc:5555`,
then force-stop **only the nativechat package** and start
`com.example.sigil_probe.nativechat/com.example.sigil_probe.MainActivity`.

Pack debug APKs (one ABI per zip; same script locally and in CI):

```bash
cd mobile
bash script/pack_android_apks.sh                  # arm64-v8a + x86_64
bash script/pack_android_apks.sh --abi arm64-v8a  # phones
```

## iOS

Same Mix package (`:sigil_probe`) and the same `HomeScreen` / Coordinator /
Runner. Host tree is `ios/` (SwiftUI + `sigil_ios` NIF). Bundle id:
`com.example.sigil_probe` (launcher: **SigilProbe**). Needs macOS, Xcode, and
the Zig pin used by Mob native (see `.tool-versions`).

```bash
cd mobile
mix ios.native                         # Simulator; alias for mob.deploy --native --ios
mix ios.native --device <udid>         # a specific simulator or device
```

`mix ios` is BEAM-only (`mob.deploy --ios`). Prefer `mix ios.native` for a
full host rebuild.

Simulator Dist cookie is `:mob_secret`. Node name is
`:"sigil_probe_ios_<8-char-udid>@127.0.0.1"` (first 8 hex chars of the UDID,
lowercase, no dashes). Bare `:"sigil_probe_ios@127.0.0.1"` is only the
fallback when no UDID is known. `mix mob.connect` often hangs; ping from a
named node instead:

```elixir
node = :"sigil_probe_ios_8d4e9af7@127.0.0.1"   # example; match the booted sim
Node.ping(node)
Mob.Test.screen(node)
Mob.Test.assigns(node)
```

Photo pick, export open/share, and in-app file preview run through
`SigilProbe.Platform.IOS` (controlled import, snapshot registry, stock Mob
nodes). Tests must not load Android NIFs; iOS NIF failures stay errors, not
`:ok`.