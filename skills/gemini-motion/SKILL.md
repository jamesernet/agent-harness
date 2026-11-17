---
name: gemini-motion
description: Make short videos (mp4 with audio) and small code animations (HTML/CSS/SVG/Lottie) with Google's Gemini API — Gemini Omni Flash for rendered video, Gemini 3.8 Flash for animation code, Nano Banana for image assets and keyframes. Use this whenever the user wants something that moves and mentions Gemini, Veo, Omni, Nano Banana or Google's models, or asks to make, render, animate, loop, edit or extend a short clip, reel, intro/outro, product shot, logo animation, loader, hero animation, explainer, trailer, promo, B-roll or GIF-style motion piece, or a longer video storyboarded shot by shot — even if they don't say "video" or "animation" explicitly. Also use it when a request needs an actual rendered clip (photoreal, cinematic, with sound) rather than code, since that requires the Omni video model.
---

# gemini-motion

Three ways to get motion out of Gemini, one shared setup. Claude is the director
and reviewer; Gemini does the rendering or writes the keyframes.

| Path | Produces | Model | Cost | Reach for it when |
|---|---|---|---|---|
| **A. Rendered video** | .mp4, 3–10 s (one take extends to 30 s), native audio | `gemini-omni-1.2-flash` | **paid only**, ~$0.023/s draft, ~$0.07/s at 720p | photoreal or cinematic, live-action feel, sound, "a video of …", social clips, something a browser can't draw |
| **B. Code animation** | one self-contained .html / .svg / Lottie .json | `gemini-3.8-flash` | free tier | UI motion, logos, loaders, hero backgrounds, diagrams that animate, anything that ships inside a web page or app |
| **C. Storyboard** | one stitched .mp4 from several 3–10 s shots | `gemini-omni-1.2-flash` | **paid only**, A's rates, priced for the whole plan before anything renders | anything over 10 s, several scenes, explainers, trailers, promos, B-roll |
| (all) **Assets / keyframes** | .png | `gemini-nano-banana-2.1` | cents | a first/last frame for a video, a sprite or illustration for an animation |

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
   with the exact token it printed. The token is `<seconds>s@<resolution>`,
   and it carries both because the per-second rate is nine times higher at 4k
   than at 360p — an approval that named seconds alone was satisfied by a far
   more expensive render. `--duration` pins the length so the approval is for
   the seconds you meant rather than the 15 s worst case (unpinned, the model
   follows a length the prompt names, up to 15 s).
   ```bash
   python <skill>/scripts/generate_video.py --prompt-file motion/x-prompt.txt --draft --aspect 9:16 --duration 6 --out motion/x-draft.mp4
   # -> this render bills 6s at 360p, about $0.14 / approve with: --approve 6s@360p
   python <skill>/scripts/generate_video.py --prompt-file motion/x-prompt.txt --draft --aspect 9:16 --duration 6 --approve 6s@360p --out motion/x-draft.mp4
   ```
   Watch it (Read the file or send it to the user). Judge: subject right,
   motion right, single shot if asked, audio as specified, no stray text.
4. **Fix with an edit turn or a new draft.** Small change on an otherwise good
   clip → `--previous-id <id>` with a short instruction ending "Keep
   everything else the same." Leave `--task` unset, as Google advises, since
   it adds constraints. Unset, the prompt decides whether the turn edits or
   extends, so the gate quotes it as an extend (30 s). For a plain edit with
   no `--image`, `--task edit` brings the quote down to one clip (15 s); the
   gate takes that flag at its word, as it does `--output-seconds`. Wrong
   concept → fix the prompt file and draft again. Two or three drafts is
   normal; tell the user the running spend.
5. **Final.** Same prompt at `--resolution 720p` (or 1080p/4k if they need
   it; both are upscales). More than 10 s → path C, a storyboard of separate
   shots. Extend with `--previous-id` + "Extend this video: …" only for one
   continuous take that cannot be cut, and only up to 30 s.

   **An extend is priced by the whole clip, not the part added.** The rate is
   per second of output and an extend returns the finished video, so a second
   extend of a 20-second clip is a 30-second bill. The gate prices that path at
   the 30 s ceiling unless you pass `--output-seconds` with the finished
   length. A clip passed with `--video` is priced the same way. That ceiling
   is the conservative reading rather than a measured
   invoice: if Omni turns out to bill only the increment, the gate overstates,
   which is the direction to be wrong in. Tell the user which number they are
   approving and why it looks large.
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
   and Read the PNGs. The summary says how many frames are DISTINCT; if that is
   1, nothing moved and the capture is worthless whatever it looks like. A
   JS-driven animation needs a `window.__seek(ms)` hook in the page or the
   capture falls back to wall-clock timing — ask for it in the brief. No
   Playwright → read the code against the brief and say so. Check: nothing
   extra, timeline matches, loop seamless, no external URLs, reduced-motion
   branch present.
5. **Iterate** with `--previous-id`, one concrete change per turn. If a fix is
   a two-line edit, make it yourself and say you did.
