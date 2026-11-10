import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


@pytest.fixture
def application():
    return create_app(Settings(version="test-version"))


@pytest.fixture
def client(application):
    with TestClient(application) as client:
        yield client
