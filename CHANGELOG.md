# Changelog

All notable changes to VidLingo are documented in this file.

## Unreleased

- Changed offline processing to keep Fun-ASR transcription internal, show one stable processing state, and render the final bilingual timeline only after translation is complete.
- Added a bilingual timestamp timeline built from Fun-ASR word timestamps, with local pause-aware segmentation, aligned translation columns, and video seeking.
- Removed legacy specialist-transcription, remote-review, and local transcript-selection paths.
- Replaced local transcription dependencies with the Fun-ASR Flash cloud transcription path.

## 1.3.2 - 2026-07-29

### Reliability and Security

- Made transcript edits and deletes transactional for legacy flat file pairs.
- Added visual-response schema fallback, broader LLM response parsing, endpoint query/fragment rejection, and stronger media validation.
- Added explicit media-operation timeouts and cancellation handling for AVFoundation duration and frame extraction.
- Restricted install/run/package/verify to stable signing identities; ad-hoc install is now explicit `dev-run` only.
- Added app/core regression tests and CI gates for scripts, bundle construction, and ad-hoc signature verification.

## 1.3.1 - 2026-07-28

### Reliability and Security

- Added atomic, manifest-backed transcript publishing with no-clobber behavior and stale staging cleanup.
- Made legacy AirTranslate transcripts read-only and explicit to import; delete-all no longer removes legacy data.
- Added bounded media processing, cancellation, process deadlines, input size and duration limits, and bounded diagnostics.
- Restricted custom endpoints to HTTPS by default and separated API-key storage from cloud audio/frame consent.
- Added provider capability metadata, explicit OpenRouter / Claude and Anthropic naming, flexible response parsing, and safer visual fallback behavior.
- Added regression tests and a macOS Swift CI workflow.

### Changed

- Renamed the app and Swift package targets from AirTranslate to VidLingo.
- Reworked the product direction from realtime Mac audio captions to short-video offline translation.
- Kept migration fallback for the old AirTranslate model directory and made old transcript records read-only until explicitly imported.

### Removed

- Removed realtime system-audio capture, microphone capture, Apple Speech streaming, OpenAI Realtime, floating captions, menu bar controls, old release-site materials, and stale multilingual README files.
