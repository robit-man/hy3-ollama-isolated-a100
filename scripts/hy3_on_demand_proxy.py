#!/usr/bin/env python3
"""Keep the Hy3 endpoint available without keeping the model resident.

The proxy owns the public Hy3 port.  It starts llama-server on a private
loopback port on the first non-health request, forwards that request once the
model is ready, and sends SIGINT after a quiet period with no active requests.
This is deliberately stdlib-only so the user service stays lightweight.
"""

from __future__ import annotations

import http.client
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional
from urllib.parse import urlsplit


def env_int(name: str, default: int, minimum: int = 1) -> int:
    try:
        value = int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default
    return value if value >= minimum else default


PUBLIC_HOST = os.environ.get("HOST", "127.0.0.1")
PUBLIC_PORT = env_int("PORT", 11453)
BACKEND_HOST = os.environ.get("HY3_BACKEND_HOST", "127.0.0.1")
BACKEND_PORT = env_int("HY3_BACKEND_PORT", PUBLIC_PORT + 1)
IDLE_TIMEOUT_SEC = env_int("HY3_IDLE_TIMEOUT_SEC", 300)
LOAD_TIMEOUT_SEC = env_int("HY3_LOAD_TIMEOUT_SEC", 600)
STOP_TIMEOUT_SEC = env_int("HY3_STOP_TIMEOUT_SEC", 300)
ENTRYPOINT = os.environ.get(
    "HY3_ENTRYPOINT",
    str(Path(__file__).resolve().parents[1] / "run_hy3_entrypoint.sh"),
)


