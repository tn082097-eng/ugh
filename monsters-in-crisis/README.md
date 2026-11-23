# Monsters in Crisis

A deadpan, photorealistic talk-show intervention: a TV psychologist confronts a giant kaiju and a giant ape
about their destructive relationship. About 58 seconds, 10 shots, 16:9, synchronized dialogue, no laugh track.

| File | What it is |
|---|---|
| `shots.json` | Shot list and the source of truth: style, cast descriptions, camera, action, dialogue, audio per shot |
| `PROMPTS.md` | Copy-paste prompts for each shot, generated from `shots.json` |
| `assemble.py` | Writes the prompts, checks which clips exist, and cuts the finished scene with ffmpeg |
| `tests/` | End-to-end test of the assembler on synthetic clips |

## Recommended workflow

1. **Pick a generator that renders speech and lip sync in the clip itself.** Shots 02, 04, 06 and 08 have dialogue.
   A model that renders audio with the video (Google's Veo 3 family in Gemini / Flow is the strongest
   option at time of writing) avoids a separate lip-sync step. Kling, Hailuo/MiniMax and Runway also handle
   photoreal creatures well. Most give free or trial credits, and limits change often, so check current
   allowances. Ten shots plus retakes usually takes 25–40 generations.
2. **Lock the look first.** Generate one still of the establishing wide shot (shot 01). Reuse it as the image or
   reference input for every shot. Keep the seed fixed where the tool allows. This keeps the set, the host and
   both creatures consistent between clips.
3. **Generate the shots** from `PROMPTS.md`, one block per generation, with the negative prompt where supported.
   Do 2–4 takes per shot and keep the stillest, least theatrical one. For the deadpan tone, underplayed takes
   are better.
4. **If your tool cannot do speech**, generate the four dialogue shots silent, record or TTS the lines, then run
   a lip-sync pass (most of the tools above offer one). The creatures never speak, so only the host needs sync.
5. **Drop the clips into `clips/`**, named by shot id (`clips/04_host_look_at_me.mp4`, etc.), and build:

```bash
python3 assemble.py check                              # which shots are still missing
python3 assemble.py build                              # -> out/monsters_in_crisis.mp4
python3 assemble.py build --room-tone roomtone.wav     # optional quiet room tone under the whole cut
python3 assemble.py build --allow-missing              # rough cut with whatever exists so far
```

The assembler conforms every clip to 1920×1080, 24 fps and 48 kHz stereo, letterboxing anything that isn't 16:9.
It trims each clip to its planned length; set `"trim_start"` on a shot to choose the best section of a
longer take. Clips get silent audio if they have none. Shots are joined with hard cuts (talk-show grammar),
loudness is normalized to −16 LUFS, and there is a 0.5 s fade in and 1 s fade out. It never freezes frames,
so the awkward pauses come from real held footage, not stills.

## About the host and the monsters

Video generators generally refuse photorealistic depictions of real people. A convincing fake of a real
person also tends to get taken down once shared. So the prompts cast an original TV psychologist and
don't try to recreate Dr. Phil's likeness or get it past those filters. The dialogue is unchanged. The
creatures are described as an original kaiju and a giant silverback rather than by name. Image-model
filters often block trademarked character names. The names still appear in the spoken lines, which is
where the joke lives.

## Regenerating prompts

Edit `shots.json`, then run `python3 assemble.py prompts`. Run tests with `python3 -m pytest -q tests`.
