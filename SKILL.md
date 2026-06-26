---
name: diarize-call
description: "Transcribes and summarizes recorded calls/meetings (OBS, Teams, Meet) or any video/audio file. Produces a speaker-diarized transcript, identifies real participant names by reading frames where Teams/Meet highlight who is speaking, and writes a narrative summary. Always use this skill when the user asks to transcribe, diarize, or summarize a call, meeting, recording, or names a video/audio file (mp4, mkv, webm, m4a, mp3) — even if they don't explicitly say 'diarize'. Typical triggers: 'transcribe this call', 'summarize the meeting', 'who said what in this video', 'give me a summary of this recording', 'diarize this'."
trigger: /diarize-call
---

# diarize-call

Transforms a meeting recording (video or audio) into: a speaker-diarized transcript with **real participant names**, and a narrative summary. Uses the bundled `diarize.js` (AssemblyAI / Gladia) for diarization, and Claude's vision to read name overlays from frames and understand context from shared screens.

## Prerequisites

No npm install needed. Only system tools required:

| Tool | Purpose | Install |
|------|---------|---------|
| `curl` | HTTP calls to API | usually pre-installed; `brew install curl` / `apt install curl` |
| `jq` | JSON parsing | `brew install jq` / `apt install jq` |
| `ffmpeg` + `ffprobe` | audio extraction, frame capture | `brew install ffmpeg` / `apt install ffmpeg` |
| `node` (v18+) | frame extraction script | `brew install node` / `apt install nodejs` |

The script checks for missing tools at startup and prints install instructions if any are absent.

**Required env vars** (add to `~/.bashrc` / `~/.zshrc` / your shell profile):
- `ASSEMBLYAI_API_KEY` — for AssemblyAI (default provider). Get one at assemblyai.com.
- `GLADIA_API_KEY` — if you prefer Gladia. Pass `--provider gladia` to use it.
- `DEEPGRAM_API_KEY` — if you prefer Deepgram Nova-3. Pass `--provider deepgram` to use it. Note: `--speakers`, `--speakers-min`, `--speakers-max`, and `--context` are ignored (Deepgram auto-detects speakers; use `--keyterms` for term boosting).

If the provider's API key is missing, stop and ask the user to set it before proceeding.

## Input to collect

At startup, ask the user (in a single message, not one question at a time) unless already provided:

1. **File** — path to the video/audio file.
2. **Number of speakers** — how many people speak actively (not just how many are present). Goes into `--speakers`. This is only a *hint*: AssemblyAI may detect more (very short interjections become separate speakers). Don't assume the final count matches.
3. **Language** — ISO language code (`en`, `it`, `fr`, ...). Goes into `--lang`. ⚠️ If the call is **multilingual or uncertain**, **omit `--lang`**: `diarize.js` does auto-detect, which is safer than forcing the wrong language (forcing `en` on a different-language call can hallucinate words). Only force `--lang` when you're sure it's monolingual.
4. **Context** — 1–3 sentences about what the call covers (project, client, topic). Greatly improves ASR accuracy. Goes into `--context`.
5. **Key terms** — technical terms, abbreviations, proper nouns, product names the ASR might mangle. Goes into `--keyterms`.

Context and key terms are the most effective lever for reducing errors: names of people, companies, and systems are frequently mangled by ASR. Politely insist on getting them.

## Output

Everything goes into a **dedicated subfolder** next to the input file, named after the file without extension (`<base>/`):

```
<dir-of-video>/<base>/
├── <base>-raw.md          # raw diarize.js output (Speaker A/B/...)
├── <base>-raw.json        # raw JSON (utterances with timestamps) — input for frames
├── frames/                # extracted frames (speaker_*.jpg, context_*.jpg)
├── manifest.json          # frame→speaker map and context frames
├── <base>-transcript.md   # final transcript with REAL NAMES
└── <base>-summary.md      # narrative summary
```

## Procedure

### 1. Diarization

Create the subfolder and run `diarize.js`:

```bash
mkdir -p "<dir>/<base>"
bash ~/.claude/skills/diarize-call/scripts/diarize.sh "<file>" \
  --out "<dir>/<base>/<base>-raw.md" \
  --speakers <N> \
  --lang <lang> \
  --context "<context>" \
  --keyterms "<t1,t2,...>"
```

