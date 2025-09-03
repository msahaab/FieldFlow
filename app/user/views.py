"""
Views for user API.
"""

from rest_framework import generics, authentication, permissions
from rest_framework.authtoken.views import ObtainAuthToken
from rest_framework.exceptions import PermissionDenied
from django.contrib.auth import get_user_model
from rest_framework.settings import api_settings
from user.serializers import (
    UserSerializer,
    AuthTokenSerializer,
)


class CreateUserView(generics.CreateAPIView):
    """Create a new user in the system (admin-only)."""

    serializer_class = UserSerializer

    permission_classes = [permissions.AllowAny]
    authentication_classes = [authentication.TokenAuthentication]

    def create(self, request, *args, **kwargs):
        user = request.user
        Roles = get_user_model().Roles
        if (
            not getattr(user, "is_authenticated", False)
            or getattr(user, "role", None) != Roles.ADMIN
        ):
            raise PermissionDenied("Only admin users can create users.")
        return super().create(request, *args, **kwargs)


class CreateTokenView(ObtainAuthToken):
    """Create a new auth token for user."""

    serializer_class = AuthTokenSerializer
    renderer_classes = api_settings.DEFAULT_RENDERER_CLASSES


class ManageUserView(generics.RetrieveUpdateAPIView):
    """Manage the authicated user."""

    serializer_class = UserSerializer
    authentication_classes = [authentication.TokenAuthentication]
    permission_classes = [permissions.IsAuthenticated]

    def get_object(self):
        """Retrieve and return the authicated user."""
        return self.request.user
