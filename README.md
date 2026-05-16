![AirTranslate hero](docs/assets/airtranslate-readme-hero.png)

# AirTranslate

Live system-audio transcription and translation for macOS.

<p align="center">
  <a href="https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate.dmg"><img alt="Download AirTranslate.dmg" src="https://img.shields.io/badge/Download-AirTranslate.dmg-2EA44F?style=for-the-badge&logo=apple&logoColor=white"></a>
  <a href="https://github.com/himomohi/AirTranslate/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/himomohi/AirTranslate?style=for-the-badge&label=Latest"></a>
</p>

<p align="center">
  <a href="#download">Download</a> ·
  <a href="#requirements">Requirements</a> ·
  <a href="#privacy-and-api-keys">Privacy</a> ·
  English ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.zh-CN.md">中文</a>
</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-0A84FF?style=flat-square&logo=apple">
  <img alt="Swift 6.2+" src="https://img.shields.io/badge/Swift-6.2%2B-F05138?style=flat-square&logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="License: Apache 2.0" src="https://img.shields.io/badge/License-Apache%202.0-blue?style=flat-square"></a>
</p>

AirTranslate captures audio playing on your Mac, turns it into a live transcript, translates it in real time, and can show the result as a floating caption overlay. It is designed for meetings, lectures, videos, interviews, and streams where routing audio through a microphone is awkward or lossy.

The default workflow uses Apple frameworks. GPT-powered realtime models are optional and can be enabled from the app when you provide your own OpenAI API key.

## Why AirTranslate

- **System-audio first:** capture Mac playback audio directly with ScreenCaptureKit.
- **Readable live workspace:** source and translated text stay side by side.
- **Floating captions:** keep subtitles above other apps while you watch or listen.
- **Apple by default:** Apple Speech and Apple Translation remain the baseline path.
- **Optional GPT mode:** OpenAI Realtime transcription and translation can be enabled only when needed.
- **Keychain storage:** OpenAI API keys are entered by the user and stored in macOS Keychain.
- **Plain text history:** saved transcripts remain normal `.txt` files in Application Support.

![AirTranslate demo](docs/assets/airtranslate-readme-demo.gif)

> "Turn any Mac audio into live captions and translation, right where you are watching."

## Core Features

- Live Mac system-audio capture
- Apple Speech transcription
- Apple Translation output
- Built-in, Bluetooth, and AirPods mic input support
- GPT mode with OpenAI Realtime transcription and translation
- Microphone input stability fixes for duplicate segments and noisy transitions
- Apple basic-mode source-language auto-detect is temporarily disabled while language-switch handling is improved.
- Realtime translation-only model path
- One-click source/target language swap
- Floating caption window
- Transcript polish based on macOS spelling suggestions
- Optional translated speech output
- Saved transcript library with edit, delete, and folder access
- English, Korean, Japanese, and Simplified Chinese interface selection based on the Mac language

## Processing Modes

AirTranslate separates the quick choice from the detailed setup.

| Mode | Best For | Details |
| --- | --- | --- |
| Apple Mode | Local-first transcription and translation | Uses Apple Speech for transcription and Apple Translation for the selected language pair. Source-language auto-detect is temporarily disabled while language-switch handling is improved. |
| GPT Mode | OpenAI Realtime transcription or translation | Enables GPT realtime models. If no API key is saved, AirTranslate opens the settings modal and focuses the API key field. |
| Transcribe Only | Source captions without translation | Records source-language captions without running translation. |
| Realtime Translation Only | Direct translated stream | Uses the realtime translation model path when you want the model to produce the translated stream directly. |

GPT model details, API key entry, transcript polish, and voice output are managed from the gear-shaped settings modal. The main sidebar only exposes the most important choices.

## Privacy And API Keys

AirTranslate does not ship with a backend account system.

- Apple Mode uses macOS frameworks and locally managed Apple language assets.
- OpenAI calls happen only when GPT mode or OpenAI translation models are enabled.
- OpenAI API keys are never hardcoded, committed, or included in release packages.
- Keys are saved in macOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Saved transcripts are plain text files on your Mac.

