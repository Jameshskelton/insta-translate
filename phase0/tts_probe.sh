#!/bin/zsh
# Wait for the bridge to be genuinely ready (/ready, not /health), then run TTS twice.
VENV=/Users/jamesskelton/Downloads/insta-translate/phase0/VoxWeft/.venv
BRIDGE=http://127.0.0.1:8133

for i in {1..600}; do
  code=$(curl -s -m 2 "$BRIDGE/ready" -o /dev/null -w '%{http_code}')
  if [[ "$code" == "200" ]]; then
    echo "bridge ready after ${i}s"
    break
  fi
  sleep 1
done

code=$(curl -s -m 2 "$BRIDGE/ready" -o /dev/null -w '%{http_code}')
if [[ "$code" != "200" ]]; then
  echo "BRIDGE NEVER READY (last=$code)"; tail -40 /Users/jamesskelton/Downloads/insta-translate/phase0/bridge.log; exit 1
fi

for n in 1 2; do
  echo "=== TTS run $n ==="
  VOXCPM2_MODEL=/Users/jamesskelton/.voxweft/models/VoxCPM2 \
    "$VENV/bin/voxweft" say "VoxWeft is running on this MacBook Pro. We are testing real time speech translation." \
    --stream -o /Users/jamesskelton/Downloads/insta-translate/phase0/tts_$n.wav 2>&1 | tail -12
done
