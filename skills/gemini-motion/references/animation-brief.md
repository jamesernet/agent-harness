# Code animations with Gemini: the brief, the review, the formats

Model: `gemini-3.8-flash` (free tier, fast, good at HTML/CSS/SVG). The script
`scripts/generate_animation.py` wraps it with a system instruction that forces
a single self-contained file, named tunables, reduced-motion support, and
"code only" output, then extracts the code block and saves it.

Your job is director and QA. Gemini's job is the keyframes.

## 1. Write the brief (this is most of the work)

Vague briefs get generic bounces. Write it like a spec for a motion designer
who can't ask questions. Save it as `motion/<name>-brief.md` so the user can
tweak and re-run.

```markdown
# <Name>  (e.g. "Hero logo breathe")

Purpose: where it lives and what it should make the viewer feel.
  "Website hero, behind the headline. Calm, premium, barely-there."

Canvas: 800x450 (scales to container); transparent background.
Duration: 4 s, loops seamlessly (last frame == first frame).
Elements:
  - logo.svg (asset): centred, 240 px wide
  - soft radial glow behind it, #7FD1C9 at 35% opacity
Timeline:
  0.0–2.0 s  logo scales 1.00 -> 1.03, glow opacity 0.35 -> 0.55  (ease-in-out)
  2.0–4.0 s  reverse of the above
Easing: cubic-bezier(0.45, 0, 0.55, 1) throughout; no linear.
Constraints:
  - CSS only if possible (no JS)
  - respect prefers-reduced-motion: show the static logo
  - expose --duration, --glow-color, --scale-max on :root
Do not: add particles, text, extra shapes, or sound.
```

Checklist of things that go wrong when left out:
- Canvas size / aspect and whether it scales.
- Duration and loop behaviour (seamless loop vs. play-once vs. hover-triggered).
- A timeline with numbers. "Fades in" means nothing; "opacity 0→1 over 0.4 s
  starting at 0.2 s" means one thing.
- Easing. Default browser easing reads cheap; name a curve.
- Which assets exist (pass them with `--asset`; Gemini sees the images and
  references them by filename, and the script inlines them as data URIs).
- The "do not" list — the model's instinct is to add flourish.

Pull colours, fonts and sizes from the user's project when it exists
(`:root` variables, Tailwind config, a design-system artifact) rather than
inventing them.

## 2. Pick a format

| `--format` | Use when | Output |
|---|---|---|
| `html` (default) | web pages, Storybook, anything that will be embedded or opened in a browser | one .html, inline `<style>`/`<script>` |
| `svg` | icons, logos, loaders, anything that must scale or live in a `<img>`/React | standalone .svg with CSS or SMIL animation |
| `lottie` | the user's stack has Lottie (mobile apps, After Effects workflow), or they asked for "a Lottie/JSON animation" | bodymovin JSON, validated as JSON |

If the user needs a *file they can post* (mp4/gif) from a code animation, it's
`snapshot_animation.py --fps 24 --mp4 out.mp4` after the HTML is right. For
anything cinematic or photoreal, it should have been the video path instead.

## 3. Generate, then actually look at it

```bash
python scripts/generate_animation.py --brief-file motion/hero-brief.md \
  --asset logo.svg --out motion/hero.html
python scripts/snapshot_animation.py motion/hero.html --duration 4 --frames 6
```

Then open the frame PNGs with the Read tool and check against the brief:

- [ ] Right elements, nothing extra (no surprise gradients, text, shadows).
- [ ] Timing matches the timeline (frame at 2 s should be the peak, etc.).
- [ ] Loop is seamless. Don't eyeball it, and don't stop at the hash either.
      `--frames N` over `--duration D` captures t=0 and t=D inclusive, so a
      closed loop gives two identical end frames: `md5 -r frames/*.png`
      (macOS) or `md5sum frames/*.png` (Linux), compare first against last.
      Matching hashes mean it closes exactly; stop there.
      Differing hashes are a question, not a verdict — anti-aliasing alone
      changes a hash. Measure before you act on it:
      `ffmpeg -i frames/frame_0000.png -i frames/frame_000N.png -lavfi psnr -f null -`
      `inf` is exact. Above ~50 dB is visually lossless: real, invisible, not
      worth an iteration. Below ~40 dB is a snap the viewer will see; fix that
      one. Measured here: a model that scored 83 dB looked flawless beside one
      that scored `inf`. A whole iteration was spent asking for the endpoints
      to match exactly; the CSS keyframes were already symmetric (0% and 100%
      identical), the model rewrote the middle, and the number did not move at
      all. Above ~50 dB you are looking at how the browser rasterises t=0
      against the wrapped end frame, not at anything the animation controls.
      Re-prompting cannot fix it. Accept it and move on.
- [ ] Colours/sizes match the project's values.
- [ ] Reduced-motion branch exists (`@media (prefers-reduced-motion: reduce)`).
- [ ] No external URLs. Grepping for `http` alone gives a false positive on
      every SVG, whose namespace is literally `http://www.w3.org/2000/svg`.
      Match what actually fetches:
      `grep -nE '(src|href)="https?://|@import|@font-face' motion/hero.html`
- [ ] File opens with no console errors (snapshot will usually surface a
      blank frame if the script crashed; check `.gemini-motion/last_raw.txt`
      if the output looks truncated).

If frame capture isn't available (no Playwright), read the code instead and
reason about the keyframes; tell the user it was reviewed by reading, not by
rendering, and suggest they open the file.

## 4. Iterate with context, not from scratch

```bash
python scripts/generate_animation.py "Loop isn't seamless: the glow snaps at 4s. \
Make the glow keyframes symmetric so frame 0 == frame 4s. Change nothing else." \
  --previous-id v1_... --out motion/hero.html
```

One concrete change per turn, say what to keep. Two or three turns is normal;
if it's not converging by the fourth, the brief is under-specified — fix the
brief and start a fresh interaction.

When Gemini's output is 90% right, it's faster to make the last fix yourself
with the Edit tool than to spend another turn. Say in the hand-over which
parts came from Gemini and which you edited.

## 5. Assets from Nano Banana

When the animation needs an illustrated element that doesn't exist yet
(a mascot, a stylised background, a product render), make it first:

```bash
python scripts/generate_image.py "flat vector illustration of a paper plane, \
single teal (#2A9D8F) on white, thick rounded outlines, no shadow" \
  --aspect 1:1 --out motion/plane.png
```

Ask for a plain white or flat background; real transparency isn't offered, so
for cut-outs either keep the background colour in the animation or remove it
afterwards (e.g. with `rembg` or a quick threshold in Pillow). Sprite sheets
work: "a 4-frame walk cycle laid out horizontally, equal cells" then animate
`background-position` in CSS.

## 6. What to hand back

- The file path(s), what format, and the one-line way to use it
  (`<img src="pulse.svg">`, `<iframe>`, Lottie player snippet).
- The brief path, so they can re-run.
- The interaction id, so the next session can continue the thread.
- What you verified (rendered frames vs. read-through), and anything you
  changed by hand after Gemini.
