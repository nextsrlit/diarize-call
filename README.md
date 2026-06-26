# diarize-call

> Turn any Teams / Meet / OBS recording into a speaker-labeled transcript + summary. Claude Code skill, zero npm deps.

Given a meeting recording (video or audio), this skill:

1. Diarizes it via **AssemblyAI** or **Gladia** — no npm, pure curl
2. Extracts frames from the video and uses **Claude's vision** to identify real participant names from Teams/Meet overlays
3. Produces a clean **speaker-labeled transcript** and a **narrative summary**

## Features

- Works with Teams, Google Meet, OBS, or any video/audio file (mp4, mkv, webm, m4a, mp3, ...)
- Identifies real speaker names from video overlays — not just "Speaker A/B"
- Two diarization providers: AssemblyAI (default) and Gladia
- Context hints and key terms to improve ASR accuracy on technical content
- Zero npm dependencies — only `curl`, `jq`, `ffmpeg`, `node`

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| `curl` | API calls | usually pre-installed |
| `jq` | JSON parsing | `brew install jq` / `apt install jq` |
| `ffmpeg` + `ffprobe` | audio extraction, frame capture | `brew install ffmpeg` / `apt install ffmpeg` |
| `node` (v18+) | frame extraction script | `brew install node` / `apt install nodejs` |

The script checks for missing tools at startup and prints install instructions.

## API Key

Add to your shell profile (`~/.zshrc` or `~/.bashrc`):

```bash
# AssemblyAI (default) — get one at assemblyai.com
export ASSEMBLYAI_API_KEY=your_key_here

# Gladia (alternative) — get one at gladia.io
export GLADIA_API_KEY=your_key_here
```

## Installation

### Claude Code

Copy the skill into your global skills directory:

```bash
git clone https://github.com/fstrapp/diarize-call ~/.claude/skills/diarize-call
```

Claude Code will auto-discover it. Trigger by describing what you want:

> "Transcribe this call: /path/to/recording.mp4"
> "Summarize the meeting in ~/recordings/standup.m4a"

Or use the slash command: `/diarize-call`

### Codex

Clone the repo and reference the skill from your `AGENTS.md`:

```markdown
## Skills
See the instructions in ./diarize-call/SKILL.md for transcribing and diarizing meeting recordings.
```

```bash
git clone https://github.com/fstrapp/diarize-call
```

### Any other LLM CLI

Paste the contents of `SKILL.md` into your system prompt or instructions file.

## Usage

### Via Claude Code (automatic)

The skill triggers automatically whenever you describe a transcription or diarization task. No slash command needed — just talk to Claude:

> "Transcribe this call: /path/to/recording.mp4"
> "Who said what in last week's meeting? ~/recordings/standup.m4a"
> "Summarize the recording at ~/Downloads/call.m4a, there were 3 speakers"

Or invoke it explicitly with the slash command:

```
/diarize-call
```

Claude will then ask you — in a single message — for:
- **File path** of the recording
- **Number of speakers** (active speakers, not attendees)
- **Language** (or leave blank for auto-detect)
- **Context** and **key terms** to improve accuracy (optional but recommended)

From there everything runs automatically: diarization, frame extraction, speaker identification via vision, final transcript and summary.

### Standalone (bash)

```bash
# Basic
bash scripts/diarize.sh recording.mp4 --speakers 3

# With context and key terms (improves ASR accuracy significantly)
bash scripts/diarize.sh meeting.mp4 \
  --speakers 4 \
  --lang en \
  --context "Product roadmap review with engineering team" \
  --keyterms "Kubernetes, gRPC, SLA, Q3 OKRs"

# Gladia provider
bash scripts/diarize.sh recording.m4a --provider gladia --speakers 2

# Multiple audio files (concatenated automatically)
bash scripts/diarize.sh part1.mp3 part2.mp3 --out output.md
```

## Output

Everything is saved in a subfolder next to the input file:

```
recording/
├── recording-raw.md          # raw diarized transcript (Speaker A/B/...)
├── recording-raw.json        # raw API response with timestamps
├── frames/                   # extracted video frames
│   ├── speaker_A_iv1_1.jpg   # frames for speaker identification
│   └── context_001500.jpg    # context frames (shared screens, etc.)
├── manifest.json             # frame map for vision analysis
├── recording-transcript.md   # final transcript with real names
└── recording-summary.md      # narrative summary
```

## Options

```
--provider <name>        assemblyai (default) or gladia
--out <file>             output .md path
--speakers <N>           expected number of speakers
--speakers-min <N>       minimum expected speakers
--speakers-max <N>       maximum expected speakers
--lang <code>            language code: en, it, fr, ... (default: auto-detect)
--title <string>         title for the markdown output
--context <text>         transcription context hint (improves accuracy)
--keyterms <t1,t2,...>   key terms to boost: names, acronyms, product names
--summary                include a provider-generated bullet summary
```

> **Tip:** `--context` and `--keyterms` are the most effective levers for accuracy. Names of people, companies, and systems are frequently mangled by ASR without them.

## Model requirements

No need for a flagship model. The heavy lifting (diarization, name identification from frames, summary) is well within the capabilities of cheaper models. **Claude Haiku** handles this skill reliably and at a fraction of the cost — a good default for teams processing many recordings.

Use a larger model (Sonnet, Opus) only when the recording is unusually noisy, the speaker identification is ambiguous, or you need a particularly detailed summary.

## Credits

Built by [Francesco Strappini](https://www.linkedin.com/in/fstraps/) @ [Next srl unipersonale](https://www.mynext.it)

## License

MIT — see [LICENSE](LICENSE).