6. **Hand over:** file path, how to embed it (one line), brief path,
   interaction id, what was verified and how. Need an mp4/gif of it →
   `snapshot_animation.py --fps 24 --mp4 out.mp4` (needs Playwright + ffmpeg).

## C. Storyboard (several Omni shots, stitched)

For anything longer than one clip: a JSON plan of independent shots, each one
billed Omni call, stitched with ffmpeg. Read `references/storyboard-plan.md`
before writing the plan and start from `references/storyboard-example.json`.
Shots are not chained as extends, because an extend bills the whole output on
every turn.

1. **Write the plan** to `plan.json` in its own directory, outside any
   repository unless the user names one, next to the images it uses. One
   camera move per shot, 3–10 s each, one resolution and aspect for the plan.
   Shared look and audio go in `style`. Continuity comes from `first_frame` /
   `last_frame` stills and the same `images` on every shot that shows the
   subject, so make those with `generate_image.py` first when they matter.
2. **Price it.** Set `"resolution": "360p"` for drafts and run
   `storyboard.py check plan.json`. It validates the plan, then prints a line
   per shot, the total seconds, a dollar estimate and the full `render` command
   with its token, `<total>s@<resolution>`. Show the user that output and get a
   real yes.
   ```bash
   python <skill>/scripts/storyboard.py check motion/launch/plan.json
   # -> to render: 3 shots, 18s at 360p, about $0.41 / approve with: … render … --approve 18s@360p
   ```
3. **Render** with the printed command, in the background: it takes minutes.
   Only shots that are missing or changed are billed. An untouched shot is
   never rendered again, wherever it moves in the plan. After an interrupted
   run the old token is refused, because the price now covers only the shots
   still missing: run `check` again and get a yes for that smaller figure.
   A shot that rendered but was not saved shows as "billed, not saved", and
   `render` fetches it free; when nothing else is pending it needs no token.
4. **Fix a shot** by editing it, then `check --only <id>` and render with the
   token that prints. Editing `style` changes every shot, so it re-bills the
   whole plan, and `--only` cannot avoid that: `stitch` refuses until every
   shot matches the new style. Say so before doing it.
5. **Final.** Set the plan's `resolution` to 720p or higher and `check` again.
   Every shot is pending again, since resolution is part of each shot's spec,
   so the final costs the full plan at the new rate. Get the yes, render, then
   `storyboard.py stitch plan.json` writes `out/<title-slug>.mp4` (needs
   ffmpeg). `out/` sits next to the plan and keeps itself out of git.
6. **Hand over:** the stitched file, the plan path, what was billed in total,
   and the SynthID note if it's going somewhere public.

## Things that keep this from going wrong

- **Don't write the animation yourself and call it the skill.** The point is
  delegating the generation to Gemini and spending the effort on the brief and
  the review. Hand-edits are for the last 10%.
- **Don't spend on video until the user knows it's paid.** The `--approve`
  gate enforces this rather than trusting you to remember: a render refuses
  until the price it will bill — the seconds *and* the resolution — is
  confirmed back to it, and changing either one after the user looked stops the
  render rather than re-pricing it silently. Draft at 360p; the first 720p
  render should be the one you expect to keep. The billed call also runs with
  the SDK's retries off, so a lost response cannot be charged twice.
- **A clip that rendered but failed to save is not lost.** Its interaction id
  is logged before the download starts, and the error prints a `--fetch` command
  that collects it without billing again (not after `--no-store`). Run that, not
  the render. `--timeout` bounds the render; `--delivery-timeout` bounds the
  wait and download after it.
- **Don't promise what Omni can't do:** >15 s in one shot (and this script
  pins at most 10; longer is path C), exact dialogue
  edits, voice changes, prepending/mid-clip edits, real-person likenesses,
  minors, precise frame-accurate sync. Say so early and offer the nearest thing.
- **Keep the thread, but don't depend on it.** Chaining `--previous-id` is
  far cheaper than regenerating — 28 s against 150 s in one measured case,
  and it edits surgically instead of reinterpreting the whole brief. But it
  pins you to the model that started the thread, so when that model degrades
  iteration is simply unavailable. The brief is the recovery path; keep it.
  The log keeps itself out of git; see references/setup.md.
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
- `scripts/storyboard.py` — a plan of shots → priced, rendered, resumable, stitched mp4 (`check`, `render`, `stitch`)
- `scripts/generate_animation.py` — brief → .html / .svg / Lottie .json; iterate via `--previous-id`
- `scripts/generate_image.py` — Nano Banana stills for keyframes and sprites
- `scripts/snapshot_animation.py` — frames/mp4/gif from an HTML or SVG animation (Playwright, ffmpeg)
- `scripts/gemini_common.py` — shared client, content blocks, logging, and the one billed video call (approval token, `render_clip`)
- `references/setup.md` — key, SDK, billing, troubleshooting
- `references/video-prompting.md` — Omni prompt recipe, flags, editing/extending, limits, cost
- `references/storyboard-plan.md` — the plan format, continuity, cost and approval, resume
- `references/storyboard-example.json` — a three-shot plan to start from
- `references/animation-brief.md` — brief template, format choice, QA checklist, assets
