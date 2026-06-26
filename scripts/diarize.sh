#!/usr/bin/env bash
# diarize.sh — transcription + speaker diarization via AssemblyAI, Gladia, or Deepgram.
# No npm deps required: uses curl, jq, ffmpeg.
#
# Usage:
#   bash diarize.sh [options] <file.m4a|video.mp4> [file2.mp3 ...]
#
# Options:
#   --provider <name>        assemblyai (default), gladia, or deepgram
#   --out <file>             output .md path (default: <input-basename>.md next to input)
#   --speakers <N>           expected number of speakers (ignored for deepgram)
#   --speakers-min <N>       minimum speakers (ignored for deepgram)
#   --speakers-max <N>       maximum speakers (ignored for deepgram)
#   --lang <code>            language code e.g. en, it (default: auto-detect)
#   --title <string>         title for the markdown (default: filename)
#   --context <text>         transcription context hint (assemblyai/gladia only)
#   --keyterms <t1,t2,...>   key terms to boost accuracy
#   --summary                request a provider summary
#   --help                   show this help
#
# Env:
#   ASSEMBLYAI_API_KEY       required for provider assemblyai
#   GLADIA_API_KEY           required for provider gladia
#   DEEPGRAM_API_KEY         required for provider deepgram

set -euo pipefail

# ── dependency check ──────────────────────────────────────────────────────────
missing=()
for cmd in curl jq ffmpeg ffprobe; do
  command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "❌ Missing required tools: ${missing[*]}"
  echo ""
  echo "Install them:"
  echo "  macOS:  brew install ${missing[*]}"
  echo "  Ubuntu: sudo apt install ${missing[*]}"
  exit 1
fi

# ── helpers ───────────────────────────────────────────────────────────────────
ms_to_time() {
  local ms=$1
  local sec=$(( ms / 1000 ))
  local h=$(( sec / 3600 ))
  local m=$(( (sec % 3600) / 60 ))
  local s=$(( sec % 60 ))
  if (( h > 0 )); then
    printf "%d:%02d:%02d" "$h" "$m" "$s"
  else
    printf "%02d:%02d" "$m" "$s"
  fi
}

show_help() {
  cat <<'EOF'
Usage: bash diarize.sh [options] <file.m4a|video.mp4> [file2.mp3 ...]

If the input is a video (.mp4 .mov .mkv .avi .webm .m4v), audio is extracted
automatically. Multiple audio files are concatenated.

Options:
  --provider <name>        assemblyai (default), gladia, or deepgram
  --out <file>             output .md path (default: <input-basename>.md)
  --speakers <N>           expected number of speakers (ignored for deepgram)
  --speakers-min <N>       minimum expected speakers (ignored for deepgram)
  --speakers-max <N>       maximum expected speakers (ignored for deepgram)
  --lang <code>            language: en, it, fr, ... (default: auto-detect)
  --title <string>         title in markdown (default: filename)
  --context <text>         context hint to improve transcription (assemblyai/gladia only)
  --keyterms <t1,t2,...>   key terms to boost (names, acronyms, products)
  --summary                request a provider bullet summary
  --help                   show this help

Env:
  ASSEMBLYAI_API_KEY       required for assemblyai
  GLADIA_API_KEY           required for gladia
  DEEPGRAM_API_KEY         required for deepgram
EOF
}

is_video() {
  [[ "$1" =~ \.(mp4|mov|mkv|avi|webm|m4v)$ ]]
}

# ── argument parsing ──────────────────────────────────────────────────────────
files=()
out=""
speakers=""
speakers_min=""
speakers_max=""
lang=""
title=""
provider="assemblyai"
context=""
keyterms=""
do_summary=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)           show_help; exit 0 ;;
    --out)            out="$2";          shift 2 ;;
    --speakers)       speakers="$2";     shift 2 ;;
    --speakers-min)   speakers_min="$2"; shift 2 ;;
    --speakers-max)   speakers_max="$2"; shift 2 ;;
    --lang)           lang="$2";         shift 2 ;;
    --title)          title="$2";        shift 2 ;;
    --provider)       provider="$2";     shift 2 ;;
    --context)        context="$2";      shift 2 ;;
    --keyterms)       keyterms="$2";     shift 2 ;;
    --summary)        do_summary=true;   shift ;;
    --*)              echo "❌ Unknown option: $1" >&2; exit 1 ;;
    *)                files+=("$1");     shift ;;
  esac
done

