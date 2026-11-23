"""End-to-end check of assemble.py using synthetic ffmpeg test clips (not production footage)."""
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
SCRIPT = HERE / "assemble.py"


def make_clip(path: Path, size: str, seconds: float, audio: bool) -> None:
    cmd = ["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", f"testsrc2=size={size}:rate=30:duration={seconds}"]
    if audio:
        cmd += ["-f", "lavfi", "-i", f"sine=frequency=330:sample_rate=44100:duration={seconds}"]
    cmd += ["-c:v", "libx264", "-pix_fmt", "yuv420p"]
    if audio:
        cmd += ["-c:a", "aac"]
    subprocess.run(cmd + [str(path)], check=True)


def probe(path: Path) -> dict:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(out)


def test_build_conforms_and_joins(tmp_path: Path) -> None:
    spec = json.loads((HERE / "shots.json").read_text())
    spec["shots"] = [
        {**spec["shots"][0], "duration": 2},                     # 16:9 with audio, longer than planned
        {**spec["shots"][1], "duration": 2, "trim_start": 0.5},  # 4:3, no audio track
        {**spec["shots"][2], "duration": 3},                     # shorter than planned: used whole
    ]
    shots_file = tmp_path / "shots.json"
    shots_file.write_text(json.dumps(spec))
    clips = tmp_path / "clips"
    clips.mkdir()
    make_clip(clips / "01_a.mp4", "1280x720", 4, audio=True)
    make_clip(clips / "02_b.mov", "640x480", 3, audio=False)
    make_clip(clips / "03_c.mp4", "1920x1080", 1.5, audio=True)

    out = tmp_path / "final.mp4"
    subprocess.run(
        [sys.executable, str(SCRIPT), "--shots", str(shots_file), "--clips", str(clips), "build", "-o", str(out)],
        check=True,
    )

    info = probe(out)
    video = next(s for s in info["streams"] if s["codec_type"] == "video")
    audio = next(s for s in info["streams"] if s["codec_type"] == "audio")
    assert (video["width"], video["height"]) == (1920, 1080)
    assert video["r_frame_rate"] == "24/1"
    assert audio["sample_rate"] == "48000" and audio["channels"] == 2
    assert abs(float(info["format"]["duration"]) - 5.5) < 0.15  # 2 + 2 + 1.5


def test_build_refuses_missing_clips(tmp_path: Path) -> None:
    (tmp_path / "clips").mkdir()
    proc = subprocess.run(
        [sys.executable, str(SCRIPT), "--clips", str(tmp_path / "clips"), "build", "-o", str(tmp_path / "x.mp4")],
        capture_output=True, text=True,
    )
    assert proc.returncode != 0 and "missing clips" in proc.stderr
