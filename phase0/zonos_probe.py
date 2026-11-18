"""Phase 0: benchmark ZONOS3-Mini streaming TTS on the M5."""
import time

from mlx_audio.tts import load

MODEL = "/Users/jamesskelton/.voxweft/models/ZONOS3-Mini"
TEXT = "Hello, this is ZONOS3 Mini speaking on an Apple M5 MacBook Pro."

model = load(MODEL)
print("voices:", model.voices[:12], "... total", len(model.voices))


def bench(label, **kwargs):
    t0 = time.perf_counter()
    first = None
    pcm = bytearray()
    for result in model.generate(stream=True, streaming_interval=0.2, **kwargs):
        if first is None:
            first = time.perf_counter() - t0
        audio = result.audio
        import numpy as np
        arr = np.asarray(audio)
        pcm.extend(arr.astype("float32").tobytes())
    total = time.perf_counter() - t0
    sr = result.sample_rate
    seconds = len(pcm) / 4 / sr
    print(f"{label}: first={first * 1000:.0f}ms total={total:.2f}s "
          f"audio={seconds:.2f}s rtf={total / seconds:.2f} sr={sr}")


bench("voice=jett  ", text=TEXT, voice="jett", lang_code="en")
bench("voice=none  ", text=TEXT, voice="none", lang_code="en")
bench("clone en_tgt", text=TEXT, lang_code="en",
      ref_audio="/Users/jamesskelton/Downloads/insta-translate/phase0/VoxWeft/samples/voices/en_tgt.wav")
