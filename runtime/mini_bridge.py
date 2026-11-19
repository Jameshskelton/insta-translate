"""Drop-in replacement for VoxWeft's bridge: Qwen3-ASR + ZONOS3-Mini TTS.

Same HTTP surface as voxweft bridge so the unmodified VoxWeft runtime can talk
to it:  POST /v1/chat/completions (ASR), POST /generate (streamed PCM),
        GET /ready, GET /health, GET /voices.

MLX models are loaded and inferred on one dedicated thread each (streams are
thread-bound). ZONOS3 emits 44.1 kHz; we resample to 48 kHz to match VoxWeft's
player and emit 200 ms / 9600-sample int16 chunks.
"""
from __future__ import annotations

import asyncio
import base64
import io
import logging
import os
import threading
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import soundfile as sf
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from pydantic import BaseModel
from scipy.signal import resample_poly

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("mini-bridge")

MODEL_DIR = os.environ.get("VOXWEFT_MODEL_DIR", os.path.expanduser("~/.voxweft/models"))
ASR_DIR = os.environ.get("VOXWEFT_ASR_MODEL", os.path.join(MODEL_DIR, "Qwen3-ASR-1.7B-8bit"))
ZONOS_DIR = os.environ.get("ZONOS_MODEL", os.path.join(MODEL_DIR, "ZONOS3-Mini"))
VOICE = os.environ.get("ZONOS_VOICE", "none")
CHUNK = 9600  # 200 ms @ 48 kHz

NAME_TO_CODE = {
    "english": "en", "mandarin chinese": "zh", "chinese": "zh", "spanish": "es",
    "french": "fr", "german": "de", "italian": "it", "portuguese": "pt",
    "japanese": "ja", "korean": "ko", "russian": "ru", "arabic": "ar",
    "hindi": "hi", "vietnamese": "vi", "indonesian": "id", "malay": "ms",
    "thai": "th", "tagalog": "tl", "filipino": "tl", "dutch": "nl",
    "turkish": "tr", "hebrew": "he", "polish": "pl", "czech": "cs",
    "ukrainian": "uk", "bengali": "bn", "tamil": "ta", "telugu": "te",
    "marathi": "mr", "gujarati": "gu", "swedish": "sv", "danish": "da",
    "norwegian": "no", "finnish": "fi", "greek": "el", "slovak": "sk",
    "hungarian": "hu", "romanian": "ro", "bulgarian": "bg", "georgian": "ka",
    "kannada": "kn", "malayalam": "ml", "punjabi": "pa", "odia": "or",
    "urdu": "ur",
}

app = FastAPI(title="voxweft mini-bridge (Qwen3-ASR + ZONOS3)")

_tts_executor = ThreadPoolExecutor(max_workers=1)
_asr_executor = ThreadPoolExecutor(max_workers=1)
_tts = None
_asr = None
_asr_supported = None
_ready = threading.Event()


def _load_tts_sync():
    global _tts
    if _tts is None:
        from mlx_audio.tts import load
        log.info("loading ZONOS3 from %s", ZONOS_DIR)
        _tts = load(ZONOS_DIR)
        log.info("ZONOS3 loaded; %d voices", len(_tts.voices))
    return _tts


def _load_asr_sync():
    global _asr
    if _asr is None:
        from mlx_audio.stt.utils import load_model
        log.info("loading ASR from %s", ASR_DIR)
        _asr = load_model(ASR_DIR)
    return _asr


async def _get_tts():
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(_tts_executor, _load_tts_sync)


async def _get_asr():
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(_asr_executor, _load_asr_sync)


def _decode_audio_16k(payload: bytes) -> np.ndarray:
    try:
        audio, sr = sf.read(io.BytesIO(payload), dtype="float32")
    except Exception:
        return np.frombuffer(payload, dtype=np.int16).astype(np.float32) / 32768.0
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != 16000:
        audio = resample_poly(audio, 16000, sr).astype(np.float32)
    return np.ascontiguousarray(audio, dtype=np.float32)


@app.get("/health")
async def health():
    return {"status": "ok", "service": "mini-bridge"}


@app.get("/ready")
async def ready():
    st = {"tts": _tts is not None, "asr": _asr is not None, "warmup_done": _ready.is_set()}
    return JSONResponse(st, status_code=200 if all(st.values()) else 503)


@app.get("/voices")
async def voices():
    tts = await _get_tts()
    return {"voices": list(tts.voices)}


class GenReq(BaseModel):
    target_text: str
    voice: str | None = None
    voice_type: str | None = None
    external_id: str | None = None
    external_text: str | None = None
    lang_code: str | None = None
    ref_audio_wav: str | None = None      # base64 WAV of the speaker (voice cloning)
    stream: bool = False
    temperature: float = 0.75
    cfg_value: float = 1.0
    cfg_scale: float = 1.0
    do_normalize: bool = True


