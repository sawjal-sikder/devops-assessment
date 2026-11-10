import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Response
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, generate_latest

from app.config import Settings
from app.metrics import MetricsMiddleware


def create_app(settings=None):
    settings = settings or Settings.from_env()
    registry = CollectorRegistry()

    @asynccontextmanager
    async def lifespan(app):
        app.state.ready = True
        logging.getLogger(__name__).info("application_started")
        try:
            yield
        finally:
            app.state.ready = False
            logging.getLogger(__name__).info("application_stopped")

    app = FastAPI(title="DevOps Task", version=settings.version, lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)
    app.state.ready = False
    app.state.registry = registry
    app.state.settings = settings
    app.add_middleware(MetricsMiddleware, registry=registry)

    @app.get("/")
    async def root():
        return {"message": "Hello from DevOps Task!", "status": "running", "version": settings.version}

    @app.get("/health")
    async def health(response: Response):
        response.status_code = 200 if app.state.ready else 503
        return {"status": "healthy" if app.state.ready else "not_ready"}

    @app.get("/metrics")
    async def metrics():
        return Response(generate_latest(registry), headers={"Content-Type": CONTENT_TYPE_LATEST})

    return app


app = create_app()
