# Create your models here.
from django.conf import settings
from django.db import models
from django.utils import timezone


class Equipment(models.Model):
    name = models.CharField(max_length=120)
    type = models.CharField(max_length=120)
    serial_number = models.CharField(max_length=120, unique=True)
    is_active = models.BooleanField(default=True)

    def __str__(self):
        return f"{self.name} ({self.serial_number})"


class Job(models.Model):
    class Status(models.TextChoices):
        DRAFT = "Draft", "Draft"
        SCHEDULED = "Scheduled", "Scheduled"
        IN_PROGRESS = "InProgress", "In Progress"
        ON_HOLD = "OnHold", "On Hold"
        COMPLETED = "Completed", "Completed"
        CANCELLED = "Cancelled", "Cancelled"

    class Priority(models.TextChoices):
        LOW = "Low", "Low"
        MEDIUM = "Medium", "Medium"
        HIGH = "High", "High"
        URGENT = "Urgent", "Urgent"

    title = models.CharField(max_length=200)
    description = models.TextField(blank=True)
    client_name = models.CharField(max_length=200)

    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, related_name="jobs_created", on_delete=models.CASCADE
    )
    assigned_to = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="jobs_assigned",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
    )

    status = models.CharField(
        max_length=20, choices=Status.choices, default=Status.DRAFT
    )
    priority = models.CharField(
        max_length=10, choices=Priority.choices, default=Priority.MEDIUM
    )
    scheduled_date = models.DateTimeField(null=True, blank=True)

    overdue = models.BooleanField(default=False)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def recalc_overdue(self):
        """Overdue if scheduled_date passed and any task not completed."""
        if not self.scheduled_date:
            self.overdue = False
            return
        any_incomplete = self.tasks.exclude(status=JobTask.Status.COMPLETED).exists()
        self.overdue = any_incomplete and timezone.now() > self.scheduled_date

    def __str__(self):
        return self.title


class JobTask(models.Model):
    class Status(models.TextChoices):
        PENDING = "Pending", "Pending"
        IN_PROGRESS = "InProgress", "In Progress"
        COMPLETED = "Completed", "Completed"

    job = models.ForeignKey(Job, related_name="tasks", on_delete=models.CASCADE)
    order = models.PositiveIntegerField(default=1)

    title = models.CharField(max_length=200)
    description = models.TextField(blank=True)
    status = models.CharField(
        max_length=20, choices=Status.choices, default=Status.PENDING
    )

    required_equipment = models.ManyToManyField(
        Equipment, related_name="task_usages", blank=True
    )

    completed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["job_id", "order", "id"]
        unique_together = [("job", "order")]

    def __str__(self):
        return f"{self.job.title} - {self.title} (#{self.order})"
