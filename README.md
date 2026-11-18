# insta-translate

On-device, real-time spoken translation for Apple Silicon.

Speak into the mic → Qwen3-ASR transcribes → **Hy-MT2-1.8B** translates →
**ZONOS3-Mini** speaks the result. Everything runs locally on Metal via MLX and
llama.cpp; nothing leaves the machine.

## Status

Working personal tool. Push-to-talk interaction (hold to listen, release to
translate). See `PLAN.md` for the full design history and `phase0/RESULTS.md`
for the hardware audit that shaped it.

## Requirements

- Apple Silicon Mac (M1+; developed on M5)
- macOS 14+
- Python 3.12 via [`uv`](https://docs.astral.sh/uv/)
- [`llama-server`](https://github.com/ggml-org/llama.cpp) (`brew install llama.cpp`)
- ~4 GB disk for models (`~/.voxweft/models`)

## Setup (one time)

```bash
scripts/setup.sh          # venv + models + toolchain check (idempotent)
```

## Run

```bash
scripts/backend.sh start   # llama-server + mini-bridge + serve (supervised)
scripts/backend.sh status
scripts/backend.sh stop
scripts/smoke_test.sh      # headless end-to-end check
app/build.sh               # builds insta-translate.app
open app/build/insta-translate.app
```

In the app: **Connect**, choose source/target languages, then **hold the mic
button** while you speak and release to hear the translation.

## Architecture

```
SwiftUI app (app/)            hold-to-talk mic → 16k PCM, playback of 48k PCM
      │  WebSocket /ws/voice/v2
      ▼
voxweft serve (runtime/)      segmentation → ASR → MT → TTS orchestration
      │  HTTP
      ▼
mini_bridge (runtime/)        Qwen3-ASR-1.7B (MLX) + ZONOS3-Mini (MLX)
      │  HTTP
      ▼
llama-server                  Hy-MT2-1.8B-GGUF Q4_K_M   (Metal, -c 2048 -np 1)
```

`runtime/supervisor.py` keeps the three services up and restarts them on crash.
Vendored third-party code lives in `runtime/voxweft/` (VoxWeft Apache-2.0, pinned
at commit `097fb20`, with two small local patches documented in
`THIRD_PARTY_NOTICES.md`).

## Measured latency (M5, 24 GB)

| Stage | Time |
|---|---|
| Utterance endpointing | ~0.45 s silence |
| ASR (10 s clip) | ~0.7 s  |
| Hy-MT2 translation | 180–520 ms |
| ZONOS3 first audio (warm) | 95–200 ms |
| Turn (server `total_ms`) | ~1.9–2.1 s |

## Known limitations

- **Push-to-talk only.** Acoustic echo cancellation cannot start on this
  MacBook Pro's built-in mic (AVAudioEngine -10875), so open-mic continuous
  mode feedback-loops on its own output. A USB interface/headset with hardware
  AEC would enable it.
- Language coverage is the *intersection* per pair: ASR ~26 / MT 36 / TTS 43.
  Low-resource ASR (Lao/Khmer/Burmese) is poor.
- Error surfaces as text in the app; no model-license/attribution UI yet.

## License

Our code: Apache-2.0 (see `LICENSE`). Third-party components (VoxWeft, ZONOS3,
Qwen3-ASR, Hy-MT2, llama.cpp, MLX stack) each carry their own licenses; see
`THIRD_PARTY_NOTICES.md`.