Notes:
- `--out` with `.md` extension; the raw JSON is written alongside as `<base>-raw.json`.
- `--context` and `--keyterms` are combined into a single `prompt` field (universal3) — they work fine together.
- If the user also wants the provider's built-in summary, add `--summary`, but the real summary you write yourself in step 4 will be richer.
- The script checks for `curl`, `jq`, `ffmpeg`, `ffprobe` at startup and exits with install instructions if any are missing.

If the input is **audio-only**, skip steps 2–3 (no frames) and go straight to step 4, using Speaker A/B/... labels or asking the user for names.

### 2. Frame extraction (deterministic script)

Don't reinvent JSON parsing or ffmpeg commands: use the bundled script. It finds the longest utterance intervals per speaker (where the "X is speaking" overlay is most likely visible) and extracts context frames at an adaptive cadence.

```bash
node ~/.claude/skills/diarize-call/scripts/prepare_frames.js \
  --video "<file>" \
  --json "<dir>/<base>/<base>-raw.json" \
  --outdir "<dir>/<base>"
```

Produces `frames/` and `manifest.json`. The manifest lists, per speaker, frames in priority order (longest interval first) and context frames with their timestamps.

### 3. Name identification (vision)

Read `manifest.json`. This is the most delicate step — **don't trust a single frame/timestamp**. Proceed like this:

**a. Extract the full roster.** Open 1–2 context frames (`context_*.jpg`): the participants panel (right side in Teams, bottom in Meet) lists everyone's real name — this is the most reliable source. Note them all.

**b. Understand the layout.** Determine where the "who is speaking" indicator appears in this recording, since it varies:
- **Teams gallery / webcam view**: the active speaker's tile has a **colored border**; name is bottom-left of their tile.
- **Teams "light meeting" / screen share** (very common): the name **bottom-left of the shared content** is *who is sharing*, **not who is speaking** — it stays static, ignore it as a speaker indicator. The active speaker is the **tile with a colored border** in the participants strip, but **it lags and sometimes highlights two at once** → noisy signal.
- **Meet**: name bottom-left of the active tile; active tile is bordered in the grid.

**c. Vote across multiple frames + cross-check with transcript.** For each speaker look at all their frames (the script gives 2–3 intervals × 2 frames) and take the name that appears most often in the speaker indicator. Then **corroborate with the transcript**, which is often more decisive than pixels:
- Who **shares their screen** and is the main presenter (lots of speaking time, "I hope you can see my screen") → often identifiable and named by others;
- Who is **called by name** ("Can you show me that, Alex?") → that line or the one before identifies a speaker;
- Roles / language patterns (e.g., the client vs. the consultant).

**c-bis. Wrong capture.** Sometimes (especially with OBS) the video doesn't show the call UI at all but a different screen (desktop, IDE, wrong monitor): frames always show the same static content, no participants panel. In that case **don't persist with frames**: map names from the **transcript content alone** (see above) and **warn the user** that OBS recorded the wrong screen, so they can select the right window/monitor next time.

**d. Be honest about uncertainty.** Build the `Speaker A → Real Name` map only where you have convergence (frames + text). Normalize names (e.g., "SMITH John" → "John Smith"). Where there's no certainty, **leave "Speaker X" and flag it**, giving the user the roster so they can complete the mapping — a wrong name is much worse than an honest unknown. For short calls with few utterances it's normal to map only the main speaker(s) with confidence.

### 4. Final transcript + summary

**Transcript** (`<base>-transcript.md`): start from `<base>-raw.md` and replace every `Speaker A/B/...` with the real name from the map. Keep timestamps and text. If the ASR introduced obvious errors in names/terms that keyterms didn't fix, correct them consistently and add a note at the top.

**Summary** (`<base>-summary.md`): write a **narrative summary** in the same language as the call (or as requested by the user), reading the transcript and the context frames (`context_*.jpg`) to understand what was shown on screen. Use this structure:

```markdown
# <Call title> — Summary

## Context
## Goal of the call
## Points discussed
## Decisions made
## Actions / TODO
```

Context frames help disambiguate: if the transcript says "this" or "the screen" and a frame shows a dashboard or a document, name it explicitly. Refer to participants by their real names.

### 5. Wrap up

Tell the user: folder path, names identified (and which speakers you couldn't map), call duration, number of context frames analyzed. Ask if they want any adjustments to the name map or the summary.
