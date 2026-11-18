"""Time the bridge's streamed /generate with and without a named cloned voice."""
import time
import requests

URL = "http://127.0.0.1:8133/generate"
TEXT = "Hola, ¿cómo estás hoy? Estamos probando un sistema de traducción."

for voice in (None, "es_tgt"):
    t0 = time.perf_counter()
    first = None
    n = 0
    with requests.post(URL, json={
        "target_text": TEXT, "voice": voice, "stream": True,
    }, stream=True, timeout=300) as r:
        r.raise_for_status()
        for chunk in r.iter_content(chunk_size=None):
            if not chunk:
                continue
            n += 1
            if first is None:
                first = time.perf_counter() - t0
    total = time.perf_counter() - t0
    print(f"voice={voice!r:10} first={first * 1000:.0f}ms total={total:.1f}s "
          f"chunks={n} audio={n * 0.2:.1f}s")
