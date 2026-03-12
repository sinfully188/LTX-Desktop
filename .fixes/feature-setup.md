## Summary

Finalize the Windows setup branch with reusable local tooling for model reuse and unsigned local packaging.

## Included setup work

- Add candidate filtering and scoring improvements to `scripts/link-existing-models.ps1` so it prefers canonical model locations, avoids false positives from LoRA folders, and handles Z-Image matching more reliably.
- Improve link validation for Windows hardlinks, junctions, and symbolic links, including UNC-backed symbolic link cases.
- Add `electron-builder.local.yml` as a local unsigned Windows builder config for creating unpacked builds without Azure Trusted Signing.

## Result

The setup branch now contains both the Windows model-linking workflow and the local packaging config needed to build and run the app in a practical developer environment.