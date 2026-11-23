#!/usr/bin/env python3
"""Monsters in Crisis: prompt export and final-cut assembly.

  python3 assemble.py prompts            # write PROMPTS.md from shots.json
  python3 assemble.py check              # list which shot clips are present
  python3 assemble.py build [-o out.mp4] [--room-tone tone.wav]

Rendered clips go in ./clips, named by shot id first, e.g. clips/03_kaiju_looks_down.mp4
(any file starting with the id and ending in .mp4/.mov/.webm/.mkv). Each clip is conformed
to 1920x1080 / 24 fps / 48 kHz stereo, trimmed to the shot duration, cut together with hard
cuts, loudness-normalised to -16 LUFS, with a short fade in and out.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
VIDEO_EXTS = (".mp4", ".mov", ".webm", ".mkv")


def load_shots(path: Path) -> dict:
    return json.loads(path.read_text())


def find_clip(clips_dir: Path, shot_id: str) -> Path | None:
    matches = sorted(
        p for p in clips_dir.glob(f"{shot_id}*") if p.suffix.lower() in VIDEO_EXTS
    )
    return matches[0] if matches else None


def run(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"command failed: {' '.join(cmd)}\n{proc.stderr[-2000:]}")
    return proc.stdout


def probe(path: Path) -> dict:
    out = run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)])
    data = json.loads(out)
    video = next((s for s in data["streams"] if s["codec_type"] == "video"), None)
    if video is None:
        sys.exit(f"{path} has no video stream")
    return {
        "width": int(video["width"]),
        "height": int(video["height"]),
        "duration": float(data["format"].get("duration", 0)),
        "has_audio": any(s["codec_type"] == "audio" for s in data["streams"]),
    }


# ---------------------------------------------------------------- prompts

def shot_prompt(spec: dict, shot: dict) -> str:
    chars = spec["characters"]
    text_blob = " ".join(str(shot.get(k) or "") for k in ("camera", "action"))
    if shot.get("dialogue"):
        text_blob += " " + shot["dialogue"]["speaker"]
    cast = [f"{name}: {desc}." for name, desc in chars.items() if name in text_blob]
    parts = [
        f"{spec['style']}",
        "Characters: " + " ".join(cast) if cast else "",
        f"Camera: {shot['camera']}",
        f"Action: {shot['action']}",
    ]
    if shot.get("dialogue"):
        d = shot["dialogue"]
        parts.append(f'The host says ({d["delivery"]}): "{d["line"]}" Only the host speaks; lips sync to the line.')
    else:
        parts.append("No one speaks in this shot.")
    parts.append(f"Audio: {shot['audio']} {spec['audio_bed']}")
    parts.append(f"Length: {shot['duration']} seconds, 16:9.")
    return "\n".join(p for p in parts if p)


NEGATIVE = (
    "laugh track, applause, music, cartoon, animation style, CGI-looking plastic skin, "
    "exaggerated facial expressions, mugging at camera, subtitles, captions, on-screen text, "
    "logos, watermark, fast camera moves, camera shake, extra limbs, warped hands"
)


def write_prompts(spec: dict, out: Path) -> None:
    lines = [
        f"# {spec['title']} - shot prompts",
        "",
        "Generated from `shots.json` by `python3 assemble.py prompts`; edit the JSON, not this file.",
        "",
        "Paste one block per generation. Use the same seed / reference image for every shot so the",
        "set, host and creatures stay consistent. Negative prompt (where the tool supports one):",
        "",
        f"> {NEGATIVE}",
        "",
    ]
    for shot in spec["shots"]:
        lines += [
            f"## Shot {shot['id']} - {shot['name']} ({shot['duration']}s)",
            "",
            "```text",
            shot_prompt(spec, shot),
            "```",
            "",
        ]
    out.write_text("\n".join(lines))
    print(f"wrote {out}")


# ---------------------------------------------------------------- assembly

def conform(src: Path, dst: Path, shot: dict, fmt: dict) -> float:
    info = probe(src)
    w, h, fps, rate = fmt["width"], fmt["height"], fmt["fps"], fmt["audio_rate"]
    aspect = info["width"] / info["height"]
    if abs(aspect - 16 / 9) > 0.02:
        print(f"  warning: {src.name} is {info['width']}x{info['height']} (not 16:9); it will be letterboxed")

    start = float(shot.get("trim_start", 0))
    available = max(info["duration"] - start, 0)
    length = min(float(shot["duration"]), available) if available else float(shot["duration"])
    if available and available < shot["duration"] - 0.05:
        print(f"  note: {src.name} is {available:.2f}s after trim, shorter than planned {shot['duration']}s; using all of it")

    vf = (
        f"scale={w}:{h}:force_original_aspect_ratio=decrease,"
        f"pad={w}:{h}:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps={fps},format=yuv420p"
    )
    cmd = ["ffmpeg", "-y", "-v", "error", "-ss", f"{start}", "-i", str(src)]
    if info["has_audio"]:
        amap = ["-map", "0:a:0", "-af", f"aresample={rate},aformat=channel_layouts=stereo"]
    else:
        cmd += ["-f", "lavfi", "-i", f"anullsrc=channel_layout=stereo:sample_rate={rate}"]
        amap = ["-map", "1:a:0"]
    cmd += ["-map", "0:v:0", *amap, "-vf", vf, "-t", f"{length}",
            "-c:v", "libx264", "-preset", "medium", "-crf", "17",
            "-c:a", "pcm_s16le", "-ar", str(rate), "-ac", "2", str(dst)]
    run(cmd)
    return length


def build(spec: dict, clips_dir: Path, out: Path, room_tone: Path | None, allow_missing: bool) -> None:
    fmt = spec["format"]
    shots = spec["shots"]
    missing = [s["id"] for s in shots if find_clip(clips_dir, s["id"]) is None]
    if missing and not allow_missing:
        sys.exit(f"missing clips for shots {', '.join(missing)} in {clips_dir} (use --allow-missing to cut without them)")

    with tempfile.TemporaryDirectory() as tmp_str:
        tmp = Path(tmp_str)
        parts, total = [], 0.0
        for shot in shots:
            src = find_clip(clips_dir, shot["id"])
            if src is None:
                print(f"skip {shot['id']} (no clip)")
                continue
            dst = tmp / f"{shot['id']}.mkv"
            print(f"conform {src.name}")
            total += conform(src, dst, shot, fmt)
            parts.append(dst)
        if not parts:
            sys.exit("no clips to assemble")

        listing = tmp / "list.txt"
        listing.write_text("".join(f"file '{p}'\n" for p in parts))
        joined = tmp / "joined.mkv"
        run(["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", str(listing), "-c", "copy", str(joined)])

        fade_out = max(total - 1.0, 0)
        vfilter = f"[0:v]fade=t=in:st=0:d=0.5,fade=t=out:st={fade_out:.3f}:d=1[v]"
        inputs = ["-i", str(joined)]
        if room_tone:
            inputs += ["-stream_loop", "-1", "-i", str(room_tone)]
            afilter = (
                f"[1:a]aresample={fmt['audio_rate']},aformat=channel_layouts=stereo,volume=0.2[rt];"
                "[0:a][rt]amix=inputs=2:duration=first:normalize=0,"
            )
        else:
            afilter = "[0:a]"
        afilter += (
            f"loudnorm=I=-16:TP=-1.5:LRA=11,aresample={fmt['audio_rate']},"
            f"afade=t=in:st=0:d=0.5,afade=t=out:st={fade_out:.3f}:d=1[a]"
        )
        out.parent.mkdir(parents=True, exist_ok=True)
        run(["ffmpeg", "-y", "-v", "error", *inputs,
             "-filter_complex", f"{vfilter};{afilter}", "-map", "[v]", "-map", "[a]",
             "-t", f"{total:.3f}", "-c:v", "libx264", "-preset", "slow", "-crf", "18",
             "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(out)])
    final = probe(out)
    print(f"wrote {out}: {final['width']}x{final['height']}, {final['duration']:.2f}s, {len(parts)} shots")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--shots", type=Path, default=HERE / "shots.json")
    ap.add_argument("--clips", type=Path, default=HERE / "clips")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("prompts").add_argument("-o", type=Path, default=HERE / "PROMPTS.md")
    sub.add_parser("check")
    b = sub.add_parser("build")
    b.add_argument("-o", type=Path, default=HERE / "out" / "monsters_in_crisis.mp4")
    b.add_argument("--room-tone", type=Path, help="optional room-tone audio looped quietly under the cut")
    b.add_argument("--allow-missing", action="store_true", help="cut with whichever shots exist")
    args = ap.parse_args()

    spec = load_shots(args.shots)
    if args.cmd == "prompts":
        write_prompts(spec, args.o)
    elif args.cmd == "check":
        for s in spec["shots"]:
            clip = find_clip(args.clips, s["id"])
            print(f"{s['id']} {s['name']:<24} {clip.name if clip else 'MISSING'}")
    else:
        for tool in ("ffmpeg", "ffprobe"):
            if shutil.which(tool) is None:
                sys.exit(f"{tool} not found on PATH")
        build(spec, args.clips, args.o, args.room_tone, args.allow_missing)


if __name__ == "__main__":
    main()
