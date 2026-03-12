from __future__ import annotations

from contextlib import contextmanager
from pathlib import Path
import subprocess
import tempfile
from collections.abc import Iterator

import imageio_ffmpeg

from _routes._errors import HTTPError

A2V_MAX_AUDIO_SECONDS = 20.0
A2V_TARGET_CHANNELS = 2
A2V_TARGET_SAMPLE_RATE = 48_000


@contextmanager
def prepare_a2v_audio_file(input_path: Path) -> Iterator[Path]:
    """Create a temporary stereo WAV trimmed for A2V ingestion.

    The upstream A2V path is stricter than our generic audio validation, so we
    normalize here instead of rejecting otherwise valid mono/multichannel input.
    """

    temp_path = Path(tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name)
    try:
        ffmpeg_exe = imageio_ffmpeg.get_ffmpeg_exe()
        result = subprocess.run(
            [
                ffmpeg_exe,
                "-y",
                "-i",
                str(input_path),
                "-vn",
                "-t",
                str(A2V_MAX_AUDIO_SECONDS),
                "-ac",
                str(A2V_TARGET_CHANNELS),
                "-ar",
                str(A2V_TARGET_SAMPLE_RATE),
                "-c:a",
                "pcm_s16le",
                str(temp_path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0 or not temp_path.exists() or temp_path.stat().st_size <= 0:
            raise HTTPError(400, f"Invalid audio file: {input_path}")
        yield temp_path
    except FileNotFoundError as exc:
        raise HTTPError(500, "Audio preprocessing failed: ffmpeg unavailable") from exc
    finally:
        temp_path.unlink(missing_ok=True)