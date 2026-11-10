import logging
from time import perf_counter

from prometheus_client import CollectorRegistry, Counter, Histogram

logger = logging.getLogger(__name__)


class MetricsMiddleware:
    """Measure complete ASGI responses, with bounded route labels."""

    def __init__(self, app, registry):
        self.app = app
        self.requests = Counter("http_requests_total", "Completed HTTP requests", ["method", "path", "status"], registry=registry)
        self.errors = Counter("http_errors_total", "HTTP responses with status >= 400", ["method", "path", "status"], registry=registry)
        self.latency = Histogram("http_request_duration_seconds", "HTTP request duration in seconds", ["method", "path"], registry=registry)

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        started = perf_counter()
        status = 500

        async def measured_send(message):
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, measured_send)
        except Exception:
            logger.exception("request_failed")
            raise
        finally:
            route = scope.get("route")
            path = getattr(route, "path", "unmatched")
            method = scope["method"]
            if method not in {"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "TRACE", "CONNECT"}:
                method = "OTHER"
            duration = perf_counter() - started
            self.requests.labels(method, path, str(status)).inc()
            if status >= 400:
                self.errors.labels(method, path, str(status)).inc()
            self.latency.labels(method, path).observe(duration)
            logger.info("request_completed", extra={"method": method, "path": path, "status_code": status, "duration_seconds": duration})
