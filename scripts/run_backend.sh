#!/bin/bash
# Convenience wrapper (kept for muscle memory) — the real control is scripts/backend.sh.
set -euo pipefail
W="$(cd "$(dirname "$0")/.." && pwd)"
exec "$W/scripts/backend.sh" start
