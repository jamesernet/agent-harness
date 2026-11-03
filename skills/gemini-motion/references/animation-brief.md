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

### Geometry: write it the way the format stores it

Every positional defect in this skill's history came from a brief that made
the model convert something. Give coordinates in the output format's own
terms and there is nothing to get wrong.

- **SVG rects are positioned by top-left, so say that.**
  `<rect x="225" y="202" width="150" height="96">` has one reading.
  "Centred at (300,250), 150x96" has two, and both are internally consistent
  — which is why it passes review. Measured: the same brief run twice put the
  card at y=202 once and y=250 the other time, a 48px drift that only showed
  when two scenes were stitched together.
- **Forbid group transforms when you give absolute baselines.** A model that
  wraps a panel in `<g transform="translate(93,150)">` *and* uses your
  `y="182"` baseline pushes every line 150px down, outside its own panel. The
  source greps clean — the numbers are all present and correct — and the
  render is broken. Say: absolute attributes only, no `<g transform>`.
- **Sum the vertical budget before writing a line of it.** List every
  element's y-extent and look for overlaps. Five separate collisions in one
  project, every one of them arithmetic that a minute of adding would have
  caught: a figure at y=380..452 under a caption at y=440; an outcome row at
  y=440..480 under a caption at y=500.
- **"Behind", "above" and "next to" are not positions.** They describe
  z-order or vibe and the model will pick a number for you. A house "behind
  the seller" at the seller's own x lands on top of him.

### Say what the thing must MEAN, then check the final frame alone

A brief can be perfectly specified and still lose the point. Two real cases:
a browser window was told to restyle into a plain card, which erased the one
fact the scene existed to show — that your website is now just one source
among several. Three identical cards say "an agent reads three sources"; they
cannot say "and one of them is yours."

After writing a brief, read only the final-state description and ask whether
the argument is visible in that frame with no motion and no caption. The hold
at the end is the frame people take away, so it has to carry the whole thing
unaided.

Pull colours, fonts and sizes from the user's project when it exists
(`:root` variables, Tailwind config, a design-system artifact) rather than
inventing them.

## 1b. When it looks flat

"Make it more sophisticated" is almost never a motion problem, and adding
movement makes it worse. In a side-by-side test the same scene went from
reading as a diagram to reading as a product, and the levers that did it,
in order of how much each mattered:

1. **Real content instead of abstractions.** Swap featureless bars for actual
   strings: "Open - 9am-5pm", "last edited 3 years ago", "Could not verify".
   Text carries meaning that shapes cannot, and incidental detail does
   explanatory work for free — a staleness line explains a whole discrepancy
   without a word of narration.
2. **Filled surfaces, not outlines.** A panel with a fill, a 1px border and
   an internal divider reads as a surface. Outlines floating on a dark
   background read as a sketch.
3. **Type hierarchy.** Three weights and sizes per card — label, value,
   detail — gives the eye a path. Flat type is most of why a frame feels
   cheap.
4. **Density.** Four cards of five lines each is ~20 elements where an
   abstract version has six. Density reads as considered when it is
   organised.
5. **Micro-motion, last.** A highlight sweep and a 6px settle per line,
   staggered, beat any amount of whole-object travel. Sophisticated motion is
   many small simultaneous settlements, not big movement.

Ban the icon set explicitly — magnifying glass, microphone, speech bubble,
robot, map pin, stars. Icons are where this aesthetic turns generic, and
labels carry it better.

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


**Grep first, but never grep last.** Source checks tell you a string is
present or absent — they are good for forbidden content and required
tunables, and useless for position. In one project, loose substring greps
produced five false positives ("Roboto" matching /robot/, "Grouped" matching
/red/, the SVG namespace matching /http/, `width="70"` missing a CSS
`width: 70px`, and an attribute check missing an equivalent group transform)
and one true positive that got talked away because the numbers matched. Use
word boundaries, and settle every positional question by rendering a frame
and looking at it.

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

## 5b. Building a set of scenes

Anything past about 10 seconds should be scenes, both because the model holds
a short brief far better and because scenes are independently reviewable and
re-runnable.

- **Write the argument in four sentences first.** Problem, why it persists,
  what changes, what you get. One scene each. If it will not compress to four
  sentences there is no piece in it.
- **One idea per scene, 4-12 s each.** Not four shots of one idea.
- **Every scene opens and closes on the same frame.** Then each loops
  standalone for QA, and they stitch with no jump. Verify with the hash test.
- **Write every brief in the set before generating any of them.** Shared
  geometry has to be identical across briefs, and it is far easier to keep
  consistent while writing than to reconcile afterwards.
- **Make scenes rhyme on purpose.** Reusing an earlier scene's exact layout
  for the payoff lets the viewer recognise the frame and read what changed,
  instead of parsing a new picture. It is the cheapest way to make an ending
  land, and it only works if the coordinates are literally identical.
- **Regeneration is not idempotent.** The same brief can produce different
  geometry on a different run. If you regenerate one scene, re-audit all of
  them against the shared anchors — and audit by rendering, not by grepping.
- **Stitch with the mp4 export**, then `ffmpeg -f concat`. Verified: duration
  and frame count come out exact, so seams land where the arithmetic says.

Keep the briefs. The HTML is disposable and regenerable; the brief is the
asset. This matters operationally, not just tidily: `--previous-id` needs the
model that started the thread, so when that model degrades — which happened
twice in one session — iteration is simply unavailable and the brief is the
only way back.

## 6. What to hand back

- The file path(s), what format, and the one-line way to use it
  (`<img src="pulse.svg">`, `<iframe>`, Lottie player snippet).
- The brief path, so they can re-run.
- The interaction id, so the next session can continue the thread.
- What you verified (rendered frames vs. read-through), and anything you
  changed by hand after Gemini.