if [ ${#files[@]} -eq 0 ]; then
  echo "❌ No audio/video file specified. Use --help for usage." >&2
  exit 1
fi

for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "❌ File not found: $f" >&2; exit 1; }
done

first_file="${files[0]}"
base=$(basename "$first_file")
base_noext="${base%.*}"
dir=$(dirname "$(realpath "$first_file")")
out="${out:-$dir/$base_noext.md}"
title="${title:-$base_noext}"
json_out="${out%.md}.json"

# ── temp file + cleanup ───────────────────────────────────────────────────────
tmp_audio=""
list_file=""
cleanup() {
  [ -n "$tmp_audio" ] && rm -f "$tmp_audio"
  [ -n "$list_file" ] && rm -f "$list_file"
  :
}
trap cleanup EXIT

# ── audio extraction / concatenation ─────────────────────────────────────────
audio_file="$first_file"

if [ ${#files[@]} -gt 1 ]; then
  echo "🔗 Concatenating ${#files[@]} audio files..."
  tmp_audio=$(mktemp /tmp/diarize-concat-XXXXXX.m4a)
  list_file=$(mktemp /tmp/diarize-list-XXXXXX.txt)
  printf "file '%s'\n" "${files[@]}" > "$list_file"
  ffmpeg -y -f concat -safe 0 -i "$list_file" -c copy "$tmp_audio" 2>/dev/null
  rm -f "$list_file"
  audio_file="$tmp_audio"
  size=$(du -m "$audio_file" | cut -f1)
  echo "✅ Concatenated: ${size}MB"
elif is_video "$first_file"; then
  echo "🎬 Extracting audio from video..."
  tmp_audio=$(mktemp /tmp/diarize-audio-XXXXXX.m4a)
  ffmpeg -y -i "$first_file" -vn -c:a copy "$tmp_audio" 2>/dev/null \
    || ffmpeg -y -i "$first_file" -vn -c:a aac -b:a 128k "$tmp_audio" 2>/dev/null
  audio_file="$tmp_audio"
  size=$(du -m "$audio_file" | cut -f1)
  echo "✅ Audio extracted: ${size}MB"
else
  size=$(du -m "$audio_file" | cut -f1)
  echo "📁 $base (${size}MB)"
fi

# ── upload + transcribe ───────────────────────────────────────────────────────
if [ "$provider" = "assemblyai" ]; then

  [ -n "${ASSEMBLYAI_API_KEY:-}" ] || { echo "❌ ASSEMBLYAI_API_KEY is not set." >&2; exit 1; }

  echo "⬆️  Uploading to AssemblyAI..."
  upload_url=$(curl -s -X POST https://api.assemblyai.com/v2/upload \
    -H "Authorization: $ASSEMBLYAI_API_KEY" \
    --data-binary @"$audio_file" | jq -r '.upload_url')
  [ "$upload_url" != "null" ] && [ -n "$upload_url" ] || { echo "❌ Upload failed." >&2; exit 1; }
  echo "✅ Upload complete"

  # Build request body
  body=$(jq -n \
    --arg url "$upload_url" \
    '{
      audio_url: $url,
      speaker_labels: true,
      speech_models: ["universal-3-pro", "universal-2"]
    }')

  if [ -n "$lang" ]; then
    body=$(echo "$body" | jq --arg lang "$lang" '. + {language_code: $lang}')
  else
    body=$(echo "$body" | jq '. + {language_detection: true}')
  fi

  if [ -n "$speakers" ]; then
    body=$(echo "$body" | jq --argjson n "$speakers" '. + {speakers_expected: $n}')
  elif [ -n "$speakers_min" ] || [ -n "$speakers_max" ]; then
    sp_opts='{}'
    [ -n "$speakers_min" ] && sp_opts=$(echo "$sp_opts" | jq --argjson n "$speakers_min" '. + {min_speakers_expected: $n}')
    [ -n "$speakers_max" ] && sp_opts=$(echo "$sp_opts" | jq --argjson n "$speakers_max" '. + {max_speakers_expected: $n}')
    body=$(echo "$body" | jq --argjson opts "$sp_opts" '. + {speaker_options: $opts}')
  fi

  # Context + keyterms → combined prompt on universal3
  prompt=""
  if [ -n "$context" ] && [ -n "$keyterms" ]; then
    prompt="$context, key terms: $keyterms"
  elif [ -n "$context" ]; then
    prompt="$context"
  fi

  if [ -n "$prompt" ]; then
    body=$(echo "$body" | jq --arg p "$prompt" '. + {prompt: $p}')
    echo "💡 Context active"
  elif [ -n "$keyterms" ]; then
    terms_json=$(echo "$keyterms" | jq -R 'split(",") | map(ltrimstr(" ") | rtrimstr(" "))')
    body=$(echo "$body" | jq --argjson t "$terms_json" '. + {keyterms_prompt: $t}')
    echo "🔑 Keyterms active: $keyterms"
  fi

  if $do_summary; then
    body=$(echo "$body" | jq '. + {summarization: true, summary_type: "bullets", summary_model: "conversational"}')
  fi

  echo "🎙️  Transcribing (AssemblyAI universal-3-pro)..."
  response=$(curl -s -X POST https://api.assemblyai.com/v2/transcript \
    -H "Authorization: $ASSEMBLYAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$body")

  transcript_id=$(echo "$response" | jq -r '.id')
  [ "$transcript_id" != "null" ] && [ -n "$transcript_id" ] || {
    echo "❌ Transcript submission failed: $(echo "$response" | jq -r '.error // "unknown error"')" >&2
    exit 1
  }

  # Poll (max 180 attempts × 5s = 15 min)
  attempt=0
  while true; do
    result=$(curl -s "https://api.assemblyai.com/v2/transcript/$transcript_id" \
      -H "Authorization: $ASSEMBLYAI_API_KEY")
    status=$(echo "$result" | jq -r '.status')
    case "$status" in
      completed) echo ""; break ;;
      error)
        echo ""
        echo "❌ AssemblyAI error: $(echo "$result" | jq -r '.error')" >&2
        exit 1 ;;
      *)
        (( attempt++ > 180 )) && { echo ""; echo "❌ Timeout: AssemblyAI job did not complete after 15 min." >&2; exit 1; }
        printf '.' ; sleep 5 ;;
    esac
  done

