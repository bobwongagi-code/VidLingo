# VidLingo

VidLingo is a local-first macOS short-video translator. It imports a local video, extracts speech audio, transcribes it with local Whisper, and translates the complete transcript to Simplified Chinese with your selected LLM provider.

The current workflow is offline-first and short-video oriented. It no longer captures realtime Mac audio, microphone audio, or screen content.

## What It Does

- Import a local `.mov`, `.mp4`, or `.m4v` short video.
- Preview the selected video before translation.
- Extract speech audio locally with `ffmpeg`.
- Transcribe locally with `whisper.cpp`.
- Detect the spoken language from Whisper when auto detection is enabled.
- If a Malay transcript fails the local quality check, retry once with greedy decoding before using the no-speech fallback.
- Translate the full transcript with a short-video e-commerce prompt.
- Always translate to Simplified Chinese; the spoken input language can be detected or selected manually.
- Choose DeepSeek, OpenAI, Qwen, OpenRouter / Claude, Anthropic / Claude, or a custom OpenAI-compatible endpoint.
- Save original and Chinese translation text files locally.
- When no speech is detected, optionally generate an explicitly labeled visual sales script after enabling separate cloud frame and visual-copy consent switches.

## Requirements

- macOS 15 or newer.
- Swift 6 toolchain.
- `ffmpeg` available on `PATH`.
- `whisper-cli` or `whisper-cpp` from `whisper.cpp` available on `PATH`; `VIDLINGO_WHISPER_CLI` can specify an exact path.
- A local general Whisper model, preferably `ggml-large-v3-q5_0.bin`.
- An API key for the selected translation provider. Saving a key does not authorize audio or frame uploads.
- Cloud frame uploads and no-speech visual copy are separate opt-in switches and default to off.
- Custom endpoints must use HTTPS by default. Loopback HTTP is accepted only with `VIDLINGO_ALLOW_LOCAL_HTTP=1`.

VidLingo looks for Whisper models in:

```text
~/Library/Application Support/VidLingo/Models/
~/Library/Application Support/AirTranslate/Models/
~/.cache/whisper/
```

The old `AirTranslate` model path is kept as a migration fallback.

## Translation Providers

VidLingo uses a shared Chat Completions-style request for these built-in providers:

```text
DeepSeek       https://api.deepseek.com/chat/completions        deepseek-v4-flash
OpenAI         https://api.openai.com/v1/chat/completions       gpt-4o-mini
Qwen / 千问     https://llm-nlx73tfv3mm6w67e.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions  qwen3.6-plus
Qwen-MT        same Qwen endpoint, model names like qwen-mt-flash or qwen-mt-plus
OpenRouter / Claude  https://openrouter.ai/api/v1/chat/completions  anthropic/claude-sonnet-4.5
Anthropic / Claude   https://api.anthropic.com/v1/messages             claude-sonnet-4-5
Custom         user-provided HTTPS OpenAI-compatible chat completions URL
```

Custom endpoints must not contain query strings or fragments; put credentials in the provider API-key field instead. Responses may use `choices[].message.content`, content blocks, `choices[].text`, top-level `output_text`, or an `output` text structure.

API keys are stored in macOS Keychain per provider. The previous DeepSeek key is still read as a migration fallback.

When the selected Qwen model name starts with `qwen-mt-`, VidLingo uses Qwen-MT's required `translation_options` request shape instead of the normal chat prompt.

The translation system prompt is bundled from:

```text
Resources/TranslationSystemPrompt.md
```

## Run Locally

```bash
./script/build_and_run.sh run
```

The `run` mode requires a stable `CODE_SIGN_IDENTITY`, builds the Swift package, creates `dist/VidLingo.app`, copies it to `~/Applications/VidLingo.app`, and opens it. The explicit `dev-run` mode uses ad-hoc signing for local development only; it may reset Keychain and privacy grants after rebuilds. The default mode only builds the bundle.

## App Data

New saved transcripts are written as manifest-backed directories to:

```text
~/Library/Application Support/VidLingo/Transcripts/
```

VidLingo reads old saved transcript files as read-only records. Use the explicit import action to copy them into VidLingo storage; delete-all only deletes VidLingo-owned records:

```text
~/Library/Application Support/AirTranslate/Transcripts/
```

## Build and Verify

```bash
./script/build_and_run.sh build     # build dist/VidLingo.app only
./script/build_and_run.sh package   # stable-signed release bundle as a zip
./script/build_and_run.sh install   # build and install to ~/Applications
./script/build_and_run.sh run       # build, install, and open
./script/build_and_run.sh verify    # build and verify the bundle
./script/build_and_run.sh stop      # explicitly stop a running VidLingo
swift test
```

`build` may use ad-hoc signing for a local bundle check. `install`, `run`, `package`, and `verify` require an explicit stable Apple signing identity so Keychain and privacy grants are tied to the intended app identity. The explicit `dev-run` mode is the only install-and-open path that permits ad-hoc signing. The ad-hoc build path can be disabled with `VIDLINGO_ALLOW_ADHOC_SIGNING=0`.

## Project Layout

```text
Sources/VidLingo/          macOS app UI and platform integrations
Sources/VidLingoCore/      pure workflow rules, transcript processing, and storage helpers
Resources/                 app icon assets
script/                    local build and app bundle scripts
```
