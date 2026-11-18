# Phase 0 — Hostile Audit Results

**Date:** 2026-11-18
**Machine:** Apple M5 MacBook Pro, 24 GB, macOS 26.6.2, Swift 6.3.2, Python 3.12.16
**Status:** complete. All decision gates resolved.

---

## Summary

| Check | Result | Gate |
|---|---|---|
| VoxWeft install + tests | 46 passed, 2 skipped (model-dependent golden tests) | PASS |
| TTS (VoxCPM2, zero-shot, warm) | first audio 208 ms, RTF 0.93 | marginal |
| TTS (VoxCPM2, cloned voice) | first audio 17.6 s, RTF 61.7 | **FAIL** |
| TTS (ZONOS3-Mini, warm) | first audio 95–200 ms (907 ms clone), RTF 0.22–0.40 | **PASS** |
| AEC on built-in mic | 1 ch → 9 ch with voice processing, `start()` = **-10875** | **FAIL** → half-duplex |
| Hy-MT2 Q4_K_M via stock llama.cpp | clean translations, 175–515 ms | PASS |
| Continuous session, no `ptt_end` | 4 segments committed, 4 audio streams, ~1.9–2.1 s per turn | **PASS** |
| Audio levels | peak 0.942, RMS 0.273, 0% clipped | PASS |

**Conclusion:** the plan changes in three ways — switch TTS to **ZONOS3-Mini**, constrain
`llama-server` to a tiny KV cache, and build **half-duplex ducking** into the app from day one.

---

## Detailed findings

### 1. Upstream tests pass, but the docs are not fully trustworthy
46 passed / 2 skipped on Python 3.12. The two skips are golden tests that need
reference NPZ files not shipped with the repo. One logging bug noticed in passing:
`bridge.py` logs the *default* voice id for every installed voice, which made a
22-voice warmup look like the same voice installing 22 times.

### 2. VoxCPM2 is unusable with its own cloned voices on this machine
Standalone, zero-shot warm TTS was fine (208 ms first audio, RTF 0.93 — matching
the published M5 number). But the runtime uses a per-language *cloned* voice
(`<lang>_tgt`). With `--ref`, first audio was 17.6 s and RTF 61.7. This is what
stalled the pipeline: segments committed, but the serial TTS worker never caught up.

### 3. ZONOS3-Mini is the right TTS model
43 languages (covers all 36 Hy-MT2 languages), 27 built-in voices, native streaming,
Apache-2.0. Warm measurements on this M5:

| mode | first audio | RTF |
|---|---|---|
| built-in voice `jett` | 197 ms | 0.24 |
| `voice=none` | 95 ms | 0.22 |
| cloned from 10 s reference | 907 ms | 0.40 |

A drop-in replacement bridge (`phase0/mini_bridge.py`) exposes the VoxWeft HTTP
surface (ASR via Qwen3-ASR, TTS via ZONOS3) and the unmodified VoxWeft runtime
works against it. End-to-end en→es produced correct transcripts, correct Hy-MT2
translations, and clean audio.

### 4. `llama-server` default context caused a 10× slowdown — critical
With defaults, llama.cpp started `n_slots=4, n_ctx_slot=218624` (~874k context),
allocating a huge KV cache. ZONOS3's RTF degraded from 0.22 to ~3.0 whenever
`llama-server` was resident — an order-of-magnitude regression from a server flag.

**Fix:** always start with `-c 2048 -np 1`. After that, ZONOS3 returned to RTF 0.22–0.40.
This number belongs in the run script, not in documentation.

### 5. AEC is impossible on this MacBook Pro's built-in mic
The AEC probe reproduced the devlog's exact failure: `setVoiceProcessingEnabled(true)`
succeeds, the input format changes from **1 ch to 9 ch**, and `AVAudioEngine.start()`
fails with **-10875**. There is no system AEC on this machine's built-in mic array.

**Decision:** v1 uses **half-duplex** — duck/mute the mic while translated audio plays.
Headphones remain the high-quality path.

### 6. Continuous conversation works (once TTS is fixed)
Leaving `ptt_start` open for 21 s of speech with natural pauses:
4 segments committed via the adaptive-RMS endpointing, 4 audio streams produced,
per-turn server-reported totals 1.85–2.13 s. No `ptt_end` was sent. So VoxWeft's
segmenter is directly reusable for continuous mode; the earlier failure was the
VoxCPM2 cloned-voice stall, not the protocol.

Probe caveat: `turn_end` events carry no `seq`, and events sent while the test client
is busy streaming audio get buffered, so client-side "first audio after commit"
timestamps from the probe are not meaningful. Trust the server's `total_ms` and
`tts_latency_ms` fields instead.

### 7. Hy-MT2 works on stock llama.cpp
`Q4_K_M` loaded with the installed build 12359 (`hunyuan-dense` template, Jinja on) —
no custom STQ kernel needed. Clean output (no explanations) on en→zh, en→es, en→ja,
zh→en; 175–515 ms per sentence. A small adapter (`translator_hymt2.py`) plugs it into
VoxWeft's runtime.

---

## Artifacts

| File | Purpose |
|---|---|
| `phase0/VoxWeft/` | upstream clone pinned at `097fb20`, with small local patches (Hy-MT2 adapter, TTS lang forwarding) |
| `phase0/.venv/` | Python 3.12 environment |
| `phase0/aec_probe.swift` / `aec_probe` | microphone AEC probe |
| `phase0/mt_probe.py` | Hy-MT2 translation checks |
| `phase0/zonos_probe.py` | ZONOS3 TTS benchmark |
| `phase0/mini_bridge.py` | ASR + ZONOS3 TTS HTTP service (drop-in bridge replacement) |
| `phase0/continuous_probe.py` | no-`ptt_end` session test |
| `phase0/translator_hymt2.py` (in vendored runtime) | Hy-MT2 adapter |
| `phase0/*.log` | raw logs from each run |

---

## Recommended next steps (Phase 1)

1. Build the SwiftUI app with **half-duplex ducking** from the start.
2. Use the vendored segmenter + runtime with `mini_bridge.py` and `llama-server -c 2048 -np 1`.
3. Keep AEC as an optional path for external/headset mics; do not depend on it.
4. Add a limiter only if needed — ZONOS3 output peaked at 0.942 with no clipping.
5. Revisit VoxCPM2 only if cloned-voice speed improves upstream; otherwise drop it.
