# Create your views here.

from collections import defaultdict
from django.utils import timezone
from rest_framework import viewsets, permissions, status
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import Job, JobTask, Equipment
from .serializers import JobSerializer, JobTaskSerializer, EquipmentSerializer
from .permissions import IsAdminOrSalesAgent, IsAssignedTechnicianForTaskUpdate

from django.db.models import (
    Avg,
    Count,
)


class EquipmentViewSet(viewsets.ModelViewSet):
    queryset = Equipment.objects.all().order_by("name")
    serializer_class = EquipmentSerializer

    def get_permissions(self):
        if self.action in ["create", "update", "partial_update", "destroy"]:
            return [IsAdminOrSalesAgent()]
        return [permissions.IsAuthenticated()]


class JobViewSet(viewsets.ModelViewSet):
    queryset = (
        Job.objects.all()
        .select_related("created_by", "assigned_to")
        .prefetch_related("tasks")
    )
    serializer_class = JobSerializer

    def get_permissions(self):
        if self.action in ["create", "update", "partial_update", "destroy"]:
            return [IsAdminOrSalesAgent()]
        return [permissions.IsAuthenticated()]

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)

    @action(detail=False, methods=["get"], permission_classes=[IsAdminOrSalesAgent])
    def analytics(self, request):
        completed = JobTask.objects.exclude(completed_at__isnull=True)
        avg_completed_per_job = (
            completed.values("job")
            .annotate(total=Count("id"))
            .aggregate(avg_tasks_per_job=Avg("total"))
        )

        most_used_equipment = (
            Equipment.objects.annotate(uses=Count("task_usages"))
            .order_by("-uses")[:10]
            .values("id", "name", "serial_number", "uses")
        )

        return Response(
            {
                "avg_completed_tasks_per_job": avg_completed_per_job[
                    "avg_tasks_per_job"
                ],
                "top_equipment_by_usage": list(most_used_equipment),
            }
        )


class JobTaskViewSet(viewsets.ModelViewSet):
    queryset = (
        JobTask.objects.all()
        .select_related("job")
        .prefetch_related("required_equipment")
    )
    serializer_class = JobTaskSerializer

    def get_queryset(self):
        qs = super().get_queryset()
        job_id = self.request.query_params.get("job")
        if job_id:
            qs = qs.filter(job_id=job_id)
        return qs

    def get_permissions(self):
        if self.action in ["create"]:
            return [IsAdminOrSalesAgent()]
        if self.action in ["update", "partial_update"]:
            return [IsAssignedTechnicianForTaskUpdate()]
        if self.action in ["destroy"]:
            return [IsAdminOrSalesAgent()]
        return [permissions.IsAuthenticated()]

    def update(self, request, *args, **kwargs):
        """
        If a Technician is updating, restrict to progress fields only
        (status, completed_at, required_equipment_ids).
        """
        user = request.user
        data = request.data.copy()
        if getattr(user, "role", None) == "Technician":
            allowed = {"status", "completed_at", "required_equipment_ids"}
            for key in list(data.keys()):
                if key not in allowed:
                    data.pop(key, None)
        serializer = self.get_serializer(self.get_object(), data=data, partial=True)
        serializer.is_valid(raise_exception=True)
        self.perform_update(serializer)
        return Response(serializer.data)


class TechnicianDashboard(APIView):
    """
    GET /api/technician-dashboard/
    Returns upcoming & in-progress tasks for the authenticated Technician,
    grouped by day (based on Job.scheduled_date).
    """

    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        user = request.user
        tech_id = request.query_params.get("technician_id")
        if getattr(user, "role", None) == "Technician" or not tech_id:
            tech_id = user.id

        tasks = (
            JobTask.objects.select_related("job")
            .prefetch_related("required_equipment")
            .filter(
                job__assigned_to_id=tech_id,
                status__in=[JobTask.Status.PENDING, JobTask.Status.IN_PROGRESS],
            )
        )

        grouped = defaultdict(list)
        for task in tasks:
            day = (
                task.job.scheduled_date.date()
                if task.job.scheduled_date
                else timezone.now().date()
            )
            grouped[day].append(task)

        out = []
        for day, day_tasks in sorted(grouped.items()):
            day_items = []
            for t in day_tasks:
                day_items.append(
                    {
                        "job_title": t.job.title,
                        "task": JobTaskSerializer(t).data,
                        "equipment": EquipmentSerializer(
                            t.required_equipment.all(), many=True
                        ).data,
                    }
                )
            out.append({"date": day, "items": day_items})

        return Response(out, status=status.HTTP_200_OK)
