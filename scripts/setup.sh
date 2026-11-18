#!/bin/bash
# One-time setup for insta-translate: Python env, models, and a check of the
# llama.cpp toolchain. Idempotent — safe to re-run.
set -euo pipefail
W="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$W/runtime"
MODELS="${VOXWEFT_MODEL_DIR:-$HOME/.voxweft/models}"

[[ "$(uname -m)" == "arm64" ]] || { echo "Apple Silicon required (MLX + Metal)."; exit 1; }

echo "==> Python environment (Python 3.12)"
command -v uv >/dev/null || { echo "uv is required (brew install uv)"; exit 1; }
if [ ! -x "$RUNTIME/.venv/bin/python" ]; then
  uv venv --python 3.12 "$RUNTIME/.venv"
fi
uv pip install --python "$RUNTIME/.venv/bin/python" \
  -e "$RUNTIME/voxweft[runtime]" websockets

echo "==> llama.cpp toolchain"
command -v llama-server >/dev/null || {
  echo "llama-server is required (brew install llama.cpp)"; exit 1
}
llama-server --version | head -1

echo "==> Models in $MODELS"
mkdir -p "$MODELS"
HF="$RUNTIME/.venv/bin/hf"

dl() {  # dl <repo> <dir>
  if [ -f "$MODELS/$2/config.json" ]; then
    echo "  $2 — already present"
  else
    echo "  downloading $1 (~$3 GB)…"
    "$HF" download "$1" --local-dir "$MODELS/$2"
  fi
}

dl mlx-community/ZONOS3-Mini           ZONOS3-Mini        1.3
dl mlx-community/Qwen3-ASR-1.7B-8bit   Qwen3-ASR-1.7B-8bit 2.3

NEED_GB=5; HAVE_GB=$(df -k "$MODELS" | awk 'NR==2 {print $4/1048576}')
if (( $(echo "$HAVE_GB < $NEED_GB" | bc 2>/dev/null || echo 0) )); then
  echo "WARNING: only ${HAVE_GB}GB free; models need room for downloads."
fi

echo "==> import check"
"$RUNTIME/.venv/bin/python" -c "import mlx, mlx_audio, voxweft; print('mlx', mlx.__version__, '| mlx_audio OK | voxweft OK')"

echo
echo "setup complete. Next:"
echo "  scripts/backend.sh start     # llama-server + mini-bridge + serve"
echo "  scripts/backend.sh status"
echo "  open app/build/insta-translate.app"
