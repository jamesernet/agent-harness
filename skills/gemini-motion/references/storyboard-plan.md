# Storyboard plan format

A storyboard is a JSON plan of independent shots. `scripts/storyboard.py`
renders each shot as one Omni call and stitches the clips with ffmpeg.
`plan.json` lives in its own working directory, outside any repository unless
the user names one, next to any images it names; paths in the plan are
relative to that directory. `storyboard.py check` validates everything below;
this file explains the choices. Start from `storyboard-example.json`.

```json
{
  "title": "Harness in sixty seconds",
  "resolution": "720p",
  "aspect_ratio": "16:9",
  "style": "Clean studio lighting, muted palette, shallow depth of field, photoreal. A single continuous shot, no scene cuts. No on-screen text.",
  "shots": [
    {
      "id": "open",
      "duration": 8,
      "prompt": "Slow dolly-in on a laptop on an oak desk at dawn; the screen glows with scrolling terminal text. Sound design: soft keyboard clicks, distant birdsong, no music."
    },
    {
      "id": "handoff",
      "duration": 6,
      "first_frame": "frames/handoff-start.png",
      "images": ["refs/mug.png"],
      "prompt": "The camera tilts up from the laptop to a window as morning light floods the room; the mug <IMAGE_REF_0> stays in the foreground. Sound design: low ambient hum."
    }
  ]
}
```

## Top level

| field | required | values | note |
|---|---|---|---|
| `title` | yes | text | names the stitched file (`out/<slug>.mp4`) |
| `resolution` | yes | `360p`, `720p`, `1080p`, `4k` | one per plan; it sets the per-second rate, so it is part of the approval token |
| `aspect_ratio` | no | `16:9` (default), `9:16` | one per plan; mixed ratios do not stitch |
| `style` | no | text | appended to every shot prompt; the main lever for consistency. It is part of every shot's spec, so editing it re-renders, and re-bills, the whole plan |
| `shots` | yes | list | rendered and stitched in this order |

There is no `model` field: the skill pins its video model in
`gemini_common.MODELS`. There is no `negative_prompt` field: Omni has no such
parameter, so write "No on-screen text" into `style` or the prompt. A field the
plan does not take is refused rather than ignored, so a plan from another format
fails `check` instead of silently dropping something from a render that costs
money.

## Shot

| field | required | note |
|---|---|---|
| `id` | yes | lowercase letters, digits, hyphens; stable across edits, since the manifest keys on it |
| `prompt` | yes | one shot, one camera move, one action; `style` is appended |
| `duration` | yes | whole seconds, 3 to 10: what one Omni call renders. Billed per second, so every shot pins its length |
| `first_frame` | no | image the shot starts on; locks composition between shots |
| `last_frame` | no | image the shot ends on; needs `first_frame`; Omni interpolates between the two |
| `images` | no | reference images for a subject, product or style; refer to them in the prompt as `<IMAGE_REF_0>`, `<IMAGE_REF_1>` in list order |

Images are PNG, JPEG, WebP, HEIC or HEIF. `check` applies the render's own
rules to every one (type by extension, present, not empty) and reads each file
once to hash it, so an SVG, a GIF, a missing path, an empty file (what a failed
download leaves) or an unreadable one is refused by name before anything is
priced, not at the API.

## Writing a shot prompt

Omni reads a prompt as a shot description. Follow the recipe in
`video-prompting.md`: camera, subject and action, setting and light, style,
audio, structure, negatives. Two things matter more in a storyboard than in a
single clip:

- Say what the audio is on every shot, or each clip gets its own guess and the
  stitched result changes character at every cut.
- Keep shared detail in `style`, not repeated per shot. Repetition drifts as
  shots are edited.

## Keeping shots consistent

Shots are independent clips. Chaining them as extends of one another was
rejected because an extend bills the whole output every time, and Omni 1.2
stops an extended clip at 30 s: three 10-second extends would bill 60 s for a
30 s video, and editing shot 2 would re-bill everything after it. Continuity
has to come from the inputs instead, in order of strength:

- `first_frame` / `last_frame`: a still per shot, generated once (with
  `generate_image.py`, a screenshot, a photo) and reused. Ending one shot on the
  frame the next one starts from is the cleanest cut.
- `images`: the same reference images on every shot that shows the subject.
- `style`: palette, lens and lighting words shared by every prompt.

## Cost and approval

```sh
python3 <skill>/scripts/storyboard.py check plan.json
```

`check` prints one line per shot, the total seconds to render, a dollar
estimate from the skill's rate table (`VIDEO_RATES_USD`, per second of output
by resolution), and the token to approve with: `<total>s@<resolution>`. Show
the user that output and wait for an explicit yes.

```sh
python3 <skill>/scripts/storyboard.py render plan.json --approve 18s@720p
```

`render` recomputes the token from the plan on disk and refuses anything else.
Seconds alone are refused by name; a plan edited to a higher resolution after
`check` is refused on the old token. Re-run `check` and ask again rather than
adjusting the token yourself.

Without `--approve`, `render` prints the same lines `check` prints and refuses,
so going straight to `render` still shows the price first. With nothing pending
it says so and exits 0, which makes it the resume command after an interrupted
run.

Rendering is resumable and incremental. `out/manifest.json` records what each
clip was rendered from (model, resolution, aspect, full prompt, duration, image
contents); a shot whose clip exists and matches is skipped and never re-billed,
an edited one re-renders. To redo one shot, edit it and pass `--only <id>`;
`check --only <id>` prints the token for just that shot. The manifest is saved
after every shot, so an interrupted run resumes instead of re-paying.

`out/` is created next to the plan and ignores itself (a `.gitignore` with `*`),
the way `.gemini-motion/` does: billed clips and whole prompts do not belong in
a repository, and the protection arrives with the directory.

```sh
python3 <skill>/scripts/storyboard.py stitch plan.json
```

`stitch` refuses while any shot is missing or out of date, then re-encodes the
clips in plan order into `out/<title-slug>.mp4` (needs ffmpeg).

## Limits worth knowing

- 3 to 10 s per shot, 24 fps, native audio on every clip.
- Generation takes tens of seconds to a few minutes per shot; run `render` in
  the background.
- 1080p and 4k are delivered by URI; the script handles that.
- Prompts that trip the safety filter return no video. Rephrase; do not retry
  the same prompt.
- Do not use images of recognisable real people or minors.
- Every output carries an invisible SynthID watermark.
