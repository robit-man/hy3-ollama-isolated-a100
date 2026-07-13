#!/usr/bin/env python3
"""Integration test for the stdlib Hy3 on-demand proxy.

It runs a tiny fake llama-server, never opens a GPU, and verifies that health
checks do not load the model, inference does, idle time unloads with SIGINT,
and the next inference request loads again.
"""

from __future__ import annotations

import http.client
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def send_json(handler: BaseHTTPRequestHandler, status: int, payload: dict[str, object]) -> None:
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def fake_backend() -> None:
    log_path = Path(os.environ["HY3_TEST_BACKEND_LOG"])
    with log_path.open("a", encoding="utf-8") as log:
        log.write("start\n")
        log.flush()

    class FakeHandler(BaseHTTPRequestHandler):
        def log_message(self, *_args: object) -> None:
            return

        def do_GET(self) -> None:
            if self.path == "/health":
                send_json(self, 200, {"status": "ok"})
            elif self.path == "/v1/models":
                send_json(self, 200, {"data": [{"id": "fake-hy3"}]})
            else:
                send_json(self, 404, {"error": "not found"})

    server = ThreadingHTTPServer(("127.0.0.1", int(os.environ["PORT"])), FakeHandler)

    def stop(_signal: int, _frame: object) -> None:
        with log_path.open("a", encoding="utf-8") as log:
            log.write("sigint\n")
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    server.serve_forever(poll_interval=0.05)
    server.server_close()


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as candidate:
        candidate.bind(("127.0.0.1", 0))
        return int(candidate.getsockname()[1])


def request(port: int, method: str, path: str) -> tuple[int, dict[str, object]]:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request(method, path)
    response = connection.getresponse()
    body = response.read()
    connection.close()
    return response.status, json.loads(body.decode("utf-8"))


def health_is_unloaded(port: int) -> bool:
    try:
        return request(port, "GET", "/health")[0] == 503
    except OSError:
        return False


def wait_for(predicate: object, timeout: float, message: str) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if callable(predicate) and predicate():
            return
        time.sleep(0.05)
    raise AssertionError(message)


def main_test() -> None:
    repo_dir = Path(__file__).resolve().parents[1]
    proxy = repo_dir / "scripts" / "hy3_on_demand_proxy.py"
    public_port = free_port()
    backend_port = free_port()
    with tempfile.TemporaryDirectory(prefix="hy3-on-demand-test-") as temp_dir:
        backend_log = Path(temp_dir) / "backend.log"
        environment = os.environ.copy()
        environment.update({
            "HOST": "127.0.0.1",
            "PORT": str(public_port),
            "HY3_BACKEND_PORT": str(backend_port),
            "HY3_IDLE_TIMEOUT_SEC": "1",
            "HY3_LOAD_TIMEOUT_SEC": "5",
            "HY3_STOP_TIMEOUT_SEC": "3",
            "HY3_ENTRYPOINT": str(Path(__file__).resolve()),
            "HY3_TEST_BACKEND_LOG": str(backend_log),
        })
        proxy_process = subprocess.Popen(
            [sys.executable, str(proxy)],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            wait_for(
                lambda: health_is_unloaded(public_port),
                5,
                "proxy did not start in unloaded state",
            )
            assert not backend_log.exists(), "a health check must not load the model"

            status, payload = request(public_port, "GET", "/v1/models")
            assert status == 200 and payload["data"][0]["id"] == "fake-hy3"
            assert backend_log.read_text(encoding="utf-8").splitlines().count("start") == 1

            wait_for(
                lambda: health_is_unloaded(public_port),
                5,
                "model did not unload after the idle timeout",
            )
            assert "sigint" in backend_log.read_text(encoding="utf-8").splitlines()

            status, payload = request(public_port, "GET", "/v1/models")
            assert status == 200 and payload["data"][0]["id"] == "fake-hy3"
            assert backend_log.read_text(encoding="utf-8").splitlines().count("start") == 2
        finally:
            proxy_process.send_signal(signal.SIGTERM)
            try:
                proxy_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proxy_process.kill()
                proxy_process.wait(timeout=5)
            if proxy_process.returncode not in {0, -signal.SIGTERM}:
                stdout, stderr = proxy_process.communicate()
                raise AssertionError(f"proxy exited {proxy_process.returncode}\nstdout:\n{stdout}\nstderr:\n{stderr}")

    print("Hy3 on-demand proxy tests passed.")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "foreground":
        fake_backend()
    else:
        main_test()
