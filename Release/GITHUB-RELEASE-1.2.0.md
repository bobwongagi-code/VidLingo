# AirTranslate 1.2.0

Open-source release for GPT realtime captions and multilingual documentation.

AirTranslate is an independent open-source project and is not affiliated with Apple or OpenAI.

## Added

- Optional OpenAI Realtime transcription and translation modes.
- Realtime translation-only mode with optional translated audio playback.
- OpenAI API keys are user-provided runtime data stored in macOS Keychain.
- English, Korean, Japanese, and Simplified Chinese README files.

## Changed

- Floating captions in GPT mode now show the current live caption unit instead of the accumulated transcript.
- Saved original-plus-translation transcripts are grouped as one library item.

## Fixed

- Reduced duplicate live transcript text after paragraph cleanup or settings changes.
- Improved per-pane editing behavior for saved original and translated transcripts.

## Download

Download `AirTranslate-1.2.0.zip` from this release, unzip it, then open `AirTranslate.app`.

macOS may require you to approve the app in Privacy & Security because this ZIP is an open-source ad-hoc signed build, not a notarized distribution.

## Privacy

Apple mode uses macOS system frameworks. GPT mode is optional and only sends the necessary audio or text to OpenAI after the user provides an API key.
