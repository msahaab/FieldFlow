from django.urls import path, include
from rest_framework.routers import DefaultRouter
from .views import JobViewSet, JobTaskViewSet, EquipmentViewSet, TechnicianDashboard

router = DefaultRouter()
router.register("jobs", JobViewSet, basename="job")
router.register("job-tasks", JobTaskViewSet, basename="jobtask")
router.register("equipment", EquipmentViewSet, basename="equipment")

urlpatterns = [
    path("", include(router.urls)),
    path(
        "technician-dashboard/",
        TechnicianDashboard.as_view(),
        name="technician-dashboard",
    ),
]
