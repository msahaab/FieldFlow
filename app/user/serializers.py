"""
Serializers for the user API view.
"""

from django.contrib.auth import (
    get_user_model,
    authenticate,
)
from rest_framework import serializers


class UserSerializer(serializers.ModelSerializer):
    """Serializer for the user object."""

    class Meta:
        model = get_user_model()
        fields = ["email", "password", "name", "role"]
        extra_kwargs = {
            "password": {"write_only": True, "min_length": 5},
        }

    def create(self, validated_data):
        """Create and return a user with encrypted password."""
        request = self.context.get("request")
        user = request.user if request else None

        # Only Admins can set role; otherwise force default SalesAgent
        if not user or user.role != get_user_model().Roles.ADMIN:
            validated_data["role"] = get_user_model().Roles.SALES_AGENT

        return get_user_model().objects.create_user(**validated_data)

    def update(self, instance, validated_data):
        """Update and return user"""
        password = validated_data.pop("password", None)
        request = self.context.get("request")
        user = request.user if request else None

        # Only Admins can change roles
        if "role" in validated_data and (
            not user or user.role != get_user_model().Roles.ADMIN
        ):
            validated_data.pop("role")

        user_obj = super().update(instance, validated_data)

        if password:
            user_obj.set_password(password)
            user_obj.save()

        return user_obj


class AuthTokenSerializer(serializers.Serializer):
    """Serializer for the user auth token."""

    email = serializers.EmailField()
    password = serializers.CharField(
        style={"input_type": "password"},
        trim_whitespace=False,
    )

    def validate(self, attrs):
        """Validate and authenicate the user."""
        email = attrs.get("email")
        password = attrs.get("password")
        user = authenticate(
            request=self.context.get("request"),
            username=email,
            password=password,
        )
        if not user:
            msg = "Unable to authenticate with provided credentials."
            raise serializers.ValidationError(msg, code="authorization")

        attrs["user"] = user
        return attrs