class BackendController:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._state_event = threading.Event()
        self._state = "unloaded"
        self._proc: Optional[subprocess.Popen[bytes]] = None
        self._active_requests = 0
        self._idle_timer: Optional[threading.Timer] = None
        self._last_error: Optional[str] = None

    def _transition_locked(self, state: str, error: Optional[str] = None) -> None:
        previous = self._state_event
        self._state = state
        self._last_error = error
        self._state_event = threading.Event()
        previous.set()

    def _cancel_idle_locked(self) -> None:
        if self._idle_timer is not None:
            self._idle_timer.cancel()
            self._idle_timer = None

    def _is_alive_locked(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def backend_healthy(self) -> bool:
        try:
            connection = http.client.HTTPConnection(BACKEND_HOST, BACKEND_PORT, timeout=2)
            connection.request("GET", "/health")
            response = connection.getresponse()
            response.read()
            connection.close()
            return 200 <= response.status < 300
        except OSError:
            return False

    def _load_worker(self) -> None:
        try:
            child_env = os.environ.copy()
            child_env["HOST"] = BACKEND_HOST
            child_env["PORT"] = str(BACKEND_PORT)
            child_env["HY3_ON_DEMAND_BACKEND"] = "1"
            process = subprocess.Popen([ENTRYPOINT, "foreground"], env=child_env)
            with self._lock:
                self._proc = process

            deadline = time.monotonic() + LOAD_TIMEOUT_SEC
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"llama-server exited with status {process.returncode} while loading")
                if self.backend_healthy():
                    with self._lock:
                        if self._proc is process:
                            self._transition_locked("ready")
                    print(f"[hy3-on-demand] model ready on {BACKEND_HOST}:{BACKEND_PORT}", flush=True)
                    return
                time.sleep(0.5)
            raise RuntimeError(f"llama-server did not become healthy within {LOAD_TIMEOUT_SEC}s")
        except Exception as error:  # Keep the request-facing failure explicit and retryable.
            with self._lock:
                process = self._proc
            if process is not None and process.poll() is None:
                process.terminate()
            with self._lock:
                self._proc = None
                self._transition_locked("failed", str(error))
            print(f"[hy3-on-demand] model load failed: {error}", file=sys.stderr, flush=True)

    def ensure_ready(self) -> tuple[bool, Optional[str]]:
        deadline = time.monotonic() + LOAD_TIMEOUT_SEC
        while True:
            with self._lock:
                if self._state == "ready" and self._is_alive_locked():
                    return True, None
                if self._state == "ready":
                    self._proc = None
                    self._transition_locked("failed", "llama-server exited unexpectedly")
                if self._state in {"unloaded", "failed"}:
                    self._cancel_idle_locked()
                    self._transition_locked("loading")
                    threading.Thread(target=self._load_worker, daemon=True).start()
                    print("[hy3-on-demand] loading model for an incoming request", flush=True)
                wait_event = self._state_event

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False, f"model did not become ready within {LOAD_TIMEOUT_SEC}s"
            wait_event.wait(min(remaining, 1.0))

            with self._lock:
                if self._state == "failed":
                    return False, self._last_error or "model load failed"

    def acquire_request(self) -> tuple[bool, Optional[str]]:
        ready, error = self.ensure_ready()
        if not ready:
            return False, error
        with self._lock:
            if self._state != "ready" or not self._is_alive_locked():
                return False, "model stopped before the request could be forwarded"
            self._cancel_idle_locked()
            self._active_requests += 1
        return True, None

    def release_request(self) -> None:
        with self._lock:
            self._active_requests = max(0, self._active_requests - 1)
            if self._active_requests == 0 and self._state == "ready":
                self._cancel_idle_locked()
                self._idle_timer = threading.Timer(IDLE_TIMEOUT_SEC, self._unload_if_idle)
                self._idle_timer.daemon = True
                self._idle_timer.start()

    def _unload_if_idle(self) -> None:
        self.unload(force=False, reason="idle timeout")

    def unload(self, force: bool = False, reason: str = "operator request") -> tuple[bool, str]:
        with self._lock:
            if self._state in {"unloaded", "failed"}:
                self._cancel_idle_locked()
                self._proc = None
                self._transition_locked("unloaded")
                return True, "model is already unloaded"
            if self._state == "loading":
                return False, "model is still loading; retry unload once it is ready"
            if self._state == "stopping":
                return False, "model is already unloading"
            if self._active_requests and not force:
                return False, f"waiting for {self._active_requests} active request(s) to finish"
            process = self._proc
            self._cancel_idle_locked()
            self._transition_locked("stopping")

        if process is not None and process.poll() is None:
            print(f"[hy3-on-demand] unloading model ({reason})", flush=True)
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=STOP_TIMEOUT_SEC)
            except subprocess.TimeoutExpired:
                print("[hy3-on-demand] SIGINT timed out; terminating llama-server", file=sys.stderr, flush=True)
                process.terminate()
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=20)

        with self._lock:
            if self._proc is process:
                self._proc = None
            self._transition_locked("unloaded")
        return True, "model unloaded and GPU memory released"

    def status(self) -> dict[str, object]:
        with self._lock:
            return {
                "status": "ok" if self._state == "ready" and self._is_alive_locked() else "unavailable",
                "model_state": self._state,
                "active_requests": self._active_requests,
                "idle_timeout_seconds": IDLE_TIMEOUT_SEC,
                "backend": f"http://{BACKEND_HOST}:{BACKEND_PORT}",
                "last_error": self._last_error,
            }

    def shutdown(self) -> None:
        self.unload(force=True, reason="proxy shutdown")


