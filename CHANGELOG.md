# Changelog

All notable changes to VidLingo are documented in this file.

## Unreleased

### Added

- Added adaptive Thai transcription: Pathumma runs first, then the general Whisper model reviews only uncertain segments.
- Added an optional quota-guarded ElevenLabs Scribe v2 fallback for unresolved Thai local transcription candidates.

### Changed

- Renamed the app and Swift package targets from AirTranslate to VidLingo.
- Reworked the product direction from realtime Mac audio captions to short-video offline translation.
- Kept migration fallbacks for old AirTranslate Whisper model and transcript directories.

### Removed

- Removed realtime system-audio capture, microphone capture, Apple Speech streaming, OpenAI Realtime, floating captions, menu bar controls, old release-site materials, and stale multilingual README files.
