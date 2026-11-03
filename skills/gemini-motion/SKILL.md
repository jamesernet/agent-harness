---
name: gemini-motion
description: Make short videos (mp4 with audio) and small code animations (HTML/CSS/SVG/Lottie) with Google's Gemini API — Gemini Omni Flash for rendered video, Gemini 3.8 Flash for animation code, Nano Banana for image assets and keyframes. Use this whenever the user wants something that moves and mentions Gemini, Veo, Omni, Nano Banana or Google's models, or asks to make, render, animate, loop, edit or extend a short clip, reel, intro/outro, product shot, logo animation, loader, hero animation, explainer or GIF-style motion piece — even if they don't say "video" or "animation" explicitly. Also use it when a request needs an actual rendered clip (photoreal, cinematic, with sound) rather than code, since that requires the Omni video model.
---

# gemini-motion

Two ways to get motion out of Gemini, one shared setup. Claude is the director
and reviewer; Gemini does the rendering or writes the keyframes.

| Path | Produces | Model | Cost | Reach for it when |
|---|---|---|---|---|
| **A. Rendered video** | .mp4, 3–10 s (extend to 40 s), native audio | `gemini-omni-1.1-flash` | **paid only**, ~$0.03/s draft, ~$0.10/s at 720p | photoreal or cinematic, live-action feel, sound, "a video of …", social clips, something a browser can't draw |
| **B. Code animation** | one self-contained .html / .svg / Lottie .json | `gemini-3.8-flash` | free tier | UI motion, logos, loaders, hero backgrounds, diagrams that animate, anything that ships inside a web page or app |
| (both) **Assets / keyframes** | .png | `gemini-nano-banana-2.1` | cents | a first/last frame for a video, a sprite or illustration for an animation |

If the request fits both ("an animated logo for our launch video"), ask one
question — *where will it play?* A web page → B. A video timeline/social post
→ A (or B rendered to mp4 with `snapshot_animation.py`). Don't build both.

## 0. Before the first call in a session

```bash
python <skill>/scripts/check_setup.py --ping          # text/animation work
python <skill>/scripts/check_setup.py --ping --video  # video work: prints billing note
```

NOT READY → read `references/setup.md` and walk the user through it (key from
aistudio.google.com/apikey, `export GEMINI_API_KEY`, `pip install --upgrade
google-genai`, billing for video). Ask the user to set the key themselves;
never ask them to paste it into chat or write it into a project file.

Video has no free tier and bills from the first clip, so before the first
video generation tell the user roughly what the plan will cost (see the table)
and that drafts run at 360p. If they haven't enabled billing, that's the
blocker — not the prompt.

All scripts log to `./.gemini-motion/runs.jsonl` (prompt, settings, output
path, `interaction_id`). The id is how a later turn edits or extends a result.

## A. Rendered video (Omni Flash)

Read `references/video-prompting.md` before writing the first prompt; the
recipe and limits there are what separate a usable clip from a generic one.

1. **Write the shot.** Turn the request into a prompt covering shot/camera,
   subject & action, setting & light, style, audio, structure (single shot or
   timecodes), negatives, length and orientation. Save it to
   `motion/<name>-prompt.txt` so it can be re-run and tweaked.
2. **Assets if needed.** A specific product, character or exact framing →
   `generate_image.py` for a first frame or reference, then pass it with
   `--first-frame` / `--image`. The user's own images are fine too (not real
   people's likenesses, not minors).
3. **Draft cheap.** Run it once without `--approve`: it prints what the render
   will bill and refuses. Show the user that line, get a real yes, then re-run
   with the number it gave you. `--duration` pins the length so the approval is
   for the seconds you meant rather than the 10 s worst case.
   ```bash
   python <skill>/scripts/generate_video.py --prompt-file motion/x-prompt.txt --draft --aspect 9:16 --duration 6 --out motion/x-draft.mp4
   # -> this render bills 6s at 360p, about $0.18 / approve with: --approve 6
   python <skill>/scripts/generate_video.py --prompt-file motion/x-prompt.txt --draft --aspect 9:16 --duration 6 --approve 6 --out motion/x-draft.mp4
   ```
   Watch it (Read the file or send it to the user). Judge: subject right,
   motion right, single shot if asked, audio as specified, no stray text.
4. **Fix with an edit turn or a new draft.** Small change on an otherwise good
   clip → `--previous-id <id>` with a short instruction ending "Keep everything
   else the same." Wrong concept → fix the prompt file and draft again. Two or
   three drafts is normal; tell the user the running spend.
5. **Final.** Same prompt at `--resolution 720p` (or 1080p/4k if they need
   it; both are upscales). Extend with `--previous-id` + "Extend this video:
   …" when they need more than 10 s, up to 40 s.
