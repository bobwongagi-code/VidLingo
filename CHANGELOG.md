# Changelog

All notable changes to AirTranslate are documented in this file.

## Unreleased

No unreleased changes yet.

## 1.3.1 - 2026-05-16

### Changed

- Temporarily disabled Apple basic-mode source-language auto-detection while the mid-session language-switch behavior is improved.
- Added an in-app notice when the disabled auto-detect toggle is clicked.
- Updated release packaging metadata for the 1.3.1 hotfix build.

### Fixed

- Prevented previously saved auto-detect settings from enabling the feature in the current build.

## 1.3.0 - 2026-05-16

### Added

- Added input support for built-in, Bluetooth, and AirPods microphones.
- Added source-language auto-detection for Apple basic mode when the input stream makes source language inference possible.

### Changed

- Improved microphone pipeline handling for long-running sessions to reduce duplicate input spikes.

### Fixed

- Fixed unstable microphone source behavior that could duplicate incoming segments.
- Improved input handling when switching between system audio and microphone capture.

## 1.2.1 - 2026-05-14

### Changed

- Apple mode now resets GPT transcription and translation model state when selected.
- Apple and GPT mode switching now uses shared session helpers to keep visible mode and internal processing state aligned.

### Fixed

- Fixed Apple default mode translation staying inactive while live transcription continued.
- Translation unavailable states now appear in the translation output instead of leaving the pane stuck on `Translating...`.

## 1.2.0 - 2026-05-13

### Added

- Added optional OpenAI Realtime transcription and translation modes for GPT-powered captions.
- Added a realtime translation-only model path with optional translated audio playback.
- Added macOS Keychain storage for user-provided OpenAI API keys.
- Added English, Korean, Japanese, and Simplified Chinese README files.
- Added separate Apple Intelligence Writing Tools buttons for the original and translation panes in the saved transcript editor.
- Added grouped saved transcript display for original-plus-translation saves.

### Changed

- GPT realtime floating captions now show only the current live caption unit instead of the accumulated transcript, so the overlay behaves more like movie subtitles.
- GPT realtime delta handling now builds the current utterance before publishing it to the caption flow.
- GPT modes disable transcript lint cleanup so realtime model output is not rewritten by Apple spell-check cleanup.
- Saved `Original + Translation` transcripts are now stored as separate `*_original.txt` and `*_translation.txt` files that share the same base name.
- The library presents those paired files as one saved transcript and shows original and translation editors in the same detail section.
- The saved transcript editor now uses plain `NSTextView` editors for Writing Tools so macOS treats each pane as editable plain text.
- The library row hit area now spans the full row, making saved transcript selection easier.

### Fixed

- Reduced duplicate source and translation text after paragraph cleanup or settings changes.
- Fixed GPT realtime floating captions so the overlay shows only the current live caption unit instead of the accumulated transcript.

## 1.1.0 - 2026-05-10

### Added

- Added a centered live audio waveform meter that reacts to captured system-audio decibel levels while capture is running.
- Added visible hover, pressed, active, and short click-confirmation feedback to the header transport controls.

### Changed

- Moved the live audio waveform out of the right-side button cluster into a wider center header area.
- Increased audio-level reporting frequency so the waveform responds more smoothly to current input.
- Kept stop, pause/resume, and floating-caption controls grouped on the right while preserving accessibility labels and values.

## 2026-05-09 - Library Modal UI

### Added

- Added a saved transcript content selector for original, original plus translation, or translation-only output.
- Added a confirmation-protected delete-all action for saved transcript files.

### Changed

- Moved saved transcript management out of the sidebar into a focused modal library view.
- Kept the sidebar storage area as a compact entry point for opening saved transcript management.

## 2026-05-09 - Transcript Control and Stability

### Added

- Added a settings control for the silence interval that starts a new transcript paragraph.
- The paragraph break interval keeps the previous default of 5 seconds and can now be adjusted from 1 to 15 seconds in 0.5 second steps.

### Fixed

- Limited live speech analyzer input buffering to the latest 32 audio chunks so delayed analysis cannot grow an unbounded queue.
- Limited the live translation segment cache to 240 recent entries and reset it when the session, language, or model changes.
- Disabled streaming text animation for long transcript updates to reduce SwiftUI layout and attributed-text work during long sessions.
