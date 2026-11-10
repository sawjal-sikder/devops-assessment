import json
import logging

import pytest

from app.config import Settings
from app.logging_config import JSONFormatter


def test_environment_config(monkeypatch):
    for key, value in {
        "PORT": "9090",
        "LOG_LEVEL": "debug",
        "ENVIRONMENT": "staging",
        "APP_VERSION": "2.0.0",
        "HOST": "127.0.0.1",
        "SHUTDOWN_TIMEOUT": "8",
    }.items():
        monkeypatch.setenv(key, value)
    assert Settings.from_env() == Settings(
        port=9090,
        log_level="DEBUG",
        environment="staging",
        version="2.0.0",
        host="127.0.0.1",
        shutdown_timeout=8,
    )


@pytest.mark.parametrize(
    "key,value",
    [("PORT", "0"), ("PORT", "65536"), ("LOG_LEVEL", "invalid"), ("SHUTDOWN_TIMEOUT", "0")],
)
def test_invalid_config(monkeypatch, key, value):
    monkeypatch.setenv(key, value)
    with pytest.raises(ValueError):
        Settings.from_env()


def test_json_logs_escape_newlines():
    record = logging.LogRecord("test", logging.INFO, "", 0, "hello\n%s", ("world",), None)
    record.status_code = 200
    line = JSONFormatter("test").format(record)
    assert "\n" not in line
    data = json.loads(line)
    assert data["message"] == "hello\nworld"
    assert data["environment"] == "test"
    assert data["status_code"] == 200
