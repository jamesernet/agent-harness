---
name: plan-to-video
description: Turn an idea into a short video — Claude writes the storyboard as a shot plan, Google's Veo (Gemini API) renders each shot, and ffmpeg stitches them. Use when the user wants to make, generate, or storyboard a video, clip, explainer, trailer, promo or B-roll, mentions Veo or Gemini video, or asks to hand a plan to another model to render. Not for editing existing footage or making still images.
disable-model-invocation: true
---

# Plan to video

Claude does the part it is good at — structure, shot design, continuity — and
hands rendering to a model that is good at that. The plan is the contract
between them: a JSON file a human can read, edit and approve before any money
is spent.

```
brief  →  plan.json  →  check  →  user approves the price  →  render  →  review  →  stitch
          (Claude)      (free)                                 (Veo, billed)          (ffmpeg)
```

## Prerequisites

Check before planning, so a missing piece does not surface after the user has
approved a render:

- `uv` on PATH (resolves `google-genai` for `render`).
- `ffmpeg` on PATH (only for `stitch`).
- `GEMINI_API_KEY` in the environment, on a paid-tier key — Veo is not on the free tier.
  Do not read, print or write the key. If it is missing, ask the user to export it,
  e.g. from their password manager in the shell they run the session from.

## 1. Brief

Settle these before writing a shot. Ask only for what is missing:

- **Purpose and audience** — what the viewer should know or feel at the end.
- **Length and shape** — total seconds, aspect ratio (16:9 landscape, 9:16 vertical).
- **Look** — references, palette, live-action vs animated, mood.
- **Must-match assets** — a product, a person, a logo-free stand-in. These need
  reference images; text alone will not hold them steady across shots.

## 2. Plan

Create a working directory outside any repository unless the user names one
(the clips are large and billed; they do not belong in git). Write `plan.json`
there using [references/plan-format.md](references/plan-format.md). Start from
[references/example-plan.json](references/example-plan.json).

- One shot = one camera move + one action. Split anything longer.
- Put the shared look in `style`; keep per-shot prompts about what changes.
- Draft on `veo-3.1-fast-generate-preview` at 720p. Move to the full model or a
  higher resolution only for the final, and only by editing the plan.

Show the user the plan as a readable shot list (id, seconds, one-line action)
before moving on. Edits are free here and billed later.

## 3. Check, then get approval

```sh
python3 <skill>/scripts/video.py check plan.json
```

`check` validates the plan and reports exactly which shots would render and how
many seconds of video that is. Tell the user the model, the seconds, and that
Veo bills per second of output (point them to
https://ai.google.dev/gemini-api/docs/pricing — do not quote a price from
memory). **Wait for an explicit yes in chat.**

## 4. Render

```sh
uv run <skill>/scripts/video.py render plan.json --approve <N>s@<resolution>
```

`--approve` must be the exact token `check` printed. It carries the resolution
as well as the seconds, because the resolution sets the per-second rate and
lives in the plan file: the same total seconds at a higher resolution is a
different bill. If the plan changed after the user approved, the script refuses
— re-run `check` and ask again rather than adjusting the token yourself. Run it in the background; each shot takes from
seconds to several minutes.

Rendering is resumable and incremental: unchanged shots are skipped, edited
shots re-render. To redo one shot, edit it and render with `--only <id>`.

## 5. Review

Look at each clip before stitching. Extract a frame to inspect when needed:

```sh
ffmpeg -loglevel error -ss 4 -i out/shots/02-handoff.mp4 -frames:v 1 /tmp/frame.png
```

Report per shot: does it match the prompt, does it hold continuity with its
neighbours, is the audio right. Propose prompt edits for the failures; each
re-render goes back through check and approval.

## 6. Stitch

```sh
python3 <skill>/scripts/video.py stitch plan.json
```

Writes `out/<title-slug>.mp4`. Tell the user where it is. Do not upload,
publish or send it anywhere — that is the user's call.

## Boundaries

- Never render without an approval for that exact number of seconds.
- Never put the API key in the plan, the manifest, a command line or a file.
- `out/manifest.json` records the prompt, model and operation for every clip;
  keep it with the video so a shot can be reproduced or audited.
