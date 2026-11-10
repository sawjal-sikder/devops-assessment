import json
import logging
import logging.config
from datetime import datetime, timezone


class JSONFormatter(logging.Formatter):
    def __init__(self, environment):
        super().__init__()
        self.environment = environment

    def format(self, record):
        data = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "environment": self.environment,
            "message": record.getMessage(),
        }
        for key in ("method", "path", "status_code", "duration_seconds"):
            if hasattr(record, key):
                data[key] = getattr(record, key)
        if record.exc_info:
            data["exception"] = self.formatException(record.exc_info)
        return json.dumps(data)


def configure_logging(settings):
    logging.config.dictConfig({
        "version": 1,
        "disable_existing_loggers": False,
        "formatters": {"json": {"()": JSONFormatter, "environment": settings.environment}},
        "handlers": {"stdout": {"class": "logging.StreamHandler", "stream": "ext://sys.stdout", "formatter": "json"}},
        "root": {"handlers": ["stdout"], "level": settings.log_level},
        "loggers": {
            "uvicorn": {"handlers": [], "propagate": True},
            "uvicorn.error": {"handlers": [], "propagate": True},
            "uvicorn.access": {"handlers": [], "propagate": True},
        },
    })