CONTROLLER = BackendController()
HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "hy3-on-demand"

    def log_message(self, format: str, *args: object) -> None:
        print(f"[hy3-on-demand] {self.address_string()} {format % args}", flush=True)

    def _send_json(self, status: HTTPStatus | int, payload: dict[str, object]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> bytes:
        length = self.headers.get("Content-Length")
        if not length:
            return b""
        try:
            return self.rfile.read(int(length))
        except ValueError:
            raise ValueError("invalid Content-Length") from None

    def _handle_control(self) -> bool:
        path = urlsplit(self.path).path
        if not path.startswith("/_hy3/control/"):
            return False
        if self.command != "POST":
            self._send_json(HTTPStatus.METHOD_NOT_ALLOWED, {"error": "control endpoints require POST"})
            return True
        action = path.rsplit("/", 1)[-1]
        if action == "load":
            ready, error = CONTROLLER.ensure_ready()
            if ready:
                self._send_json(HTTPStatus.OK, CONTROLLER.status())
            else:
                self._send_json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": error or "model load failed", **CONTROLLER.status()})
        elif action == "unload":
            ok, message = CONTROLLER.unload()
            self._send_json(HTTPStatus.OK if ok else HTTPStatus.CONFLICT, {"ok": ok, "message": message, **CONTROLLER.status()})
        elif action == "kill":
            ok, message = CONTROLLER.unload(force=True, reason="operator force unload")
            self._send_json(HTTPStatus.OK if ok else HTTPStatus.CONFLICT, {"ok": ok, "message": message, **CONTROLLER.status()})
        else:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown control action"})
        return True

    def _serve_health(self) -> bool:
        if urlsplit(self.path).path != "/health":
            return False
        status = CONTROLLER.status()
        self._send_json(HTTPStatus.OK if status["status"] == "ok" else HTTPStatus.SERVICE_UNAVAILABLE, status)
        return True

    def _proxy_request(self) -> None:
        ready, error = CONTROLLER.acquire_request()
        if not ready:
            self._send_json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": error or "model unavailable", **CONTROLLER.status()})
            return
        connection: Optional[http.client.HTTPConnection] = None
        response_started = False
        try:
            body = self._read_body()
            headers = {
                key: value
                for key, value in self.headers.items()
                if key.lower() not in HOP_BY_HOP_HEADERS | {"host", "content-length"}
            }
            if body:
                headers["Content-Length"] = str(len(body))
            connection = http.client.HTTPConnection(BACKEND_HOST, BACKEND_PORT, timeout=LOAD_TIMEOUT_SEC)
            connection.request(self.command, self.path, body=body, headers=headers)
            response = connection.getresponse()

            response_started = True
            self.send_response(response.status, response.reason)
            for key, value in response.getheaders():
                if key.lower() not in HOP_BY_HOP_HEADERS | {"content-length"}:
                    self.send_header(key, value)
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                chunk = response.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
            self.close_connection = True
            connection.close()
        except (OSError, http.client.HTTPException, ValueError) as error:
            if not response_started and not self.wfile.closed:
                self._send_json(HTTPStatus.BAD_GATEWAY, {"error": f"backend request failed: {error}"})
        finally:
            if connection is not None:
                connection.close()
            CONTROLLER.release_request()

    def _handle(self) -> None:
        if self._handle_control() or self._serve_health():
            return
        self._proxy_request()

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_PATCH = _handle
    do_DELETE = _handle
    do_OPTIONS = _handle


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    if not Path(ENTRYPOINT).is_file() or not os.access(ENTRYPOINT, os.X_OK):
        raise SystemExit(f"HY3_ENTRYPOINT is not executable: {ENTRYPOINT}")
    if PUBLIC_HOST not in {"127.0.0.1", "::1", "localhost"}:
        raise SystemExit("Hy3 on-demand proxy must bind to loopback; use a separate authenticated proxy for remote access")
    if PUBLIC_PORT == BACKEND_PORT:
        raise SystemExit("HY3_BACKEND_PORT must differ from PORT")

    server = ReusableThreadingHTTPServer((PUBLIC_HOST, PUBLIC_PORT), Handler)

    def stop_proxy(_signal: int, _frame: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop_proxy)
    signal.signal(signal.SIGINT, stop_proxy)
    print(
        f"[hy3-on-demand] listening on http://{PUBLIC_HOST}:{PUBLIC_PORT}; "
        f"idle unload after {IDLE_TIMEOUT_SEC}s",
        flush=True,
    )
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        CONTROLLER.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
