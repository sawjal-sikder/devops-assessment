"""Environment-only runtime configuration."""

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    port: int = 8080
    log_level: str = "INFO"
    environment: str = "development"
    version: str = "1.0.0"
    host: str = "0.0.0.0"
    shutdown_timeout: int = 20

    @classmethod
    def from_env(cls):
        settings = cls(
            port=int(os.getenv("PORT", "8080")),
            log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
            environment=os.getenv("ENVIRONMENT", "development"),
            version=os.getenv("APP_VERSION", "1.0.0"),
            host=os.getenv("HOST", "0.0.0.0"),
            shutdown_timeout=int(os.getenv("SHUTDOWN_TIMEOUT", "20")),
        )
        if not 1 <= settings.port <= 65535:
            raise ValueError("PORT must be between 1 and 65535")
        if settings.log_level not in {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}:
            raise ValueError("Invalid LOG_LEVEL")
        if settings.shutdown_timeout < 1:
            raise ValueError("SHUTDOWN_TIMEOUT must be positive")
        return settings
