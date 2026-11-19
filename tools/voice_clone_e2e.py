"""E2E voice-cloning check for insta-translate.

Generates a reference voice via mini_bridge, then streams it through serve's
PTT path so the translation comes back in that (cloned) voice; writes
/tmp/ref.wav and /tmp/cloned_out.wav for listening.

Requires the backend running: scripts/backend.sh start

Run:  runtime/.venv/bin/python tools/voice_clone_e2e.py
"""
import asyncio, io, json, sys, time

import numpy as np
import soundfile as sf
import requests

BRIDGE = "http://127.0.0.1:8134"
WS = "ws://127.0.0.1:3100/ws/voice/v2"
REF_TXT = "My name is Ada. I am testing voice cloning on a laptop."
TGT_TXT = "Mi nombre es Ada. Estoy probando la clonación de voz."

def gen_ref():
    print(">> generating reference voice (jett)")
    out = bytearray()
    with requests.post(f"{BRIDGE}/generate", json={
        "target_text": REF_TXT, "voice": "jett", "lang_code": "English", "stream": True,
    }, stream=True, timeout=120) as r:
        r.raise_for_status()
        for c in r.iter_content(chunk_size=None):
            if c: out += c
    wav = np.frombuffer(bytes(out), dtype=np.int16).astype(np.float32) / 32768.0
    sf.write("/tmp/ref.wav", wav, 48000)
    print(f"   saved ref.wav: {len(wav)/48000:.1f}s @48k")
    return wav

async def main():
    ref48 = gen_ref()
    ref16 = np.ascontiguousarray(
        __import__("scipy.signal", fromlist=["resample_poly"]).resample_poly(ref48, 16000, 48000),
        dtype=np.float32)
    pcm = (np.clip(ref16, -1, 1) * 32767).astype(np.int16).tobytes()

    import websockets
    async with websockets.connect(WS, max_size=None) as ws:
        ready = json.loads(await ws.recv())
        assert ready["type"] == "ready"
        await ws.send(json.dumps({"type": "session_config", "mode": "interpreter",
                                  "src_lang": "en", "tgt_lang": "es"}))
        await ws.recv()  # ack

        await ws.send(json.dumps({"type": "ptt_start"}))
        frame = 1024
        t0 = time.perf_counter()
        for off in range(0, len(pcm), frame):
            await ws.send(pcm[off:off + frame])
            due = t0 + (off + frame) / 32000.0
            d = due - time.perf_counter()
            if d > 0: await asyncio.sleep(d)
        await ws.send(json.dumps({"type": "ptt_end"}))
        print(">> streamed reference; waiting for the cloned turn…")

        out_pcm = bytearray(); seen = []
        idle = time.perf_counter()
        while True:
            try:
                msg = await asyncio.wait_for(ws.recv(), timeout=1.0)
            except asyncio.TimeoutError:
                if time.perf_counter() - idle > 25: break
                continue
            idle = time.perf_counter()
            if isinstance(msg, bytes):
                out_pcm += msg; continue
            ev = json.loads(msg)
            t = ev.get("type")
            seen.append(t)
            if t in ("asr", "translation"):
                print(f"  {t}: {ev.get('text','')[:70]}")
            elif t in ("audio_start", "audio_end", "turn_end", "error"):
                print(f"  {t} latency={ev.get('tts_latency_ms','')} samples={ev.get('samples','')}")
        if out_pcm:
            sf.write("/tmp/cloned_out.wav",
                     np.frombuffer(bytes(out_pcm), dtype=np.int16), 48000)
            print(f">> saved /tmp/cloned_out.wav ({len(out_pcm)/2/48000:.1f}s)")
        ok = "translation" in seen and any(x in seen for x in ("audio_start", "audio_end"))
        print("RESULT:", "PASS" if ok else "FAIL")

asyncio.run(main())