Need an API key? Open the [OpenAI API key page](https://platform.openai.com/api-keys), create a key, then paste it into AirTranslate's settings modal.

## Apple Translation Language Packs

Apple Mode uses macOS-managed translation languages. Before using Apple Mode with a new language pair, download the needed Apple translation language packs:

1. Open **System Settings**.
2. Go to **General > Language & Region**.
3. Click **Translation Languages**.
4. Click **Download** for each source and target language you want to use.
5. Optional: turn on **On-Device Mode** if you want macOS to process supported translations on your Mac whenever possible.

If a selected language pair is unavailable or not downloaded, Apple Mode translation may not start or may show an unavailable state until macOS has the required language assets.

## Permissions

AirTranslate asks for the permissions required by its capture and transcription flow.

- Screen Recording
- System Audio Recording
- Speech Recognition

Screen Recording is required because ScreenCaptureKit provides the system-audio capture path. AirTranslate does not save screen frames as recordings.

After changing macOS privacy permissions, quit and relaunch the app so the signed app bundle receives the new authorization state.

## Download

Download the latest open-source build from [GitHub Releases](https://github.com/himomohi/AirTranslate/releases/latest). The DMG is the easiest install path, and the ZIP remains available as the original lightweight option.

AirTranslate remains fully open-source under the Apache-2.0 License. The DMG is provided only as a convenient macOS installer, while all source code, build scripts, release materials, LICENSE, and NOTICE files remain available in this repository.

- [Download AirTranslate.dmg](https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate.dmg)
- [Download AirTranslate-1.3.1.zip](https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate-1.3.1.zip)
- [Download AirTranslate.dmg.sha256](https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate.dmg.sha256)
- [View version history](Release/VERSION-HISTORY.md)

![AirTranslate install guide](docs/assets/airtranslate-install-guide.svg)

The open-source DMG and ZIP are ad-hoc signed builds for pre-notarization distribution. On the first launch, macOS may show an "unidentified developer" warning. To open the app:

1. Open the DMG and drag `AirTranslate.app` to Applications.
2. In Applications, Control-click or right-click `AirTranslate.app`.
3. Choose **Open**, then choose **Open** again in the macOS warning dialog.

You can verify the DMG checksum after downloading:

```bash
shasum -a 256 AirTranslate.dmg
cat AirTranslate.dmg.sha256
```

Developer ID signing and notarization are planned for a later distribution step.

## Requirements

- macOS 26.0 or later
- Swift 6.2 or later
- A Mac that supports system-audio capture
- Apple Speech and Apple Translation framework availability
- Optional: an OpenAI API key for GPT mode

## Build From Source

Run the app bundle:

```bash
./script/build_and_run.sh
```

Build and verify launch:

```bash
./script/build_and_run.sh --verify
```

View logs:

```bash
./script/build_and_run.sh --logs
```

Reset development permissions:

```bash
./script/build_and_run.sh --reset-permissions
```

SwiftPM checks:

```bash
swift build
swift test
```

## Basic Usage

1. Choose the source and target languages.
2. Use the center swap button if you want to reverse the direction.
3. Choose Apple Mode or GPT Mode.
4. For GPT Mode, add your OpenAI API key in the settings modal if prompted.
5. Press Start.
6. Play meeting, lecture, video, interview, or stream audio on your Mac.
7. Read the transcript and translation in the main workspace or floating caption window.
8. Press Stop to save the current transcript.

## Saved Transcripts

Saved transcripts are stored as plain text files:

```text
~/Library/Application Support/AirTranslate/Transcripts/*.txt
```

When source and translation are saved together, AirTranslate writes separate `_original.txt` and `_translation.txt` files while presenting them as one grouped item in the library UI.

## Project Map

```text
Package.swift
Resources/
  AppIcon.png
  AppIcon.icns
Sources/AirTranslate/
  App/
  Models/
  Services/
  Support/
  Views/
Sources/AirTranslateCore/
Tests/
script/
  build_and_run.sh
docs/assets/
  airtranslate-readme-hero.png
```

## Key Implementation Areas

- `SystemAudioCapture`: captures Mac system audio through ScreenCaptureKit.
- `LiveSpeechTranscriber`: streams speech recognition through Apple Speech.
- `AppleTranslationService`: isolates Apple Translation work.
- `OpenAIRealtimeTranscriber`: handles optional realtime transcription.
- `OpenAITranslationService`: handles optional realtime translation requests.
- `OpenAIAPIKeyStore`: saves the API key in macOS Keychain.
- `TranslationSessionStore`: coordinates capture, transcript state, translation, saving, and playback.
- `SidebarView`: language, mode, session, and settings entry points.
- `CaptionBoardView`: live transcript, translation, controls, and audio meter.
- `TranscriptLibraryView`: saved transcript management.
- `FloatingCaptionWindowController`: floating subtitle window lifecycle.

## License

AirTranslate is released under the [Apache License 2.0](LICENSE). Copyright attribution is provided in [NOTICE](NOTICE).

AirTranslate is an independent open-source project and is not affiliated with Apple or OpenAI.
