# VidLingo

VidLingo is a local-first macOS short-video translator. It imports a local video, extracts speech audio, transcribes it with local Whisper, and translates the complete transcript to Simplified Chinese with DeepSeek.

The current workflow is offline-first and short-video oriented. It no longer captures realtime Mac audio, microphone audio, or screen content.

## What It Does

- Import a local `.mov`, `.mp4`, or `.m4v` short video.
- Preview the selected video before translation.
- Extract speech audio locally with `ffmpeg`.
- Transcribe locally with `whisper.cpp`.
- Detect the spoken language from Whisper when auto detection is enabled.
- Translate the full transcript with a short-video e-commerce prompt.
- Save original and Chinese translation text files locally.

## Requirements

- macOS 15 or newer.
- Swift 6 toolchain.
- `ffmpeg` available on `PATH`.
- `whisper-cli` or `main` from `whisper.cpp` available on `PATH`.
- A local Whisper model, preferably `ggml-large-v3-turbo-q5_0.bin`.
- A DeepSeek API key saved in the app.

VidLingo looks for Whisper models in:

```text
~/Library/Application Support/VidLingo/Models/
~/Library/Application Support/AirTranslate/Models/
~/.cache/whisper/
```

The old `AirTranslate` model path is kept as a migration fallback.

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
