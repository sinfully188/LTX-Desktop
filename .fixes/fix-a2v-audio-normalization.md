## Summary

Normalize audio-to-video inputs on the backend before local generation or API upload.

## Problem

The A2V pipeline was stricter than the app's generic audio validation. Valid user audio could still fail later if it was not already stereo or if it exceeded the practical clip length used by the pipeline.

## Changes

- Add `backend/server_utils/audio_preprocessing.py` to convert input audio to stereo WAV at 48 kHz.
- Trim prepared audio to the first 20 seconds, matching the app's effective A2V video length.
- Use the prepared temporary WAV for local A2V generation.
- Use the same prepared WAV for API-backed A2V uploads.
- Extend backend tests to verify conversion to stereo, temporary-file cleanup, and `.wav` upload/generation behavior.

## Result

Mono or otherwise non-conforming audio no longer needs manual preprocessing before A2V. The app consistently feeds the downstream pipeline a short stereo WAV that it can ingest.