elif [ "$provider" = "gladia" ]; then

  [ -n "${GLADIA_API_KEY:-}" ] || { echo "❌ GLADIA_API_KEY is not set." >&2; exit 1; }

  echo "⬆️  Uploading to Gladia..."
  upload_resp=$(curl -s -X POST https://api.gladia.io/v2/upload \
    -H "x-gladia-key: $GLADIA_API_KEY" \
    -F "audio=@$audio_file;type=audio/mp4")
  upload_url=$(echo "$upload_resp" | jq -r '.audio_url')
  [ "$upload_url" != "null" ] && [ -n "$upload_url" ] || { echo "❌ Gladia upload failed: $upload_resp" >&2; exit 1; }
  echo "✅ Upload complete"

  body=$(jq -n --arg url "$upload_url" '{audio_url: $url, diarization: true}')

  if [ -n "$lang" ]; then
    body=$(echo "$body" | jq --arg lang "$lang" '. + {language: $lang, detect_language: false}')
  else
    body=$(echo "$body" | jq '. + {detect_language: true}')
  fi

  if [ -n "$speakers" ]; then
    body=$(echo "$body" | jq --argjson n "$speakers" '. + {diarization_config: {number_of_speakers: $n}}')
  elif [ -n "$speakers_min" ] || [ -n "$speakers_max" ]; then
    sp_opts='{}'
    [ -n "$speakers_min" ] && sp_opts=$(echo "$sp_opts" | jq --argjson n "$speakers_min" '. + {min_speakers: $n}')
    [ -n "$speakers_max" ] && sp_opts=$(echo "$sp_opts" | jq --argjson n "$speakers_max" '. + {max_speakers: $n}')
    body=$(echo "$body" | jq --argjson opts "$sp_opts" '. + {diarization_config: $opts}')
  fi

  echo "🎙️  Transcribing (Gladia Solaria)..."
  init_resp=$(curl -s -X POST https://api.gladia.io/v2/pre-recorded \
    -H "x-gladia-key: $GLADIA_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$body")
  result_url=$(echo "$init_resp" | jq -r '.result_url')
  [ "$result_url" != "null" ] && [ -n "$result_url" ] || { echo "❌ Gladia init failed: $init_resp" >&2; exit 1; }

  # Poll (max 180 attempts × 3s = 9 min)
  attempt=0
  while true; do
    result=$(curl -s "$result_url" -H "x-gladia-key: $GLADIA_API_KEY")
    status=$(echo "$result" | jq -r '.status')
    case "$status" in
      done)  echo ""; break ;;
      error) echo ""; echo "❌ Gladia error: $(echo "$result" | jq -r '.error_code // "unknown"')" >&2; exit 1 ;;
      *)
        (( attempt++ > 180 )) && { echo ""; echo "❌ Timeout: Gladia job did not complete after 9 min." >&2; exit 1; }
        printf '.'; sleep 3 ;;
    esac
  done

  # Normalize Gladia format: convert seconds→ms, flatten utterances
  result=$(echo "$result" | jq '{
    utterances: [.result.transcription.utterances[] | {
      speaker: .speaker,
      start: (.start * 1000 | round),
      end:   (.end   * 1000 | round),
      text:  .text
    }]
  }')

