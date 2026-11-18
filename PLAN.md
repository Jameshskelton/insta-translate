# insta-translate — Detailed Implementation Plan

**Goal:** A native macOS app for continuous, on-device spoken translation:
*you talk naturally → speech is transcribed → Hy-MT2-1.8B translates → a multilingual TTS model speaks the result.*
No cloud calls, no data leaving the machine.

**Target hardware:** Apple M5 MacBook Pro, 24 GB unified memory (~16 GB comfortably usable).
**Status:** planning only — no code or model downloads have been performed yet.

**Recommendation in one line:** vendor selected parts of VoxWeft (its streaming TTS core,
segmenter, and devlog), do **not** fork it wholesale, and build our own native shell.

---

## 1. Reality check before we build

Three findings materially shape the design:

1. **Your translation model choice is excellent and cheap.**
   `tencent/Hy-MT2-1.8B-GGUF` `Q4_K_M` is ~1.13 GB, Apache-2.0, covers 36 languages,
   and your installed `llama-server` (build 12359) already ships the `hunyuan-dense`
   chat template (Jinja enabled by default). The headline-grabbing 1.25-bit (440 MB)
   and 2-bit variants require Tencent's custom **STQ kernel** (llama.cpp PR #22836),
   so we will **not** use them in v1 — `Q4_K_M` is the pragmatic starting point.

2. **TTS is now ZONOS3-Mini, chosen by measurement rather than assumption.**
   Hy-MT2 covers 36 languages; Phase 0 showed VoxCPM2's cloned-voice path is
   unusable here (RTF 61.7), while **ZONOS3-Mini** covers **43 languages**, streams
   natively, and measured RTF 0.22–0.40 with 95–200 ms warm first audio. Kokoro
   remains an 8-language fallback. See `phase0/RESULTS.md`.

