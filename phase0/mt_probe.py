"""Phase 0: probe Hy-MT2 via llama-server's OpenAI-compatible endpoint."""
import json
import time
import urllib.request

URL = "http://127.0.0.1:8080/v1/chat/completions"

PAIRS = [
    ("English", "Chinese", "The weather is lovely today, so let's go for a walk in the park."),
    ("English", "Spanish", "Could you please translate this sentence for me right now?"),
    ("English", "Japanese", "We are testing a real-time translation and speech system."),
    ("Chinese", "English", "今天天气真好，我们一起去公园散步吧。"),
]

for src, tgt, text in PAIRS:
    prompt = (
        f"Translate the following text into {tgt}. Note that you should only output "
        f"the translated result without any additional explanation: {text}"
    )
    body = json.dumps({
        "model": "hy-mt2",
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.7,
        "top_p": 0.6,
        "top_k": 20,
        "repetition_penalty": 1.05,
        "max_tokens": 256,
    }).encode()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=120) as r:
        result = json.loads(r.read())
    dt = (time.perf_counter() - t0) * 1000
    out = result["choices"][0]["message"]["content"].strip()
    print(f"[{src} -> {tgt}] {dt:.0f} ms")
    print(f"  in : {text}")
    print(f"  out: {out}")
    leaked = any(w in out.lower() for w in ("translate", "translation", "here is", "以下是", "翻译"))
    print(f"  clean: {'NO — explanation leaked' if leaked else 'yes'}")
    print()
