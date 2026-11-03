# Setup: Gemini API key, SDK, billing

Read this when `scripts/check_setup.py` reports NOT READY, or the first time the
skill is used on a machine.

## 1. Get an API key

1. Open https://aistudio.google.com/apikey (Google account required).
2. Create an API key. It belongs to a Google AI Studio project; note which one.
3. Treat it like a password: never paste it into a file that gets committed.

## 2. Put the key in the environment

The SDK reads `GEMINI_API_KEY` automatically.

```bash
# current shell only
export GEMINI_API_KEY="AIza..."

# persist (zsh on macOS; use ~/.bashrc on Linux bash)
echo 'export GEMINI_API_KEY="AIza..."' >> ~/.zshrc && source ~/.zshrc
```

Per-project alternative: a `.env` file with `GEMINI_API_KEY=...`, loaded by
`direnv` or `set -a; source .env; set +a`. Add `.env` to `.gitignore`.

Ask the user to do this themselves. Do not ask them to paste the key into chat,
and do not write the key into project files.

## 3. Install the SDK

```bash
pip install --upgrade google-genai
```

The Interactions API (`client.interactions.create`) arrived in 2026; older
installs of `google-genai` will not have it, hence `--upgrade`.

Optional, for the animation QA step (frame capture) and GIF/MP4 export:

```bash
pip install playwright && playwright install chromium
# plus ffmpeg: brew install ffmpeg | apt install ffmpeg
```

## 4. Verify

```bash
python scripts/check_setup.py --ping --video
```

`--ping` makes one tiny call on a free-tier text model, so it costs nothing
and proves the key works. `--video` prints the billing note below.

## 5. Billing: what is free and what is not

| Use | Model | Free tier? | Rough cost |
|---|---|---|---|
| Animation code | `gemini-3.8-flash` | Yes (rate-limited) | fractions of a cent per brief |
| Image assets / keyframes | `gemini-nano-banana-2.1` | Limited | cents per image |
| **Video** | `gemini-omni-1.1-flash` | **No** | **~$0.03/s at 360p, ~$0.10/s at 720p, ~$0.15/s at 1080p, ~$0.30/s at 4K** |

Video generation requires billing enabled on the AI Studio project that owns
the key (AI Studio → project → billing). Until then video calls fail with a
quota/permission error; the fix is billing, not a different prompt.

Because of this, the video workflow drafts at 360p and only renders the final
at 720p+ once the prompt is right. Prices move; check
https://ai.google.dev/gemini-api/docs/pricing when it matters.

## 6. Where things land

- Outputs: `./motion/` by default (override with `--out`).
- Run log: `./.gemini-motion/runs.jsonl`, one line per generation with the
  prompt, settings, output path and `interaction_id`. The id is what lets a
  later call edit or extend a clip (`--previous-id`), so keep the log.
- Raw model reply for the last animation call: `./.gemini-motion/last_raw.txt`.

Add `.gemini-motion/` to `.gitignore` if the project is under version control.

## Troubleshooting

- `ImportError: google.genai` → step 3.
- `GEMINI_API_KEY is not set` → step 2 (new terminal windows need the export too).
- `403` / `PERMISSION_DENIED` / quota error on video only → billing (step 5).
- `429 RESOURCE_EXHAUSTED` on text/image → free-tier rate limit; wait a minute.
- `503 service_unavailable` ("experiencing high demand") → the model is
  overloaded, not your key. The scripts retry 429/503 four times with
  exponential backoff; if it still fails the spike is long-running. Either
  wait, or pass `--model gemini-3.5-flash-lite` for animation work — it is
  a separate capacity pool and has produced correct, brief-compliant output
  when `gemini-3.8-flash` was refusing every request.
- Video call returns no video and a text apology → safety filter; rephrase
  (no real people's likenesses, no minors, nothing violent or explicit).
- Region errors on editing *uploaded* videos → not available in the EEA, UK
  and Switzerland; editing clips the model generated still works.
