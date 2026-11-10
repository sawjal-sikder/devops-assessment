import uvicorn

from app.config import Settings
from app.logging_config import configure_logging
from app.main import create_app


def main():
    settings = Settings.from_env()
    configure_logging(settings)
    # Uvicorn installs SIGTERM handlers, drains requests, then runs lifespan cleanup.
    uvicorn.run(create_app(settings), host=settings.host, port=settings.port,
                log_config=None, log_level=settings.log_level.lower(), access_log=False,
                timeout_graceful_shutdown=settings.shutdown_timeout)


if __name__ == "__main__":
    main()