elif [ "$provider" = "deepgram" ]; then

  [ -n "${DEEPGRAM_API_KEY:-}" ] || { echo "❌ DEEPGRAM_API_KEY is not set." >&2; exit 1; }

  # MIME type from extension (Deepgram accepts any audio; m4a/mp4 both map to audio/mp4)
  case "${audio_file##*.}" in
    mp3)  ctype="audio/mpeg" ;;
    wav)  ctype="audio/wav"  ;;
    flac) ctype="audio/flac" ;;
    ogg)  ctype="audio/ogg"  ;;
    *)    ctype="audio/mp4"  ;;
  esac

  params="diarize=true&utterances=true&punctuate=true&model=nova-3"

  if [ -n "$lang" ]; then
    params="$params&language=$lang"
  else
    params="$params&detect_language=true"
  fi

  if $do_summary; then
    params="$params&summarize=v2"
  fi

  # --speakers* not supported by Deepgram nova-3 diarization
  if [ -n "$speakers" ] || [ -n "$speakers_min" ] || [ -n "$speakers_max" ]; then
    echo "⚠️  --speakers/--speakers-min/--speakers-max ignored for Deepgram (auto-detected)"
  fi

  if [ -n "$keyterms" ]; then
    IFS=',' read -ra _kterms <<< "$keyterms"
    for _kt in "${_kterms[@]}"; do
      _kt="${_kt#"${_kt%%[![:space:]]*}"}"
      _kt="${_kt%"${_kt##*[![:space:]]}"}"
      [ -n "$_kt" ] && params="$params&keyterm=$(printf '%s' "$_kt" | jq -Rr '@uri')"
    done
    echo "🔑 Keyterms: $keyterms"
  fi

  echo "🎙️  Transcribing (Deepgram Nova-3)..."
  result=$(curl -s -X POST "https://api.deepgram.com/v1/listen?$params" \
    -H "Authorization: Token $DEEPGRAM_API_KEY" \
    -H "Content-Type: $ctype" \
    --data-binary @"$audio_file")

  err=$(echo "$result" | jq -r '.err_msg // empty' 2>/dev/null || true)
  [ -z "$err" ] || { echo "❌ Deepgram error: $err" >&2; exit 1; }

  utt_count=$(echo "$result" | jq '.results.utterances | length' 2>/dev/null || echo 0)
  [ "${utt_count:-0}" -gt 0 ] || {
    echo "❌ Deepgram returned no utterances." >&2
    echo "$result" | jq -r '.error // .err_msg // "unknown error"' >&2
    exit 1
  }

  # Normalize: speaker int→string, seconds→ms, transcript→text
  result=$(echo "$result" | jq '{
    utterances: [.results.utterances[] | {
      speaker: (.speaker | tostring),
      start:   (.start * 1000 | round),
      end:     (.end   * 1000 | round),
      text:    .transcript
    }],
    summary: (.results.summary.short // null)
  }')

else
  echo "❌ Unknown provider: $provider. Use assemblyai, gladia, or deepgram." >&2
  exit 1
fi

# ── write outputs ─────────────────────────────────────────────────────────────
echo "$result" > "$json_out"
echo "💾 Raw JSON: $json_out"

{
  echo "# $title"
  echo ""
  echo "> Transcript — $provider diarization"
  echo ""

  summary_text=$(echo "$result" | jq -r '.summary // empty' 2>/dev/null || true)
  if [ -n "$summary_text" ]; then
    echo "## Summary"
    echo ""
    echo "$summary_text"
    echo ""
  fi

  echo "## Transcript"
  echo ""

  count=$(echo "$result" | jq '.utterances | length')
  for (( i=0; i<count; i++ )); do
    speaker=$(echo "$result" | jq -r ".utterances[$i].speaker")
    start_ms=$(echo "$result" | jq -r ".utterances[$i].start")
    text=$(echo "$result" | jq -r ".utterances[$i].text")
    ts=$(ms_to_time "$start_ms")
    echo "**Speaker $speaker** \`[$ts]\`"
    echo "$text"
    echo ""
  done
} > "$out"

echo "📝 Markdown: $out"
