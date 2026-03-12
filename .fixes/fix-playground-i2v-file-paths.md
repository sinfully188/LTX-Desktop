## Summary

Fix Playground image and audio selection so click and replace actions always use real filesystem paths via the Electron file dialog.

## Problem

Playground uploads could fall back to blob URLs when a selected browser `File` object did not expose a native path. The backend only accepts real file paths for local image-to-video and audio-to-video generation, so the UI could show a selected asset while generation silently behaved as if no local file had been provided.

## Changes

- Route click and replace actions in the image uploader through `window.electronAPI.showOpenFileDialog`.
- Route click and replace actions in the audio uploader through the same Electron dialog path.
- Normalize selected paths into `file:///...` URLs before storing them in frontend state.
- Derive an `effectiveMode` in Playground so attaching an image clearly switches the request to image-to-video.
- Update the primary action label and helper text to reflect the effective mode.

## Result

Playground local file selection now behaves the same way as drag and drop: the backend receives a real path, image-to-video uses the chosen image, and the UI makes the mode switch explicit.