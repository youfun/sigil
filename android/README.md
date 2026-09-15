# Sigil Native Chat experiment

Mob 0.7.39 native controls rendered by Android Compose. The chat and settings
pages no longer embed LiveView or WebView. Sigil runs on-device unchanged:
Coordinator owns input, Runner owns tasks, and ConversationTranscriptStore owns
history. Phoenix remains available on loopback for existing runtime services.

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
cd android
mix deps.get
mix test
```

Independent package: `com.example.sigil_probe.nativechat` (launcher: **Sigil Native**).
Does not replace or share data with `com.example.sigil_probe`.
Debug node: `:"sigil_probe_android_nativechat@127.0.0.1"`, port 9200.
Inspect handlers using `Mob.Test` / `:rpc`; screenshots verify layout only.

ChromeOS ARC cannot `run-as`. Persist OTP with `mix mob.pack_apk --device arc:5555`,
then force-stop **only the nativechat package** and start
`com.example.sigil_probe.nativechat/com.example.sigil_probe.MainActivity`.

Pack debug APKs (one ABI per zip; same script locally and in CI):

```bash
cd android
bash script/pack_android_apks.sh                  # arm64-v8a + x86_64
bash script/pack_android_apks.sh --abi arm64-v8a  # phones
```
