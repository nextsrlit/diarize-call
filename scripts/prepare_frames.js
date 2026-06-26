#!/usr/bin/env node

/**
 * prepare_frames.js — deterministic part of the diarize-call skill.
 *
 * Given the video and the raw JSON produced by diarize.js, it computes:
 *  1. The longest intervals (utterances) per speaker → extracts frames at
 *     those moments, where Teams/Meet display the speaker's name overlay.
 *     Used to map "Speaker A/B/..." → real name (via vision).
 *  2. Context frames at an adaptive cadence throughout the call, to capture
 *     shared screens and understand what is being discussed.
 *
 * Output: .jpg files in <outdir>/frames/ and a manifest.json telling Claude
 * which frames to read and in what priority order.
 *
 * Usage:
 *   node prepare_frames.js --video <file.mp4> --json <raw.json> --outdir <dir>
 *     [--intervals 3]    # how many longest intervals per speaker (default 3)
 *     [--per-interval 2] # frames per interval, spaced 5s apart (default 2)
 *
 * Requires ffmpeg and ffprobe in PATH.
 */

import { execFileSync } from 'child_process'
import fs from 'fs'
import path from 'path'

function parseArgs(argv) {
  const a = { video: null, json: null, outdir: null, intervals: 3, perInterval: 2 }
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i]
    if (k === '--video') a.video = argv[++i]
    else if (k === '--json') a.json = argv[++i]
    else if (k === '--outdir') a.outdir = argv[++i]
    else if (k === '--intervals') a.intervals = parseInt(argv[++i], 10)
    else if (k === '--per-interval') a.perInterval = parseInt(argv[++i], 10)
  }
  return a
}

function die(msg) { console.error('❌ ' + msg); process.exit(1) }

function videoDurationSec(video) {
  const out = execFileSync('ffprobe', [
    '-v', 'error',
    '-show_entries', 'format=duration',
    '-of', 'default=noprint_wrappers=1:nokey=1',
    video,
  ], { encoding: 'utf8' }).trim()
  const d = parseFloat(out)
  if (!isFinite(d) || d <= 0) die(`Could not read video duration from ffprobe: "${out}"`)
  return d
}

// Extracts utterances (speaker, start_ms, end_ms) from raw JSON, handling
// both AssemblyAI format (top-level .utterances, ms) and Gladia (seconds).
function extractUtterances(j) {
  if (Array.isArray(j.utterances) && j.utterances.length) {
    return j.utterances.map(u => ({ speaker: u.speaker, start: u.start, end: u.end }))
  }
  const g = j.result?.transcription?.utterances
  if (Array.isArray(g) && g.length) {
    return g.map(u => ({ speaker: u.speaker, start: Math.round(u.start * 1000), end: Math.round(u.end * 1000) }))
  }
  die('No utterances found in JSON (expected .utterances from AssemblyAI or .result.transcription.utterances from Gladia)')
}

function hhmmss(sec) {
  const t = Math.floor(sec)
  const h = String(Math.floor(t / 3600)).padStart(2, '0')
  const m = String(Math.floor((t % 3600) / 60)).padStart(2, '0')
  const s = String(t % 60).padStart(2, '0')
  return `${h}${m}${s}`
}

function grabFrame(video, sec, outPath) {
  // -ss prima di -i = seek veloce; -frames:v 1 = un fotogramma; -q:v 2 = alta qualità jpg
  execFileSync('ffmpeg', ['-y', '-ss', sec.toFixed(2), '-i', video, '-frames:v', '1', '-q:v', '2', outPath], { stdio: 'pipe' })
}

function main() {
  const opts = parseArgs(process.argv.slice(2))
  if (!opts.video || !opts.json || !opts.outdir) die('--video, --json, and --outdir are required. See script header.')
  for (const f of [opts.video, opts.json]) if (!fs.existsSync(f)) die(`File non trovato: ${f}`)

  const framesDir = path.join(opts.outdir, 'frames')
  fs.mkdirSync(framesDir, { recursive: true })

  const raw = JSON.parse(fs.readFileSync(opts.json, 'utf8'))
  const utts = extractUtterances(raw)
  const duration = videoDurationSec(opts.video)

  // ── speaker identification frames ───────────────────────────────────────────
  // Group by speaker, sort intervals by duration descending, keep top N.
  // For each interval extract `perInterval` frames spaced 5s apart, so if
  // the name is not visible in one (overlay gone) there's another chance.
  const bySpeaker = {}
  for (const u of utts) {
    if (u.speaker == null) continue
    ;(bySpeaker[u.speaker] ??= []).push(u)
  }

  const speakers = {}
  for (const [sp, list] of Object.entries(bySpeaker)) {
    list.sort((a, b) => (b.end - b.start) - (a.end - a.start))
    const top = list.slice(0, opts.intervals)
    const frames = []
    top.forEach((iv, ivIdx) => {
      const startS = iv.start / 1000
      const lenS = (iv.end - iv.start) / 1000
      for (let k = 0; k < opts.perInterval; k++) {
        // offset 3s, 8s, 13s... ma clippato all'interno dell'intervallo
        let t = startS + 3 + k * 5
        if (t > startS + lenS - 0.5) t = startS + Math.min(1, lenS / 2)
        if (t >= duration) t = duration - 0.5
        const name = `speaker_${sp}_iv${ivIdx + 1}_${k + 1}.jpg`
        const p = path.join(framesDir, name)
        try { grabFrame(opts.video, t, p); frames.push({ t: +t.toFixed(2), file: path.relative(opts.outdir, p) }) }
        catch { /* frame mancante: ignora, restano gli altri */ }
      }
    })
    speakers[sp] = {
      total_speaking_sec: +(list.reduce((s, u) => s + (u.end - u.start), 0) / 1000).toFixed(1),
      longest_interval_sec: +((top[0].end - top[0].start) / 1000).toFixed(1),
      frames,
    }
  }

  // ── context frames (adaptive cadence) ──────────────────────────────────────
  // Call < 20 min → 1/min (60s); otherwise 1 every 5 min (300s). Short calls
  // are dense and benefit from finer granularity; long calls would produce too many frames.
  const stepSec = duration < 20 * 60 ? 60 : 300
  const context = []
  for (let t = Math.min(15, duration / 2); t < duration; t += stepSec) {
    const name = `context_${hhmmss(t)}.jpg`
    const p = path.join(framesDir, name)
    try { grabFrame(opts.video, t, p); context.push({ t: +t.toFixed(2), file: path.relative(opts.outdir, p) }) }
    catch { /* ignora */ }
  }

  const manifest = {
    video: path.resolve(opts.video),
    duration_sec: +duration.toFixed(1),
    context_step_sec: stepSec,
    n_speakers: Object.keys(speakers).length,
    speakers,
    context,
  }
  const manifestPath = path.join(opts.outdir, 'manifest.json')
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2), 'utf8')

  console.log(`✅ Frames ready in ${framesDir}`)
  console.log(`   Speakers: ${Object.keys(speakers).join(', ') || '(none)'}`)
  console.log(`   Context frames: ${context.length} (1 every ${stepSec}s)`)
  console.log(`📋 Manifest: ${manifestPath}`)
}

main()
