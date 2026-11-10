"""Exercise the real server entrypoint and SIGTERM lifecycle."""

import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.request


def test_sigterm_shutdown():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    env = {
        **os.environ,
        "HOST": "127.0.0.1",
        "PORT": str(port),
        "ENVIRONMENT": "shutdown-test",
        "LOG_LEVEL": "INFO",
    }
    process = subprocess.Popen(
        [sys.executable, "-m", "app"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        deadline = time.monotonic() + 10
        while True:
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/health", timeout=0.2
                ) as response:
                    assert response.status == 200
                break
            except OSError:
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise AssertionError("Server did not become ready")
                time.sleep(0.05)
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
        # Some Uvicorn releases re-raise SIGTERM after completing shutdown.
        assert process.returncode in (0, -signal.SIGTERM)
        assert stderr == ""
        records = [json.loads(line) for line in stdout.splitlines()]
        assert all(record["environment"] == "shutdown-test" for record in records)
        assert any(record["message"] == "application_stopped" for record in records)
        assert any(record["message"] == "request_completed" for record in records)
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
