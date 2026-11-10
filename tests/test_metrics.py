from fastapi.testclient import TestClient
from prometheus_client import CONTENT_TYPE_LATEST
from prometheus_client.parser import text_string_to_metric_families


def sample(text, name, labels):
    return next(s.value for family in text_string_to_metric_families(text)
                for s in family.samples if s.name == name and s.labels == labels)


def test_metrics_counts_errors_and_latency(client):
    client.get("/")
    client.get("/missing-1")
    client.get("/missing-2")
    response = client.get("/metrics")
    assert response.status_code == 200
    assert response.headers["content-type"] == CONTENT_TYPE_LATEST
    text = response.text
    assert sample(text, "http_requests_total", {"method": "GET", "path": "/", "status": "200"}) == 1
    assert sample(text, "http_errors_total", {"method": "GET", "path": "unmatched", "status": "404"}) == 2
    assert sample(text, "http_request_duration_seconds_count", {"method": "GET", "path": "/"}) == 1
    assert sample(text, "http_request_duration_seconds_bucket", {"method": "GET", "path": "/", "le": "+Inf"}) == 1
    assert sample(text, "http_request_duration_seconds_sum", {"method": "GET", "path": "/"}) >= 0
    assert "missing-1" not in text


def test_unhandled_error_counted(application):
    @application.get("/fail")
    async def fail():
        raise RuntimeError("test failure")

    with TestClient(application, raise_server_exceptions=False) as client:
        assert client.get("/fail").status_code == 500
        text = client.get("/metrics").text
        assert sample(text, "http_errors_total", {"method": "GET", "path": "/fail", "status": "500"}) == 1


def test_registries_are_isolated(client):
    from app.main import create_app
    with TestClient(create_app()) as other:
        other.get("/")
    text = client.get("/metrics").text
    assert 'path="/",status="200"' not in text
