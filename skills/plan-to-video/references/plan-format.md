# Plan format

`plan.json` lives in its own working directory, next to any images it names.
Paths in the plan are relative to that directory. `scripts/video.py check`
validates everything below; this file explains the choices.

```json
{
  "title": "Harness in sixty seconds",
  "model": "veo-3.1-fast-generate-preview",
  "aspect_ratio": "16:9",
  "resolution": "720p",
  "style": "Clean studio lighting, muted palette, shallow depth of field, no on-screen text.",
  "negative_prompt": "logos, watermarks, captions",
  "shots": [
    {
      "id": "open",
      "duration": 8,
      "prompt": "Slow dolly-in on a laptop on an oak desk at dawn; the screen glows with scrolling terminal text. Soft keyboard clicks, distant birdsong."
    },
    {
      "id": "handoff",
      "duration": 6,
      "image": "frames/handoff-start.png",
      "prompt": "The camera tilts up from the laptop to a window as morning light floods the room. Low ambient hum."
    }
  ]
}
```

## Top level

| field | required | values | note |
|---|---|---|---|
| `title` | yes | text | names the stitched file (`out/<slug>.mp4`) |
| `model` | yes | `veo-3.1-generate-preview`, `veo-3.1-fast-generate-preview`, `veo-3.1-lite-generate-preview` | draft on fast or lite; render the final on the full model |
| `aspect_ratio` | no | `16:9` (default), `9:16` | one per plan; mixed ratios do not stitch |
| `resolution` | no | `720p` (default), `1080p`, `4k` | 1080p and 4k require 8-second shots; lite has no 4k |
| `style` | no | text | appended to every shot prompt — the main lever for consistency |
| `negative_prompt` | no | text | what to keep out; a shot can override it |

## Shot

| field | required | note |
|---|---|---|
| `id` | yes | lowercase, digits, hyphens; stable across edits, since the manifest keys on it |
| `prompt` | yes | one shot, one camera move, one action — see below |
| `duration` | no | 4, 6 or 8 seconds (default 8) |
| `image` | no | starting frame; locks composition and character between shots |
| `last_frame` | no | ending frame; needs `image`; Veo interpolates between the two |
| `references` | no | up to 3 asset images (a product, a character, a garment); needs duration 8 |
| `negative_prompt` | no | overrides the plan's |

## Writing a shot prompt

Veo reads a prompt as a single continuous shot. Write it in this order:

1. **Camera** — framing and movement: "wide static shot", "slow dolly-in", "handheld tracking".
2. **Subject** — who or what, with the details that must stay the same across shots.
3. **Action** — one thing that happens. Two actions in eight seconds usually blur.
4. **Setting and light** — place, time of day, light source.
5. **Sound** — Veo generates audio on every clip. Name the ambient sound; put any
   dialogue in quotes with the speaker: `The engineer says, "It's green."`

Keep shared detail in `style`, not repeated per shot — repetition drifts as it is edited.

## Keeping shots consistent

Text alone will not hold a character's face or a product's shape across clips. In order of strength:

- `references` — the same asset images on every shot that shows the asset.
- `image` — a starting frame per shot, generated once and reused.
- `style` — palette, lens and lighting words shared by every prompt.

For a starting frame, generate a still first (an image model, a screenshot, a
photo) and save it under `frames/`.

## Limits worth knowing

- 24 fps; clips are 4, 6 or 8 seconds.
- Generation takes from about 10 seconds to several minutes per clip.
- Google keeps generated clips for two days; the script downloads them immediately.
- Shots blocked by safety filters return no video and are not billed — revise the prompt.
- Image-to-video and reference shots permit adults only, and some regions restrict people further.
