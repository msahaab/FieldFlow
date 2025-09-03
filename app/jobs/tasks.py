from celery import shared_task
from django.utils import timezone
from .models import Job, JobTask


@shared_task
def update_overdue_jobs():
    """
    Flag Job.overdue = True if scheduled_date < now AND any task is not completed.
    Otherwise set False.
    """
    now = timezone.now()
    qs = Job.objects.select_related("assigned_to", "created_by").prefetch_related(
        "tasks"
    )
    for job in qs:
        if not job.scheduled_date:
            if job.overdue:
                job.overdue = False
                job.save(update_fields=["overdue"])
            continue

        any_incomplete = job.tasks.exclude(status=JobTask.Status.COMPLETED).exists()
        desired = any_incomplete and job.scheduled_date < now
        if job.overdue != desired:
            job.overdue = desired
            job.save(update_fields=["overdue"])
