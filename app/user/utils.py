# utils.py
from rest_framework.permissions import BasePermission
from django.contrib.auth import get_user_model


class IsAdmin(BasePermission):
    message = "Only admin users can perform this action."

    def has_permission(self, request, view):
        user = getattr(request, "user", None)
        if not getattr(user, "is_authenticated", False):
            # unauthenticated -> deny with 403 (permission denied)
            return False
        return getattr(user, "role", None) == get_user_model().Roles.ADMIN
