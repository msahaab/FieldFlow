from rest_framework.permissions import BasePermission, SAFE_METHODS


class IsAuthenticatedAndReadOnly(BasePermission):
    def has_permission(self, request, view):
        return (
            request.user
            and request.user.is_authenticated
            and request.method in SAFE_METHODS
        )


class IsAdminOrSalesAgent(BasePermission):
    def has_permission(self, request, view):
        u = request.user
        return bool(
            u
            and u.is_authenticated
            and getattr(u, "role", None) in ("Admin", "SalesAgent")
        )


class IsAssignedTechnicianForTaskUpdate(BasePermission):
    """
    Only the assigned Technician of the parent Job can update a task (progress).
    Admins/SalesAgents can also update tasks.
    """

    def has_object_permission(self, request, view, obj):
        u = request.user
        if not u or not u.is_authenticated:
            return False
        if getattr(u, "role", None) in ("Admin", "SalesAgent"):
            return True
        # technician may update only if assigned to this job
        return (
            getattr(u, "role", None) == "Technician" and obj.job.assigned_to_id == u.id
        )
