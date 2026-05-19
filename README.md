# VidLingo

VidLingo is a local-first macOS short-video translator. It imports a local video, extracts speech audio, transcribes it with local Whisper, and translates the complete transcript to Simplified Chinese with your selected LLM provider.

The current workflow is offline-first and short-video oriented. It no longer captures realtime Mac audio, microphone audio, or screen content.

## What It Does

- Import a local `.mov`, `.mp4`, or `.m4v` short video.
- Preview the selected video before translation.
- Extract speech audio locally with `ffmpeg`.
- Transcribe locally with `whisper.cpp`.
- Detect the spoken language from Whisper when auto detection is enabled.
- Translate the full transcript with a short-video e-commerce prompt.
- Choose DeepSeek, OpenAI, Qwen, Claude-compatible, or a custom OpenAI-compatible endpoint.
- Save original and Chinese translation text files locally.

## Requirements

- macOS 15 or newer.
- Swift 6 toolchain.
- `ffmpeg` available on `PATH`.
- `whisper-cli` or `main` from `whisper.cpp` available on `PATH`.
- A local Whisper model, preferably `ggml-large-v3-turbo-q5_0.bin`.
- An API key for the selected translation provider.

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
Qwen / 千问     https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions  qwen-plus
Qwen-MT        same Qwen endpoint, model names like qwen-mt-flash or qwen-mt-plus
Claude         https://api.anthropic.com/v1/chat/completions    claude-sonnet-4-5-20250929
Custom         user-provided OpenAI-compatible chat completions URL
```

API keys are stored in macOS Keychain per provider. The previous DeepSeek key is still read as a migration fallback.

When the selected Qwen model name starts with `qwen-mt-`, VidLingo uses Qwen-MT's required `translation_options` request shape instead of the normal chat prompt.

The translation system prompt is bundled from:

```text
Resources/TranslationSystemPrompt.md
```

## Run Locally

```bash
./script/build_and_run.sh
```

The script builds the Swift package, creates `dist/VidLingo.app`, copies it to `~/Applications/VidLingo.app`, signs it locally, and opens it.

## App Data

New saved transcripts are written to:

```text
~/Library/Application Support/VidLingo/Transcripts/
```

VidLingo also reads old saved transcript files from:

```text
~/Library/Application Support/AirTranslate/Transcripts/
```

## Project Layout

```text
Sources/VidLingo/          macOS app UI and offline workflow
Sources/VidLingoCore/      transcript text processing helpers
Resources/                 app icon assets
script/                    local build and app bundle scripts
```