def _decode_ref_audio_wav(b64: str) -> np.ndarray | None:
    """base64 WAV → float32 mono @ 44.1 kHz (ZONOS3's reference format).
    Returns None for unusable input so the caller falls back to voice="none"."""
    try:
        payload = base64.b64decode(b64)
        audio, sr = sf.read(io.BytesIO(payload), dtype="float32")
    except Exception as e:
        log.warning("ref audio decode failed: %s", e)
        return None
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != 44100:
        audio = resample_poly(audio, 44100, sr).astype(np.float32)
    audio = np.ascontiguousarray(audio, dtype=np.float32)
    if len(audio) < int(0.4 * 44100):      # too short to clone meaningfully
        log.warning("ref audio too short (%.2fs) — skipping clone", len(audio) / 44100)
        return None
    return audio


@app.post("/generate")
async def generate(req: GenReq, request: Request):
    tts = await _get_tts()
    voice = req.voice if req.voice in tts.voices else VOICE
    lang = NAME_TO_CODE.get((req.lang_code or "").lower(),
                            NAME_TO_CODE.get((req.external_id or "").lower(), "en"))
    ref = _decode_ref_audio_wav(req.ref_audio_wav) if req.ref_audio_wav else None
    if ref is not None:
        voice = "none"                       # the speaker comes from the reference
    q: asyncio.Queue = asyncio.Queue(maxsize=64)
    stop = threading.Event()

    def _produce():
        try:
            buf = np.zeros(0, dtype=np.float32)
            y = buf
            pending = 0
            kw = dict(text=req.target_text, voice=voice, lang_code=lang,
                      stream=True, streaming_interval=0.2,
                      temperature=req.temperature,
                      speaker_cfg_scale=req.cfg_scale)
            if ref is not None:
                kw["ref_audio"] = ref
                log.info("voice cloning from %.2fs reference", len(ref) / 44100)
            for result in tts.generate(**kw):
                if stop.is_set():
                    break
                arr = np.asarray(result.audio, dtype=np.float32).reshape(-1)
                buf = np.concatenate([buf, arr])
                # Resample the whole accumulated buffer so chunk boundaries
                # stay continuous. Emit only complete 200 ms blocks; keep a
                # margin so the resampler's tail never affects emitted samples.
                y = resample_poly(buf, 160, 147)
                usable = len(y) - 512
                n_blocks = max(0, (usable - pending) // CHUNK)
                if n_blocks:
                    tail = y[pending:pending + n_blocks * CHUNK]
                    i16 = (np.clip(tail, -1, 1) * 32767).astype(np.int16)
                    loop.call_soon_threadsafe(q.put_nowait, i16.tobytes())
                    pending += n_blocks * CHUNK
            if not stop.is_set() and pending < len(y):
                tail = y[pending:]
                if len(tail):
                    i16 = (np.clip(tail, -1, 1) * 32767).astype(np.int16)
                    loop.call_soon_threadsafe(q.put_nowait, i16.tobytes())
        except Exception as e:
            log.exception("ZONOS3 generation failed")
            loop.call_soon_threadsafe(q.put_nowait, e)
        finally:
            loop.call_soon_threadsafe(q.put_nowait, None)

    loop = asyncio.get_running_loop()
    loop.run_in_executor(_tts_executor, _produce)

    async def _stream():
        while True:
            item = await q.get()
            if item is None:
                break
            if isinstance(item, Exception):
                raise item
            yield item

    return StreamingResponse(_stream(), media_type="application/octet-stream")


@app.post("/v1/chat/completions")
async def asr_chat(req: Request):
    body = await req.json()
    audio_url = ""
    for m in body.get("messages", []):
        for c in m.get("content", []):
            if isinstance(c, dict) and c.get("type") == "audio_url":
                audio_url = c["audio_url"]["url"]
    if not audio_url.startswith("data:"):
        return JSONResponse({"error": "expected data URL"}, status_code=400)
    audio = _decode_audio_16k(base64.b64decode(audio_url.split(",", 1)[1]))
    lang_name = body.get("language") or "English"
    hotwords = body.get("hotword") or []

    global _asr_supported
    asr = await _get_asr()
    if _asr_supported is None:
        langs = getattr(getattr(asr, "config", None), "support_languages", None) or []
        _asr_supported = {str(x).lower() for x in langs}
    hint = lang_name if (not _asr_supported or str(lang_name).lower() in _asr_supported) else None
    loop = asyncio.get_running_loop()
    text = await loop.run_in_executor(
        _asr_executor, lambda: asr.generate(audio, language=hint, hotwords=hotwords))
    text = getattr(text, "text", str(text)).strip()
    return {"choices": [{"message": {"content": f"language {lang_name}<asr_text>{text}"}}]}


@app.on_event("startup")
async def warmup():
    async def _warm():
        tts = await _get_tts()
        await asyncio.get_running_loop().run_in_executor(
            _tts_executor, lambda: next(tts.generate(
                text="Hello.", voice=VOICE if VOICE != "none" else "none",
                lang_code="en", stream=True, streaming_interval=0.2)))
        await _get_asr()
        _ready.set()
        log.info("warmup done")
    asyncio.create_task(_warm())


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("PORT", "8134")))
