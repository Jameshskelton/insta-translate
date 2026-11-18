# Third-Party Notices

This project builds on the following third-party software. Each component is
listed with its source, license, and — where we modified it — what changed.

## Vendored

### VoxWeft
- **Source:** https://github.com/HenryZ838978/VoxWeft (pinned at commit `097fb20`, 2026-09-22)
- **License:** Apache-2.0
- **Role:** WebSocket runtime (`serve`), `IncrementalSegmenter`, orchestrator,
  language router, tests, `docs/DEVLOG.md`.
- **Local patches (kept deliberately small):**
  1. `voxweft/runtime/server.py` — optional `VOXWEFT_MT_URL` backend that loads
     `HyMT2Translator` (author: insta-translate) instead of the in-process
     Qwen3-4B/NLLB translators; forwards the session's target language to the
     TTS bridge via `TTS_LANG_CODE`.
  2. `voxweft/runtime/translator_hymt2.py` — new file (Apache-2.0, our code):
     thin client for llama-server's OpenAI-compatible endpoint.
- VoxWeft itself ports VoxCPM2 to MLX; we do **not** run that port in this app
  (replaced by ZONOS3-Mini via `runtime/mini_bridge.py`).

## Model weights

| Model | Source | License |
|---|---|---|
| ZONOS3-Mini | https://huggingface.co/Zyphra/ZONOS3-Mini (MLX port: mlx-community/ZONOS3-Mini) | Apache-2.0 (weights); backbone/codec adapted from Zyphra (MIT); Gated DeltaNet kernel MIT (Apple) |
| Qwen3-ASR-1.7B | https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit | Apache-2.0 |
| Hy-MT2-1.8B | https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF | Apache-2.0 |

VoxWeft's optional NLLB-200 fallback is **CC-BY-NC-4.0** and is **not used** by
this app.

## Runtimes / libraries

| Component | License |
|---|---|
| llama.cpp | MIT |
| MLX / mlx / mlx-lm / mlx-audio / mlx-whisper | MIT (Apple) |
| FastAPI / Starlette | MIT |
| Uvicorn | BSD-3-Clause |
| SoundFile / SciPy / NumPy / Requests / Transformers | per-package (BSL/BDS/Apache) |

## Note on distribution

If you distribute or sign this app for others, review the "Note on licensing
attribution" constraints of each model provider (weight + codec licenses above)
and include the relevant NOTICE/OSI text in the app bundle.