6. **Hand over:** file path, prompt path, interaction id, resolution/aspect,
   approximate cost, and the SynthID note if it's going somewhere public.

## B. Code animation (Gemini 3.8 Flash)

Read `references/animation-brief.md` first; the brief template and QA checklist
are the method.

1. **Write the brief** to `motion/<name>-brief.md`: purpose, canvas, duration
   and loop behaviour, elements, a numbered timeline, easing, constraints, a
   "do not" list. Pull colours/sizes from the user's project if one exists.
   Give geometry in the output format's own terms (`<rect x= y= width=
   height=>`), never as centres to be converted — that conversion is where
   positional defects come from. Anything over ~10 s should be a set of
   scenes; see `references/animation-brief.md`.
2. **Assets.** Existing images → `--asset path` (Gemini sees them; the script
   inlines them as data URIs). Missing illustration → `generate_image.py`
   first.
3. **Generate.**
   ```bash
   python <skill>/scripts/generate_animation.py --brief-file motion/x-brief.md --asset logo.svg --out motion/x.html
   ```
   `--format svg` for scalable icons/loaders, `--format lottie` only when the
   user's stack is Lottie.
4. **Look at it.** `snapshot_animation.py motion/x.html --duration 4 --frames 6`
   and Read the PNGs. No Playwright → read the code against the brief and say
   so. Check: nothing extra, timeline matches, loop seamless, no external
   URLs, reduced-motion branch present.
5. **Iterate** with `--previous-id`, one concrete change per turn. If a fix is
   a two-line edit, make it yourself and say you did.
6. **Hand over:** file path, how to embed it (one line), brief path,
   interaction id, what was verified and how. Need an mp4/gif of it →
   `snapshot_animation.py --fps 24 --mp4 out.mp4` (needs Playwright + ffmpeg).

## Things that keep this from going wrong

- **Don't write the animation yourself and call it the skill.** The point is
  delegating the generation to Gemini and spending the effort on the brief and
  the review. Hand-edits are for the last 10%.
- **Don't spend on video until the user knows it's paid.** The `--approve`
  gate enforces this rather than trusting you to remember: a render refuses
  until the seconds it will bill are confirmed back to it. Draft at 360p; the
  first 720p render should be the one you expect to keep.
- **Don't promise what Omni can't do:** >10 s in one shot, exact dialogue
  edits, voice changes, prepending/mid-clip edits, real-person likenesses,
  minors, precise frame-accurate sync. Say so early and offer the nearest thing.
- **Keep the thread, but don't depend on it.** Chaining `--previous-id` is
  far cheaper than regenerating — 28 s against 150 s in one measured case,
  and it edits surgically instead of reinterpreting the whole brief. But it
  pins you to the model that started the thread, so when that model degrades
  iteration is simply unavailable. The brief is the recovery path; keep it.
  Keep `.gemini-motion/runs.jsonl` out of git.
- **Never pass `--model` on a fresh generation.** An explicit model is
  honoured literally and disables the fallback chain, which turns a
  recoverable 503 into a dead run. Pin the model only when continuing a
  thread with `--previous-id`, where it is required.
- **Expect the direction to be wrong, not the generation.** Across a dozen
  generations in one project the model produced exactly what each brief
  specified every time, including faithfully executing the bad ones. Every
  defect in the output traced to the brief. Budget accordingly: the time goes
  into specifying and verifying, not into fighting the generator.
- **Verify by rendering.** Grep the output for forbidden content and required
  tunables, then settle every positional question with a captured frame.
  Source checks say a value exists; only the render says where it landed.
  See `references/animation-brief.md` for the full ordering.
- **Safety filters return no video and a polite text.** Rephrase; don't
  retry the same prompt.
- **Scripts over ad-hoc code.** The scripts handle key loading, file upload,
  URI delivery for big outputs, code extraction and logging. If a flag is
  missing, add it to the script rather than writing a one-off.

## Files in this skill

- `scripts/check_setup.py` — readiness check (`--ping`, `--video`)
- `scripts/generate_video.py` — text/image/keyframes → mp4; edit/extend via `--previous-id` or `--video`
- `scripts/generate_animation.py` — brief → .html / .svg / Lottie .json; iterate via `--previous-id`
- `scripts/generate_image.py` — Nano Banana stills for keyframes and sprites
- `scripts/snapshot_animation.py` — frames/mp4/gif from an HTML or SVG animation (Playwright, ffmpeg)
- `scripts/gemini_common.py` — shared client, content blocks, logging
- `references/setup.md` — key, SDK, billing, troubleshooting
- `references/video-prompting.md` — Omni prompt recipe, flags, editing/extending, limits, cost
- `references/animation-brief.md` — brief template, format choice, QA checklist, assets
