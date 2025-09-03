import pytest
from django.utils import timezone
from jobs.models import Job, JobTask, Equipment


@pytest.mark.django_db
def test_job_overdue_flag_updates_when_tasks_incomplete(user_factory):
    admin = user_factory(role="Admin", email="admin@example.com")
    job = Job.objects.create(
        title="Test Job",
        description="desc",
        client_name="Client A",
        created_by=admin,
        assigned_to=admin,
        scheduled_date=timezone.now() - timezone.timedelta(days=1),
    )
    JobTask.objects.create(job=job, order=1, title="Task 1")
    job.recalc_overdue()
    assert job.overdue is True


@pytest.mark.django_db
def test_job_not_overdue_when_no_scheduled_date(user_factory):
    admin = user_factory(role="Admin", email="admin@example.com")
    job = Job.objects.create(
        title="No schedule",
        client_name="Client B",
        created_by=admin,
        assigned_to=admin,
    )
    JobTask.objects.create(job=job, order=1, title="Task 1")
    job.recalc_overdue()
    assert job.overdue is False


@pytest.mark.django_db
def test_jobtask_unique_order_constraint(user_factory):
    admin = user_factory(role="Admin", email="admin@example.com")
    job = Job.objects.create(
        title="Job with duplicate order", client_name="C", created_by=admin
    )
    JobTask.objects.create(job=job, order=1, title="Step 1")
    with pytest.raises(Exception):
        JobTask.objects.create(job=job, order=1, title="Step 2")


@pytest.mark.django_db
def test_equipment_can_be_assigned_to_tasks(user_factory):
    admin = user_factory(role="Admin", email="admin@example.com")
    job = Job.objects.create(title="Equipment Job", client_name="C", created_by=admin)
    task = JobTask.objects.create(job=job, order=1, title="Install AC")
    eq = Equipment.objects.create(name="Hammer", type="Tool", serial_number="SN123")
    task.required_equipment.add(eq)
    assert eq in task.required_equipment.all()
    assert task in eq.task_usages.all()
