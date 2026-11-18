#!/bin/bash
# Control the backend as one unit. Delegates to runtime/supervisor.py.
#   backend.sh start|stop|restart|status
set -euo pipefail
W="$(cd "$(dirname "$0")/.." && pwd)"
exec "$W/runtime/.venv/bin/python" "$W/runtime/supervisor.py" "${1:-status}"
