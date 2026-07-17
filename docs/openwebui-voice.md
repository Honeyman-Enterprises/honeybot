# Open WebUI voice / Call mode

Hands-free voice conversation in the Open WebUI GUI — like Claude/ChatGPT
voice — talking to honeybot with your selected model.

## The shape (Open WebUI does the UI)

Open WebUI already ships the voice UI: mic input, read-aloud, and a
hands-free **Call mode** that loops STT → LLM → TTS. We don't build a voice
UI — we configure the audio layer and point it at a provider.

```
🎙 mic ── STT (speech→text) ─┐
                             ├─► honeybot api_server  (selected model: sonnet / gpt / …)
🔊 out ◄─ TTS (text→speech) ─┘
```

- **Brain (LLM)** — unchanged. The chat model stays selectable via the model
  dropdown (the `model-prefix-router` routes sonnet vs gpt through honeybot's
  api_server). Call mode uses whatever's selected. "Default + selectable" for
  the model is already done.
- **Ears + mouth (STT/TTS)** — this doc. Default provider: **OpenAI**.

## The gotcha (why base URLs are explicit)

Open WebUI's audio config *defaults* `AUDIO_STT/TTS_OPENAI_API_BASE_URL` to
`OPENAI_API_BASE_URL` and the key to `OPENAI_API_KEY`. In our stack those
point at the **auth-bridge → honeybot api_server** — a chat-only adapter
that has no `/audio/transcriptions` or `/audio/speech`, and whose "key" is
the api_server bearer, not a real OpenAI key. Left default, voice would POST
to honeybot and fail.

So the audio layer is pointed **directly at OpenAI**:
- `AUDIO_STT/TTS_OPENAI_API_BASE_URL = https://api.openai.com/v1` (compose)
- `AUDIO_STT/TTS_OPENAI_API_KEY = op://Honeybot/OpenAI/key` (the real key,
  via `.env.runtime` — the same key honeybot uses for vision).

Clean split: **audio → OpenAI directly; chat → honeybot.**

## What's wired

| Where | Vars |
|---|---|
| `docker-compose.yml` (openwebui `environment:`) | `AUDIO_STT_ENGINE=openai`, `AUDIO_STT_MODEL=whisper-1`, `AUDIO_STT_OPENAI_API_BASE_URL`, `AUDIO_TTS_ENGINE=openai`, `AUDIO_TTS_MODEL=tts-1`, `AUDIO_TTS_VOICE=alloy`, `AUDIO_TTS_OPENAI_API_BASE_URL` |
| `scripts/emit-runtime-env.sh` → `.env.runtime` | `AUDIO_STT_OPENAI_API_KEY`, `AUDIO_TTS_OPENAI_API_KEY` (= `op://Honeybot/OpenAI/key`) |

No new 1Password item — reuses the existing `OpenAI` key. Empty key ⇒ voice
just doesn't work; Open WebUI still boots.

## Default + selectable (your question)

- **Model**: the existing dropdown (sonnet / gpt-5.6 / …). Nothing to add.
- **Voice**: `AUDIO_TTS_VOICE=alloy` is the admin default; each user can pick
  a different OpenAI voice (echo, fable, onyx, nova, shimmer) in
  **Settings → Audio**.
- **Engine/model**: set to OpenAI here; changeable in **Admin → Settings →
  Audio**.

## ⚠️ PersistentConfig caveat

Open WebUI's `AUDIO_*` are *PersistentConfig*: the env vars **seed a fresh
`openwebui-data` volume** on first boot, after which the DB value wins and
env changes are ignored. On the **existing** deployment they may not take
effect — in that case set them in **Admin → Settings → Audio** directly
(engine = OpenAI, base URL = `https://api.openai.com/v1`, model, voice; and
paste the OpenAI key there once). Env remains the source of truth for fresh
deploys and documents intent.

## Deploy + verify

```bash
docker compose up -d          # secrets-init writes the AUDIO_* keys; openwebui recreates
```
Then in Open WebUI: open a chat → click the **microphone** (transcribes) and
the **headphone/Call** icon (hands-free). Pick a model in the dropdown; talk;
it replies in the chosen voice.

Verify direct-to-OpenAI: a failed transcription/synthesis in the openwebui
logs should reference `api.openai.com`, not `honeybot`/`owui-auth-bridge`.

## Upgrades (later)

- **Better voice**: ElevenLabs (`AUDIO_TTS_ENGINE=elevenlabs`,
  `AUDIO_TTS_API_KEY`), or OpenAI `gpt-4o-mini-tts` (steerable) / `tts-1-hd`.
- **Better STT**: `gpt-4o-transcribe` / `gpt-4o-mini-transcribe`.
- **Privacy**: local Whisper (`AUDIO_STT_ENGINE=""` + `WHISPER_MODEL`) keeps
  mic audio in-container — heavier (model download + CPU).
