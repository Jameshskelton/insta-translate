#!/usr/bin/env python3
"""Supervisor for the insta-translate backend (3 services).

Starts llama-server (Hy-MT2), mini_bridge (ASR + ZONOS3 TTS), and the voxweft
WebSocket runtime. Restarts any service that dies, logs to runtime/run/, and
can stop/restart everything as one unit.

Usage:  supervisor.py [start|stop|restart|status]
"""
from __future__ import annotations

import logging
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent          # runtime/
RUN = ROOT / "run"
VENV_BIN = ROOT / ".venv" / "bin"
MODELS = Path(os.environ.get("VOXWEFT_MODEL_DIR", Path.home() / ".voxweft/models"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("supervisor")

_services = {}
_stopping = threading.Event()


def http_ok(url: str, timeout: float = 2.0) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status == 200
    except Exception:
        return False


def service(name, argv, env_extra, ready_url, cwd=None, start_timeout=300):
    _services[name] = dict(
        argv=argv, env_extra=env_extra, ready_url=ready_url,
        cwd=cwd or ROOT, start_timeout=start_timeout,
        proc=None, logfile=RUN / f"{name}.log", backoff=0, cr_ch=0,
    )


# ---- service definitions ---------------------------------------------------

service(
    "llama-server",
    ["llama-server",
     "-hf", "tencent/Hy-MT2-1.8B-GGUF:Q4_K_M",
     "--port", "8080", "--host", "127.0.0.1",
     "--jinja", "-ngl", "99", "-c", "2048", "-np", "1"],
    {},
    "http://127.0.0.1:8080/health",
    start_timeout=600,          # first run downloads the ~1.1 GB GGUF
)

service(
    "mini-bridge",
    [str(VENV_BIN / "python"), str(ROOT / "mini_bridge.py")],
    {"ZONOS_MODEL": str(MODELS / "ZONOS3-Mini"), "PORT": "8134",
     "VOXWEFT_MODEL_DIR": str(MODELS)},
    "http://127.0.0.1:8134/ready",
    start_timeout=420,
)

service(
    "serve",
    [str(VENV_BIN / "voxweft"), "serve", "--port", "3100"],
    {"VOXWEFT_BRIDGE_URL": "http://127.0.0.1:8134",
     "VOXWEFT_MT_URL": "http://127.0.0.1:8080",
     "VOXWEFT_MODEL_DIR": str(MODELS)},
    "http://127.0.0.1:3100/health",
    start_timeout=120,
)


# ---- process management -----------------------------------------------------

def _env(name):
    env = dict(os.environ)
    env.update(_services[name]["env_extra"])
    return env


def start_one(name):
    s = _services[name]
    RUN.mkdir(parents=True, exist_ok=True)
    logf = open(s["logfile"], "ab")
    file_p = subprocess.Popen(s["argv"], cwd=str(s["cwd"]), env=_env(name),
                              stdout=logf, stderr=subprocess.STDOUT, start_new_session=True)
    s["proc"] = file_p
    (RUN / f"{name}.pid").write_text(str(file_p.pid))
    log.info("%s started (pid %d)", name, file_p.pid)
    return file_p


def wait_ready(name):
    s = _services[name]
    deadline = time.monotonic() + s["start_timeout"]
    while time.monotonic() < deadline:
        if _stopping.is_set():
            return False
        if s["proc"].poll() is not None:
            log.error("%s exited early (code %s); tail:", name, s["proc"].returncode)
            print(_tail(s["logfile"], 20))
            return False
        if http_ok(s["ready_url"]):
            log.info("%s ready", name)
            return True
        time.sleep(1)
    log.error("%s not ready within %ss", name, s["start_timeout"])
    return False


def monitor(name):
    s = _services[name]
    while not _stopping.is_set():
        s["proc"].wait()
        if _stopping.is_set():
            break
        s["cr_ch"] += 1
        s["backoff"] = min(2.0 * 2 ** s["cr_ch"], 60.0)
        if s["cr_ch"] >= 10:
            log.error("%s crashed 10x consecutively — leaving it stopped", name)
            return
        log.error("%s died (code %s); restarting in %.0fs",
                  name, s["proc"].returncode, s["backoff"])
        time.sleep(s["backoff"])
        start_one(name)
        if not wait_ready(name):
            log.error("%s failed to come back up", name)


def stop_one(name):
    s = _services[name]
    p = s.get("proc")
    if not p or p.poll() is not None:
        return
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except Exception:
        p.terminate()
    try:
        p.wait(timeout=8)
    except Exception:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except Exception:
            pass
    log.info("%s stopped", name)


def _tail(path, n=15):
    try:
        lines = path.read_text(errors="replace").splitlines()[-n:]
    except Exception:
        return "  (no log yet)"
    return "\n".join(f"    | {l}" for l in lines)


def start_all():
    RUN.mkdir(parents=True, exist_ok=True)
    for name in _services:
        start_one(name)
    for name in _services:
        if not wait_ready(name):
            log.error("backend NOT fully up: %s failed", name)
            return False
    log.info("all services ready")
    return True


def stop_all():
    log.info("stopping all services…")
    _stopping.set()
    for name in reversed(list(_services)):
        stop_one(name)


def _pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def status():
    RUN.mkdir(parents=True, exist_ok=True)
    for name, s in _services.items():
        pidf = RUN / f"{name}.pid"
        pid = int(pidf.read_text().strip()) if pidf.exists() else None
        alive = _pid_alive(pid)
        ready = " ready" if (alive and http_ok(s["ready_url"])) else ""
        print(f"{name:14} {'RUNNING' if alive else 'stopped'}{ready}"
              f"{f'  (pid {pid})' if pid else ''}")
        if not alive and pid:
            print(_tail(s["logfile"], 6))


def main():
    RUN.mkdir(parents=True, exist_ok=True)
    cmd = sys.argv[1] if len(sys.argv) > 1 else "start"
    # Start monitors after a successful boot so a crash during the very first
    # model load (e.g. disk full) surfaces to the operator instead of
    # spinning the restart loop.
    if cmd == "start":
        if start_all():
            for name in _services:
                threading.Thread(target=monitor, args=(name,), daemon=True).start()
            log.info("supervising %d services (Ctrl+C to stop)", len(_services))
            signal.signal(signal.SIGINT, lambda *_: stop_all())
            signal.signal(signal.SIGTERM, lambda *_: stop_all())
            _stopping.wait()
        return 1 if any(s["proc"] and s["proc"].poll() is not None for s in _services.values()) else 0
    if cmd == "stop":
        stop_all()
        return 0
    if cmd == "restart":
        stop_all()
        _stopping.clear()
        if not start_all():
            return 1
        return _hold()
    if cmd == "status":
        status()
        return 0
    print(__doc__)
    return 2


def _hold():
    for name in _services:
        threading.Thread(target=monitor, args=(name,), daemon=True).start()
    signal.signal(signal.SIGINT, lambda *_: stop_all())
    signal.signal(signal.SIGTERM, lambda *_: stop_all())
    _stopping.wait()
    return 0


if __name__ == "__main__":
    sys.exit(main())
