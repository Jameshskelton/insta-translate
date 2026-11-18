"""Hy-MT2 translator via llama-server's OpenAI-compatible HTTP endpoint.

Phase 0 adapter. Kept deliberately small: the router passes FLORES-200 codes,
the model card wants full English language names, so we map via FLORES_TO_NAME.
"""
from __future__ import annotations

import os
import time
import logging

import requests

from voxweft.runtime.router import FLORES_TO_NAME, normalize

log = logging.getLogger("voxweft.translator.hymt2")


class HyMT2Translator:
    def __init__(self, url: str | None = None, model: str = "hy-mt2"):
        self.url = (url or os.environ.get("VOXWEFT_MT_URL", "http://127.0.0.1:8080")
                    ).rstrip("/") + "/v1/chat/completions"
        self.model = model

    def _name(self, code: str) -> str:
        return FLORES_TO_NAME.get(normalize(code), str(code))

    def translate(self, text: str, src_lang: str, tgt_lang: str,
                  max_new_tokens: int = 256) -> dict:
        t0 = time.perf_counter()
        prompt = (
            f"Translate the following text into {self._name(tgt_lang)}. Note that "
            "you should only output the translated result without any additional "
            f"explanation: {text}"
        )
        try:
            r = requests.post(self.url, timeout=120, json={
                "model": self.model,
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0.3,
                "top_p": 0.6,
                "top_k": 20,
                "repetition_penalty": 1.05,
                "max_tokens": max_new_tokens,
            })
            r.raise_for_status()
            out = r.json()["choices"][0]["message"]["content"].strip()
        except Exception as e:
            log.exception("Hy-MT2 request failed")
            return {"text": "", "error": str(e),
                    "latency_ms": round((time.perf_counter() - t0) * 1000)}
        return {"text": out, "latency_ms": round((time.perf_counter() - t0) * 1000)}

    def warmup(self) -> None:
        """Warm the server with one small request through the real code path."""
        result = self.translate("Hello.", "eng_Latn", "zho_Hans", max_new_tokens=32)
        if result.get("error"):
            log.warning("Hy-MT2 warmup failed: %s", result["error"])
        else:
            log.info("Hy-MT2 warmup: %s -> %s", result["text"], result["latency_ms"])
