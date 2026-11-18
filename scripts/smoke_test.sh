#!/bin/bash
# End-to-end smoke test: spins the app headless (text_input) through the real
# backend and asserts a translation + TTS playback + turn_end were delivered.
# Requires the backend to be up: scripts/backend.sh start
set -euo pipefail
W="$(cd "$(dirname "$0")/.." && pwd)"
APP="$W/app/build/insta-translate.app/Contents/MacOS/insta-translate"
LOG="$(mktemp /tmp/it-smoke.XXXXXX.log)"

for u in http://127.0.0.1:8080/health http://127.0.0.1:8134/ready http://127.0.0.1:3100/health; do
  if ! curl -s -m 2 "$u" -o /dev/null; then
    echo "backend not ready ($u) — run: scripts/backend.sh start"
    exit 2
  fi
done

echo "running headless turn…"
"$APP" --text "This is a smoke test of the translation pipeline." > "$LOG" 2>&1 &
PID=$!
for i in $(seq 1 60); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
kill -0 "$PID" 2>/dev/null && { echo "FAIL: app timed out"; kill "$PID"; tail -20 "$LOG"; exit 1; }

grep -q '"type": "translation"' "$LOG" && \
grep -q '"type": "turn_end"'    "$LOG" && \
grep -q '"type": "audio_end"'   "$LOG" \
  && { echo "PASS — translation, audio, and turn_end delivered:"; \
       grep -o '"text": "[^"]*"' "$LOG" | head -1; exit 0; }
echo "FAIL — missing events in log:"; tail -20 "$LOG"; exit 1
