def test_root(client):
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {
        "message": "Hello from DevOps Task!",
        "status": "running",
        "version": "test-version",
    }


def test_unknown_route(client):
    assert client.get("/unknown").status_code == 404


def test_unsupported_method(client):
    assert client.post("/").status_code == 405
