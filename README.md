# VidLingo

VidLingo is a local-first macOS short-video translator. It imports a local video, extracts speech audio locally, sends the audio to Alibaba Cloud Fun-ASR Flash, and translates the complete transcript to Simplified Chinese with your selected LLM provider.

The current workflow is offline-first and short-video oriented. It no longer captures realtime Mac audio, microphone audio, or screen content.

## What It Does

- Import a local `.mov`, `.mp4`, or `.m4v` short video.
- Preview the selected video before translation.
- Extract speech audio locally with `ffmpeg`.
- Transcribe all supported languages with `fun-asr-flash-2026-06-15`.
- Detect the spoken language locally from the returned transcript when auto detection is enabled.
- Translate the full transcript with a short-video e-commerce prompt.
- Always translate to Simplified Chinese; the spoken input language can be detected or selected manually.
- Choose Rootify, DeepSeek, or a custom Chat Completions-compatible endpoint.
- Save original and Chinese translation text files locally.
- Save a bilingual SRT timeline assembled from Fun-ASR word-level timestamps; the app groups speech by pauses, punctuation, and short-video-friendly duration, then shows time, original text, and Chinese translation in aligned columns.
- When no speech is detected, optionally generate an explicitly labeled visual sales script after enabling separate cloud frame and visual-copy consent switches.

## Requirements

- macOS 15 or newer.
- Swift 6 toolchain.
- `ffmpeg` available on `PATH`.
- An Alibaba Cloud Southeast Asia API key for Fun-ASR and a separate API key for the selected translation provider.
- The extracted speech audio is uploaded to Fun-ASR only after the separate audio-consent switch is enabled; frame uploads and no-speech visual copy remain separate opt-in switches.
- Audio consent, cloud frame uploads, and no-speech visual copy are independent switches and default to off.
- Custom endpoints must use HTTPS by default. Loopback HTTP is accepted only with `VIDLINGO_ALLOW_LOCAL_HTTP=1`.

## Translation Providers

VidLingo uses a shared Chat Completions-style request for these built-in providers:

```text
Rootify        https://rootifyaiapi.rootifyglobal.com/v1/chat/completions  gpt-5.6-luna
DeepSeek       https://api.deepseek.com/chat/completions        deepseek-v4-flash
Custom         user-provided HTTPS OpenAI-compatible chat completions URL
```

Custom endpoints must not contain query strings or fragments; put credentials in the provider API-key field instead. Responses may use `choices[].message.content`, content blocks, `choices[].text`, top-level `output_text`, or an `output` text structure.

API keys are stored in macOS Keychain per provider. The previous DeepSeek key is still read as a migration fallback.


Fun-ASR uses the workspace-specific native endpoint. Replace `<workspace-id>` with the ID from your deployment:

```text
https://<workspace-id>.ap-southeast-1.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation
fun-asr-flash-2026-06-15
```

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

Each completed translation is published as one directory containing `manifest.json`, `original.txt`, `translation.txt`, and, when timestamps are available, `bilingual.srt`. Incomplete staging directories are ignored and cleaned up on a later startup.

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
