# Setup Notes

This note captures public, repository-safe setup findings from a local Windows validation run.

## Verified workflow

- Node dependencies can be installed successfully.
- Backend Python dependencies can be installed successfully with `uv`.
- TypeScript typecheck passes.
- Python typecheck passes.
- Backend tests pass.
- Frontend and Electron production bundles build successfully.
- A runnable unpacked Windows app can be produced and launched locally.

## Commands used successfully

```powershell
npx pnpm@10.30.3 install

Set-Location backend
uv sync --extra dev

Set-Location ..
npx pnpm@10.30.3 run typecheck:ts
npx pnpm@10.30.3 run typecheck:py
npx pnpm@10.30.3 run backend:test
npx pnpm@10.30.3 run build:frontend

& .\scripts\prepare-python.ps1
Set-Location release\win-unpacked
& '.\LTX Desktop.exe'
```

## Model directory behavior

The application stores a single effective `models_dir` setting and resolves all required model files relative to that root.

- Existing models are detected only when the expected canonical file or directory names are present under the configured root.
- Alternate filenames are not treated as equivalents.
- If a required canonical file is missing, the app downloads it into the configured root.
- If the exact canonical target already exists, the app skips downloading that target.

This means the current implementation is based on one canonical model root, not a recursive multi-layout search.

## Local build caveats

### `pnpm` availability

Some environments may not have a global `pnpm` binary available on `PATH` even though Node is installed.

Practical workaround:

```powershell
npx pnpm@10.30.3 <command>
```

### Windows packaging and signing

The checked-in Windows packaging configuration is oriented toward signed release builds.

Implications for local validation:

- local packaging may fail if release signing credentials are not configured
- an unpacked local build is the lowest-friction path for validation

### Updater noise in local unpacked runs

Unpacked local runs may log updater-related errors because release update metadata is not present in the local package. This does not necessarily prevent the app from launching.

### Packaged icon path

The local unpacked build may log a missing icon path during startup. This appears to be a packaging/runtime polish issue rather than a core application blocker.

## Follow-up ideas

- Add a supported unsigned local Windows packaging path for contributors.
- Add a sanitized contributor-facing setup note to the main documentation if needed.
- Consider a future import/discovery flow for alternative model layouts such as ComfyUI-managed directories.