## Summary

Fix IC-LoRA control-video preprocessing and output-size quantization for portrait and other non-square inputs.

## Problem

IC-LoRA conditioning initially wrote the control video at the source video's original dimensions, which could diverge from the generation target size. After aligning the control video with the target output, portrait requests could still fail because the chosen output height was only snapped to multiples of 64. The two-stage IC-LoRA pipeline requires final output dimensions that are effectively multiples of 128 for valid stage-1 latent patching.

## Changes

- Add `resize_and_crop` to the video processor interface and implementation.
- Resize and crop each conditioning frame to the target generation size before writing the cached control video.
- Compute IC-LoRA output size with a fixed width of 768 and a height snapped to valid multiples of 128.
- Preserve the conditioning cache flow while guaranteeing `control_video_path` is initialized before inference.
- Add regression coverage to assert portrait conditioning videos are written and generated at valid dimensions.

## Result

IC-LoRA can now use portrait inputs without hitting latent shape mismatches, and the generated video matches the dimensions used for conditioning.