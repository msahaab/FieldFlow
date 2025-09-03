import pytest
from rest_framework.test import APIClient
from django.contrib.auth import get_user_model

User = get_user_model()


@pytest.fixture
def api_client():
    """Fixture for DRF APIClient."""
    return APIClient()


@pytest.fixture
def user_factory(db):
    """Factory fixture to create users with different roles."""

    def create_user(**kwargs):
        count = User.objects.count() + 1
        defaults = {
            "email": f"user{count}@example.com",
            "password": "password123",
            "name": f"User {count}",
            "role": "SalesAgent",  # default role
        }
        defaults.update(kwargs)
        user = User.objects.create_user(
            email=defaults["email"],
            password=defaults["password"],
            name=defaults["name"],
            role=defaults["role"],
        )
        return user

    return create_user
