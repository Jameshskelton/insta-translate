"""Phase 0: test whether a long-lived session commits turns WITHOUT ptt_end.

Streams a spoken sample (repeated with pauses) through /ws/voice/v2 as if it were
a continuously open microphone. Never sends ptt_end. Reports segment_committed,
turn_end, ASR/MT/audio events and per-turn first-audio latency.

    python continuous_probe.py --src en --tgt es
"""
import argparse
import asyncio
import json
import time

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly


async def run(a):
    import websockets

    wav, sr = sf.read(a.wav, dtype="float32")
    if wav.ndim > 1:
        wav = wav.mean(axis=1)
    if sr != 16000:
        wav = resample_poly(wav, 16000, sr).astype(np.float32)

    gap = np.zeros(int(0.8 * 16000), dtype=np.float32)
    stream = np.concatenate([np.concatenate([wav, gap]) for _ in range(a.repeats)])
    pcm = (np.clip(stream, -1, 1) * 32767).astype(np.int16).tobytes()
    print(f"streaming {len(stream) / 16000:.1f}s of speech at real time, "
          f"repeats={a.repeats}, NO ptt_end")

    url = a.url
    async with websockets.connect(url, max_size=None) as ws:
        ready = json.loads(await ws.recv())
        assert ready["type"] == "ready", ready
        await ws.send(json.dumps({"type": "session_config", "mode": "interpreter",
                                  "src_lang": a.src, "tgt_lang": a.tgt}))
        ack = json.loads(await ws.recv())
        print(f"routes: {ack.get('routes')}")

        await ws.send(json.dumps({"type": "ptt_start"}))
        t0 = time.perf_counter()
        frame = 1024  # 32 ms @ 16 kHz int16
        for off in range(0, len(pcm), frame):
            await ws.send(pcm[off:off + frame])
            due = t0 + (off + frame) / 32000.0
            delay = due - time.perf_counter()
            if delay > 0:
                await asyncio.sleep(delay)
        print(f"audio sent; listening for turns (no ptt_end sent)...")

        turns = {}
        idle_since = time.perf_counter()
        while True:
            try:
                msg = await asyncio.wait_for(ws.recv(), timeout=1.0)
            except asyncio.TimeoutError:
                if time.perf_counter() - idle_since > a.wait:
                    break
                continue
            idle_since = time.perf_counter()
            if isinstance(msg, bytes):
                continue
            ev = json.loads(msg)
            t = ev.get("type")
            seq = ev.get("seq", 0)
            d = turns.setdefault(seq, {})
            if t == "segment_committed":
                d["commit"] = time.perf_counter()
                d["reason"] = ev.get("reason")
                print(f"  seg {seq}: COMMITTED ({ev.get('reason')}, {ev.get('ms')} ms)")
            elif t == "asr":
                d["asr"] = ev.get("text", "")
            elif t == "translation":
                d["mt"] = ev.get("text", "")
            elif t == "audio_start":
                now = time.perf_counter()
                d["audio"] = now
                if d.get("commit"):
                    print(f"  seg {seq}: FIRST AUDIO {1000 * (now - d['commit']):.0f}ms "
                          f"after commit; src={d.get('asr', '')[:45]!r} "
                          f"tgt={d.get('mt', '')[:45]!r}")
            elif t == "turn_end":
                # turn_end carries no seq — count it globally.
                turns.setdefault("__count__", {"n": 0})["n"] += 1
                print(f"  TURN_END (sentences={ev.get('sentences')}, "
                      f"total={ev.get('total_ms')}ms)")
            elif t == "error":
                print(f"  ERROR stage={ev.get('stage')}: {ev.get('message')}")
            elif t == "no_speech":
                print(f"  no_speech {ev}")

        n_commit = sum(1 for d in turns.values() if "commit" in d)
        n_end = turns.get("__count__", {}).get("n", 0)
        n_audio = sum(1 for d in turns.values() if "audio" in d)
        print(f"\nRESULT: {n_commit} segments committed, {n_end} turns ended, "
              f"{n_audio} produced audio — with NO ptt_end.")
        await ws.send(json.dumps({"type": "interrupt", "reason": "probe done"}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="ws://127.0.0.1:3100/ws/voice/v2")
    ap.add_argument("--wav", default="/Users/jamesskelton/Downloads/insta-translate/"
                                     "phase0/VoxWeft/samples/voices/en_src.wav")
    ap.add_argument("--src", default="en")
    ap.add_argument("--tgt", default="es")
    ap.add_argument("--repeats", type=int, default=4)
    ap.add_argument("--wait", type=float, default=25.0)
    asyncio.run(run(ap.parse_args()))


if __name__ == "__main__":
    main()