3. **VoxWeft implements most of this spec, but it is not a product base.**
   [HenryZ838978/VoxWeft](https://github.com/HenryZ838978/VoxWeft) (Apache-2.0) has
   exactly the right Lego: VoxCPM2 on MLX with a custom stateful streaming decoder,
   an adaptive-RMS segmenter, a language router, a thread-pinned TTS+ASR bridge, and
   a WebSocket runtime. It also lists Hy-MT2-1.8B as an alternative MT backend.
   But it is 0.1.0, single-author, last committed 2026-09-22, PTT-shaped end to end,
   and its own devlog records ten confirmed post-release defects — six of them cases
   of "the docs describe the fix, the code doesn't have it". See section 2.

**Phase 0 is complete.** Results are in `phase0/RESULTS.md`. Three plan changes came
out of it: switch TTS to ZONOS3-Mini, force `llama-server -c 2048 -np 1`, and design
for half-duplex mic ducking from day one. Continuous sessions were verified to work.

---

## 2. Honest assessment of VoxWeft

**Rating: 8/10 as a reference implementation, 4/10 as a product base.**

### What is genuinely valuable

`docs/DEVLOG.md` is the main asset — ~500 lines of measured failure analysis, including
*disproved* hypotheses. You cannot recreate this from papers. Highlights we should inherit:

- **MLX GPU streams are thread-bound.** Load and infer must happen on the same thread;
  one single-thread executor per model, separate executors for TTS and ASR.
- **Loading the second model evicts the first model's MLX buffer cache.** First TTS
  request 747 ms vs 305 ms afterwards; fix is one re-prime *after all models load*.
- **VoxCPM2 `temperature` is flow-matching noise, not softmax.** Setting it to 0.01
  prevents the stop token and produces 80% silence. Keep the official 1.0.
- **`warmup_patches=2` (inherited from mlx-audio) created the click it was meant to
  remove** and cost ~470 ms first-audio on M2. Default is 0 with an 8 ms fade.
- **SmartTurn v3 is net-negative for interpretation.** It is a dialogue model asking
  "is the speaker waiting for a reply?", not "is this a clause boundary?". Leave off.
- **Adaptive RMS threshold** cut ASR CER from 16.3% → 10% on phone audio.
- **Short segments were silently dropped** ("各位专家，" vanished with no error);
  they must be carried into the next segment in a separate buffer.
- **Interrupt was broken in four independent layers**; fixing all four took 19.9 s → 1.2 s.
- **Client jitter buffer** (accumulate to 200 ms before scheduling) and **0.6 s pre-roll**
  for RTF > 1 producers hide a slow TTS without per-chunk stutter.
- **`/health` ≠ `/ready`**; SwiftPM trusts mtimes and can report "Build complete" in
  2.8 s without compiling; macOS 26 + Swift 6.3 makes SwiftUI `Button` abort on click.

The code matches the prose: `orchestrator.py` and `segmenter.py` are careful state
machines (generation counters, cancel semantics, carry buffers), not a demo. There is
a golden test proving the streaming VAE is bit-identical to full decode. Reported smoke
tests: 48/48 on M2, 43 passed / 2 skipped on Linux.

### What worries us

1. **Dormant, bus factor one.** 0.1.0, 13 commits, 16 stars, no releases, no PyPI by
   design ("the source is the distribution"). Last commit 2026-09-22. If we hit a novel
   bug, we are the maintainer. → **Vendor the modules we need; do not track upstream.**

2. **Docs/code drift was a real, recent problem.** A post-open-source review found ten
   confirmed defects: WAV headers decoded as audio for an entire exhibition run, the
   shipped default ASR forcing language labels the model never saw, TTS exceptions
   returning clean HTTP 200, empty translations with no `turn_end`, and an advertised
   adaptive threshold that was never enabled. All ten were fixed in one commit
   (`b9026a5`) — creditable, but it means README claims are hypotheses until tested.

3. **The M5 numbers are thinly sourced.** The devlog appendix contains only M2 (TTS
   RTF 1.47 — slower than realtime) and M3 Ultra (0.2), and explicitly says "M-series
   Pro/Max RTF is unmeasured". The M5 column came from a **single showcase recording**
   added in one commit: three sentences at 0.58 / 2.44 / 1.32 s, "with a full desktop
   session running", and TTS RTF ≈ 0.94. That is essentially exactly real-time, before
   adding Hy-MT2 as a third process.

4. **Continuous conversation is not implemented.** Protocol, app, and lifecycle are
   PTT-shaped (`ptt_start` → frames → `ptt_end`, flush on release, hold-to-talk button).
   Leaving a session open *may* work because the segmenter cuts incrementally, but it
   is untested territory.

5. **AEC is a concrete landmine on your exact machine.** On a MacBook Pro whose mic
   array reports 3 input channels, `setVoiceProcessingEnabled(true)` reshapes input to
   7 channels and `AVAudioEngine.start()` fails with -10875. Their fallback disables
   AEC entirely; the README quietly says "headphones". This is the **biggest single
   risk** to open-mic continuous conversation.

6. **"30+ languages" is optimistic.** The router knows 16, Qwen3-ASR ships ~26, and
   Lao/Khmer/Burmese ASR is openly poor (Whisper returns Thai script for Lao, CER 89%).
   Hy-MT2's 36 languages don't help if ASR/TTS can't handle them.

7. **The Swift shell is disposable.** ~500 lines in three files, explicitly a thin
   client, with no SwiftUI `Button` at all due to the macOS 26 abort. We need a real
   native app anyway (continuous mode, language pickers, AEC/ducking, lifecycle).

8. **Quality variance is unresolved.** Same text/params: 3.84–6.40 s duration, whole-
   signal RMS 0.006–0.11, peaks to 0.97 (one bad run from clipping). No seed, no limiter.

9. **Dependency sharp edges.** `mlx-lm` 0.31 changed the sampling API; `mcp` 2.x broke
   the published install; Swift 6.3/macOS 26 needs workarounds; CLT-only installs can
   fail to link; ModelScope mirrors lack HF processor files; NLLB fallback is CC-BY-NC.

**Phase 0 confirmed the two biggest concerns.** AEC fails on this MacBook Pro's
built-in mic (1 ch → 9 ch, `start()` = -10875). VoxCPM2's cloned voices stall the
pipeline (RTF 61.7). Both are now resolved design decisions, not open risks
(`phase0/RESULTS.md`).

### Decision (updated after Phase 0)

| Take | Leave behind |
|---|---|
| `IncrementalSegmenter` + its tests | L1 VoxCPM2 core — replaced by ZONOS3-Mini |
| `DEVLOG.md` as required reading | L3 SwiftUI shell — rewrite |
| Runtime orchestrator + WebSocket protocol | `serve` PTT lifecycle — rework for continuous |
| Voice-design patterns (optional) | Router's hardcoded LLM-vs-dedicated-MT rules — simplify for Hy-MT2 |
| Bridge patterns (thread pinning, re-prime, `/ready`) | Their in-process Qwen3-4B MT — replace with Hy-MT2 |
| Voice design/clone samples (optional) | Faithful upstream tracking — pin commit `097fb20` |

---

## 3. Architecture

### Architecture A — Vendored Python MLX runtime + own native Swift app (recommended)

```
┌──────────────────────────────────────────────────────────────┐
│  Our SwiftUI macOS app  (new, not VoxWeft's shell)            │
│  • continuous mic session + half-duplex ducking (AEC failed)  │
│  • language pickers, live transcript, latency chips           │
│  • AVAudioEngine playback with jitter buffer + barge-in       │
└───────────────────┬───────────────────────────▲──────────────┘
                    │ WebSocket /ws/voice/v2     │ 48 kHz PCM chunks + events
┌───────────────────▼───────────────────────────┴──────────────┐
│  Python MLX runtime (vendored VoxWeft L2 + mini_bridge)       │
│                                                              │
│   mic frames → vendored adaptive-RMS segmenter (0.45 s cut)   │
│              → Qwen3-ASR-1.7B-8bit   (ASR, ~26 langs)         │
│              → Hy-MT2-1.8B Q4_K_M    (MT, 36 langs)  ← ours   │
│              → ZONOS3-Mini           (TTS, 43 langs) ← chosen │
│              → 48 kHz PCM streamed back to the app            │
└──────────────────────────────────────────────────────────────┘
                               │
                     llama-server (third process, local HTTP)
                     llama-server -hf tencent/Hy-MT2-1.8B-GGUF:Q4_K_M \
                                  --port 8080 --jinja -ngl 99 -c 2048 -np 1
                     ⚠ without -c/-np the KV cache causes a 10x slowdown
```

**Pros:** shortest path to a working streaming interpreter; the hard MLX/concurrency/
endpointing bugs are already solved and documented. **Cons:** three processes, and we
own whatever we vendor. Note that VoxWeft's MT is **in-process** via mlx-lm; adding
Hy-MT2 through llama-server adds a third process and an HTTP hop — budget ~100–300 ms
and measure it.

**MT integration detail.** Call the OpenAI-compatible `/v1/chat/completions` endpoint
with the model card's exact instruction and no system prompt:

```
Translate the following text into {TARGET_LANGUAGE}. Note that you should only output
the translated result without any additional explanation: {SOURCE_TEXT}
```

Start with the card's sampling defaults (`temperature 0.7, top_p 0.6, top_k 20,
repetition_penalty 1.05`), then lower temperature to ~0.2–0.3 for deterministic
translation. Cap `max_tokens` around 256 — we are translating a sentence, not
generating an essay. VoxWeft's `translator.py` is the adapter point, but its router
assumes separate LLM/dedicated-MT backends; Hy-MT2 covers all pairs in one hop, so
this is a simplification of the router, not a config swap.

### Architecture B — pure Swift app, `mlx-audio-swift`

[Neywa-Labs/mlx-audio-swift](https://github.com/Neywa-Labs/mlx-audio-swift) (MIT,
822 stars) puts ASR, TTS, VAD, and SwiftUI audio components directly in the app:

- ASR: Whisper or `Qwen3-ASR-1.7B` in-process.
- TTS: **ZONOS3** is supported by the Swift package; OmniVoice (646+ languages),
  Chatterbox, and Voxtral are also available if wider coverage is needed.
- VAD: Silero VAD / SmartTurn / FSMN VAD.
- MT: still needs `llama-server` for Hy-MT2 (mlx-lm uses safetensors, not GGUF).

**Pros:** single app bundle, no Python daemon, better distribution story.
**Cons:** more Swift-side engineering for endpointing and cancellation. Recommend as
an **optional Phase 4 migration** only if a single-bundle distribution matters more
than the current three-process setup.

---

## 4. Model inventory

| Role | Model | Quant / size | Languages | Notes |
|---|---|---|---|---|
| ASR | `mlx-community/Qwen3-ASR-1.7B-8bit` (via mlx-audio) | 8-bit, 2.5 GB | ~26 | RTF 0.11 on M-series; VoxWeft default |
| ASR fallback | `mlx-community/whisper-large-v3-turbo` | MLX | 99+ | used by VoxWeft for lo/km/my; quality poor (Lao CER 89%) |
| ASR alternative | Apple `SpeechAnalyzer` / `SFSpeechRecognizer` | on-device, 0 MB | ~50 locales | macOS 26+; no download; true streaming partials, but our own endpointing still needed |
| MT | `tencent/Hy-MT2-1.8B-GGUF:Q4_K_M` | 1.13 GB | 36 | Apache-2.0; `llama-server --jinja -c 2048 -np 1`; verified clean output, 175–515 ms |
| TTS **(chosen)** | `mlx-community/ZONOS3-Mini` | ~0.9B total / 100M active | **43** | Apache-2.0, 27 voices, native streaming; measured RTF 0.22–0.40, first audio 95–200 ms (907 ms cloned) |
| TTS (dropped) | VoxCPM2 4-bit | ~1.5 GB | 30 | zero-shot OK, cloned voice RTF 61.7 — unusable in the runtime |
| TTS fallback | Kokoro-82M via mlx-audio | 82M, ~0.3 GB | 8 | fastest; en-only control if ZONOS3 has issues |
| Endpointing | vendored adaptive RMS VAD | — | — | 0.45 s silence cut, 6 s forced dip, 2 s carry; SmartTurn **off** |
| Output safety | light limiter | — | — | ZONOS3 peaked at 0.942 with 0% clipping — optional, not urgent |

**Footprint:** ~7–9 GB on disk. VoxWeft measured **6.7 GB resident** for their
ASR + in-process Qwen3-4B MT + TTS; adding `llama-server` for Hy-MT2 adds roughly
1.3–1.8 GB. Still leaves ~7 GB of your ~16 GB usable budget — comfortable, but
measure with `vm_stat` before any latency claim.

---

## 5. Latency budget (M5, with caveats)

"Real-time" means *continuous conversation with ~1–2 s response latency after you
stop speaking*, not word-for-word simultaneous interpreting.

| Stage | Basis | Estimate |
|---|---|---|
| End of utterance detected | VoxWeft design | ~0.45 s silence + segmenter overhead |
| ASR of segment | VoxWeft M-series measurement | ~0.3–0.8 s |
| MT (Hy-MT2 Q4_K_M via HTTP) | Phase 0 measured | 0.18–0.52 s |
| TTS first audio (warm) | Phase 0 measured, ZONOS3 | 0.10–0.20 s (0.91 s cloned) |
| TTS full segment | Phase 0 measured, RTF 0.22–0.40 | ~5 s audio in 1.1–2.0 s wall |
| **Per-turn, stop-speaking → first translated audio** | Phase 0 continuous probe | **~1.9–2.1 s** (server `total_ms`) |

These are measured on this M5 with all three model processes co-resident, using
`llama-server -c 2048 -np 1`. The earlier VoxWeft M5 number (RTF 0.94) was TTS-bound;
ZONOS3 removes that ceiling.

**Mitigations that matter:**
- **Always** start `llama-server` with `-c 2048 -np 1`. Defaults allocated ~874k
  context and caused a **10× slowdown** of the TTS model.
- Keep segments short (vendored segmenter cuts at the first ≥100 ms dip after 6 s).
- Preserve thread pinning and warm through the real inference path; poll `/ready`.
- Watch co-resident memory — the machine showed only 12% free with all processes up.

---

## 6. Risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| **AEC fails on the built-in mic (-10875)** | Confirmed | v1 is **half-duplex**: duck the mic while TTS plays. Headphones = optional high-quality path. |
| Co-resident model processes | High | `llama-server -c 2048 -np 1` is mandatory; monitor `vm_stat`; 12% free observed with all processes up |
| Continuous mode not implemented upstream | Resolved | Phase 0 verified it works with an open `ptt_start`; reuse `IncrementalSegmenter` in a long-lived session |
| TTS as latency ceiling | Resolved | ZONOS3 measured RTF 0.22–0.40; VoxCPM2 abandoned |
| Vendored code is dormant / bus factor one | Medium | pin `097fb20`, copy only what we use, read DEVLOG, keep our layer thin |
| Docs/code drift in upstream | Medium | treat README claims as hypotheses; upstream tests passed 46/2 in Phase 0 |
| Hy-MT2 GGUF compatibility | Resolved | loads and translates correctly on stock llama.cpp build 12359 |
| Hy-MT2 sub-2-bit quants need custom STQ kernel | Low | use `Q4_K_M` |
| Low-resource ASR (lo/km/my) | Medium | ZONOS3 covers 43 languages but ASR does not; pick 2–3 priority pairs and be honest in UI |
| Python 3.15 wheel gaps | Low | pin Python 3.12 with `uv` |
| App sandbox entitlements | Low | start unsigned/unsandboxed for dev; add mic + speech entitlements before distribution |

---

## 7. Phased implementation

### Phase 0 — Hostile audit on your M5 — ✅ COMPLETE

Goal: find out whether the vendored core works *here*, before building a UI on top.
Full results and raw logs are in `phase0/RESULTS.md`. Outcome: upstream tests pass,
AEC fails, VoxCPM2 cloned voices are unusable, ZONOS3-Mini is the replacement,
continuous sessions work, and `llama-server` needs `-c 2048 -np 1`.

1. `uv venv --python 3.12` (your system Python 3.15 is too new for several audio wheels).
2. Clone VoxWeft **to a scratch directory**, pin commit `097fb20`, install
   `.[runtime]`, follow `docs/AGENT-SETUP.md` and `docs/MODELS.md`.
3. Run their tests (`pytest`), not just the demo. Note what fails on Python 3.12 / current MLX.
4. Download VoxCPM2 4-bit + Qwen3-ASR-1.7B-8bit. Run `voxweft say "..." --stream`
   **twice** with all background apps closed; report the second first-audio and RTF.
5. **AEC probe (highest priority):** a 15-line AVAudioEngine/Swift or Objective-C probe
   using the built-in mic with voice processing enabled. If `start()` returns -10875,
   record it and plan for half-duplex ducking now, not later.
6. **Continuous-session probe:** send `ptt_start`, keep the stream open, speak for
   60 s with natural pauses, never send `ptt_end`. Check whether segments commit and
   turns complete. This is the untested path.
7. Start `llama-server` with Hy-MT2 `Q4_K_M`; curl the model-card translation prompt
   and verify clean output (no explanations, correct target language) for 3 pairs.
8. Optionally run `scripts/mock_interpret.py` for a full mic-free baseline.

**Resolved decision gates:** TTS → ZONOS3-Mini; audio → half-duplex ducking;
continuous mode → reuse `IncrementalSegmenter` with an open session; MT → Hy-MT2
adapter on stock llama.cpp. No fallback to Architecture B was needed.

### Phase 1 — Our native shell with continuous audio (in progress)

✅ **Milestone 1 done — end-to-end on this machine.** `app/` is a thin SwiftUI
client (4 files, `build.sh` compiles it to `insta-translate.app` without Xcode
projects). Verified headlessly: connect → `session_config` → `text_input` → Hy-MT2
translation (259 ms) → ZONOS3 `audio_start` (140 ms TTS latency) → `audio_end` →
`turn_end`, with playback. Mic capture uses VoxWeft-style AVAudioEngine with a
voice-processing try/fallback and half-duplex ducking hooks.

✅ **Milestone 2 attempt — continuous mode, rolled back.** Continuous mode
worked but reintroduced the Phase 0 AEC problem in practice: with the mic open,
the app heard its own playback and fed it back as input. Because system AEC is
unavailable on this machine's built-in mic, continuous open-mic operation is a
dead end here. Reverted to **push-to-talk** (press to listen, release to
translate); mic frames are only forwarded between press and release, so the app
cannot hear itself.

Remaining in Phase 1:
- Revisit continuous/open-mic only via a board with AEC (e.g. an external
  USB interface with hardware echo cancellation), not the built-in mic.

✅ **Milestone 3 done — runtime promoted + project hygiene.** Backend moved out
of `phase0/` into a real `runtime/`:
- `runtime/voxweft/` — vendored VoxWeft (pinned `097fb20`), trimmed to the
  Python package + tests + docs, with our two small patches.
- `runtime/mini_bridge.py`, `runtime/supervisor.py` (3-service supervisor with
  restart-on-crash and disk-backed `status`).
- `scripts/setup.sh` (env + models + toolchain, idempotent), `backend.sh`
  (start/stop/restart/status), `smoke_test.sh` (headless end-to-end, passing).
- `git init` + `.gitignore`, `README.md`, `LICENSE`, `THIRD_PARTY_NOTICES.md`.
- Vendored tests: 46 passed / 2 skipped. Smoke test: translation + audio +
  turn_end delivered through the supervised backend.

### Phase 2 — Hy-MT2 as the translator — ✅ prototype done in Phase 0

`phase0/VoxWeft/voxweft/runtime/translator_hymt2.py` already calls llama-server's
`/v1/chat/completions`, and the server was patched to forward the target language
to the TTS bridge. Revisit only when hardening the vendored copy.

1. Implement `HyMT2Translator` against llama-server's `/v1/chat/completions`.
2. Exact prompt template, no system prompt, capped `max_tokens`, tuned temperature.
3. Simplify the router: Hy-MT2 handles any pair in one hop; keep dedicated fallback
   only for languages ASR/TTS can't serve.
4. Add llama-server launch/health-check to app startup; measure the HTTP hop.

*Acceptance:* clean translations on 3 priority pairs; adds < 500 ms; no script leakage.

### Phase 3 — Polish and packaging (1–2 days)

- Pick a ZONOS3 voice per target language (27 built-in voices); keep `voice=none`
  as the lowest-latency default. A limiter is optional — measured peak 0.942, 0% clipped.
- First-launch model manager: download progress, checksum, disk-space check.
- Menu-bar lifecycle across app + `mini_bridge.py` + `voxweft serve` + `llama-server`
  (with `-c 2048 -np 1`), with real error surfacing.
- Memory/CPU profiling on the M5; tune quant, `-ngl`, and timesteps.
- README with setup, supported pairs, and known limitations.

### Phase 4 (optional) — Pure Swift migration

Rebuild against `mlx-audio-swift` (which already supports ZONOS3), keeping only
`llama-server` for Hy-MT2. Do this only if a single-bundle distribution matters more
than the current three-process setup.

---

## 8. Decisions I need from you before Phase 1

1. **Priority language pairs** to tune and demo (pick 2–3, e.g. en↔es, en↔ja, zh↔en).
2. **Voice:** ZONOS3 built-in voice per language, cloned voices, or `voice=none`
   everywhere (lowest latency)?
3. **Distribution:** local development only, or a signed/notarized macOS app bundle?
4. **Half-duplex confirmation:** Phase 0 proved AEC is unavailable on the built-in
   mic, so v1 ducks the mic during playback. Confirm that is acceptable.

Once you answer, I can start Phase 1 and turn this into a runnable app.
