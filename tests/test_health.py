def test_health(client):
    assert client.get("/health").status_code == 200
    assert client.get("/health").json() == {"status": "healthy"}


def test_not_ready(client, application):
    application.state.ready = False
    response = client.get("/health")
    assert response.status_code == 503
    assert response.json() == {"status": "not_ready"}


def test_lifespan_resets_readiness(application):
    from fastapi.testclient import TestClient

    assert application.state.ready is False
    with TestClient(application):
        assert application.state.ready is True
    assert application.state.ready is False
