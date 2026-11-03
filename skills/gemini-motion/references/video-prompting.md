# Prompting Gemini Omni Flash for short videos

Model: `gemini-omni-1.1-flash`. One call returns a 3–10 second .mp4 with
native audio (24 fps). Extension adds up to 10 s per turn, 40 s total.
Length is a parameter: `--duration 3..10` sets `response_format.duration`
("3s".."10s"). Prefer it over asking in prose — you are billed per second of
output, and the flag is honoured where a sentence may not be. Still use
timecodes in the prompt for structure *within* the clip.

Condensed from Google's prompt guide (ai.google.dev/gemini-api/docs/omni),
plus what matters in practice.

## The brief → prompt recipe

A good prompt reads like a shot description, not a wish. Cover, in this order:

1. **Shot & camera** — "Continuous handheld close-up", "slow dolly-in",
   "static tripod wide shot", "top-down".
2. **Subject & action** — who/what, doing what, with concrete physical detail
   ("steam curls off the cup", "tail twitches twice").
3. **Setting & light** — place, time of day, light quality, palette.
4. **Style** — "photoreal", "stop-motion clay", "flat 2D vector animation",
   "anime", "1970s film grain".
5. **Audio** — always say what you want, or you get a guess: "Sound design:
   gentle rain, no music. No dialogue." / "Upbeat lo-fi beat."
6. **Structure** — single shot or cuts; timing; text.
7. **Negatives** — plain language: "No on-screen text. No people. No lens flare."

Example:

```
Continuous, unbroken slow-motion close-up of black coffee being poured into a
white ceramic cup on a dark walnut counter. Morning side light through a window,
soft shadows, shallow depth of field, photoreal. Steam rises as the cup fills.
Sound design: liquid pouring, quiet room tone, no music, no dialogue.
No scene cuts. No on-screen text. 8 seconds, vertical.
```

## Controls that live in the prompt

- **Single shot vs. edits.** By default Omni cuts between several shots to
  "tell a story". For one take, say so: "In a single continuous shot, no
  scene cuts."
- **Timing.** Natural language works: "After 3 seconds a hand enters frame."
  Or timecodes:
  ```
  [0-3s] the logo sits still on black
  [3-5s] it splits into particles that drift upward
  [5-8s] particles reassemble into the tagline "Launch Day"
  ```
- **Text on screen.** Omni renders legible text when told exactly what it
  says: `a neon sign that reads "OPEN LATE"`. Put the literal string in quotes.
- **Audio.** "Include calm background music", "a low radio in the background
  playing a song", "no sound effects", "no dialogue".
- **Negatives.** There is no `negative_prompt` parameter; write "Do not show
  X" in the prompt.
- **Meta-prompting.** "Be extremely detailed in costume and environment",
  "consider micro-expressions and timing" nudges richness.

## Controls that live in the call (flags on `generate_video.py`)

| Flag | Values | Notes |
|---|---|---|
| `--aspect` | `16:9` (default), `9:16` | portrait for reels/stories |
| `--resolution` | `360p`, `720p` (default), `1080p`, `4k` | 1080p/4k are upscaled; cost scales with it |
| `--draft` | | = `--resolution 360p`; use for every iteration until the prompt is right |
| `--image` | path, repeatable | reference images: subjects, products, style |
| `--first-frame` / `--last-frame` | path | keyframe interpolation; the script inserts `<FIRST_FRAME>`/`<LAST_FRAME>` tags |
| `--video` | path to .mp4 ≤10 s | uploads via Files API for editing/extending your own clip |
| `--previous-id` | interaction id | edit or extend the previous *generated* clip |
| `--task` | `text_to_video` `image_to_video` `reference_to_video` `edit` `extend` | only when prompting alone picks the wrong mode; it adds constraints |
| `--no-store` | | faster; but the result can't be chained later |

## Image inputs: three different jobs

Order of blocks is images first, text last; the script does this for you.

- **Animate this image** (image-to-video): one `--image`, prompt describes
  the motion. "Use high-resolution images and specific motion descriptions"
  — "make it move" gives weak results; "the drawing comes alive: the fish
  arcs out of the water, droplets trail, camera tracks it" gives good ones.
- **Start/end here** (interpolation): `--first-frame a.png --last-frame
  b.png`, prompt describes the transition. Same image for both = a loop.
- **Keep this subject consistent** (reference): `--image` for each subject,
  prompt refers to them with `<IMAGE_REF_0>`, `<IMAGE_REF_1>` in input order
  (references start at 0). Example: `the woman <IMAGE_REF_0> holds the mug
  <IMAGE_REF_1> and smiles`.

For mixed roles in one call, declare them at the top of the prompt:
`[# Sources <FIRST_FRAME>@Image1] [# References <IMAGE_REF_0>@Image2]`.

Keyframes can be made with `generate_image.py` first (Nano Banana), which is
how you get an exact product shot or a stylised frame to start from.

## Editing (multi-turn)

Pass `--previous-id <id>` and give a *short* instruction. Over-described edit
prompts cause unintended changes. End with "Keep everything else the same."

Good: `Make the sky stormy. Keep everything else the same.`
Good: `Change the sign to say "Grand Opening". Keep everything else the same.`
Bad:  a paragraph re-describing the whole scene plus the one change.

Each turn produces a new video; the model keeps the context (no re-upload).
This only works if the earlier call stored the interaction (default; don't
pass `--no-store` on clips you may want to edit).

## Extending

`--previous-id <id>` plus a prompt like `Extend this video: the camera keeps
panning left to reveal the harbour. Music continues into the chorus.` The
last 10 s of the clip are used as context; a few final frames get retouched
for a seamless join. Timecodes in an extension prompt count from the start of
the *new* part. You can extend your own uploaded clip (`--video`, ≤10 s) too,
but not to add dialogue to someone already talking.

## Limits worth knowing before promising anything

- 3–10 s per generation; up to 40 s via extensions.
- No system instructions, temperature, top_p, stop sequences or negative
  prompt parameters on this model.
- No voice editing; no audio reference uploads; audio in a reference video is
  ignored. Video references: max 3 clips, ≤3 s each.
- Don't upload images of recognisable real people or minors; such requests
  are refused or restricted by region.
- Editing/extending *uploaded* videos is unavailable in the EEA, UK and
  Switzerland (editing generated clips is fine everywhere).
- Every output carries an invisible SynthID watermark.
- Generation takes tens of seconds to a few minutes; longer/higher-res is slower.
- Outputs over 4 MB need URI delivery; the script switches to it automatically
  for 1080p/4k (`--uri` forces it).

## Cost discipline (it's paid-only)

~$0.03/s at 360p, ~$0.10/s at 720p, ~$0.15/s at 1080p, ~$0.30/s at 4K.
Workflow that keeps this sane:

1. Iterate the prompt at `--draft` (360p). Three drafts of 8 s ≈ $0.72.
2. Only when the draft is right, re-run the *same prompt* at the final
   resolution — or edit the draft via `--previous-id` (edits are new
   generations and cost the same as a fresh clip at that resolution).
3. Tell the user the approximate spend when you hand over the clip.
