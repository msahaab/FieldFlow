import pytest
from django.utils import timezone
from jobs.models import Job, JobTask, Equipment


@pytest.mark.django_db
def test_admin_can_create_job(api_client, user_factory):
    admin = user_factory(role="Admin", email="admin@example.com")
    api_client.force_authenticate(user=admin)

    resp = api_client.post(
        "/api/jobs/",
        {
            "title": "New Job",
            "description": "Desc",
            "client_name": "ClientX",
            "assigned_to": admin.id,
            "status": "Scheduled",
            "priority": "High",
            "scheduled_date": timezone.now().isoformat(),
        },
        format="json",
    )
    assert resp.status_code == 201
    assert Job.objects.count() == 1


@pytest.mark.django_db
def test_technician_cannot_create_job(api_client, user_factory):
    tech1 = user_factory(role="Technician", email="tech1@example.com")
    api_client.force_authenticate(user=tech1)

    resp = api_client.post(
        "/api/jobs/",
        {
            "title": "Tech Job",
            "client_name": "X",
        },
        format="json",
    )
    assert resp.status_code == 403


@pytest.mark.django_db
def test_technician_can_update_assigned_task_progress(api_client, user_factory):
    admin = user_factory(role="Admin", email="admin@example.com")
    tech1 = user_factory(role="Technician", email="tech1@example.com")

    job = Job.objects.create(
        title="Assigned Job",
        client_name="C",
        created_by=admin,
        assigned_to=tech1,
    )
    task = JobTask.objects.create(job=job, order=1, title="Step 1")

    api_client.force_authenticate(user=tech1)
    resp = api_client.patch(
        f"/api/job-tasks/{task.id}/", {"status": "InProgress"}, format="json"
    )
    assert resp.status_code == 200
    task.refresh_from_db()
    assert task.status == "InProgress"


@pytest.mark.django_db
def test_technician_cannot_update_unassigned_task(api_client, user_factory):
    admin = user_factory(role="Admin", email="admin@example.com")
    tech1 = user_factory(role="Technician", email="tech1@example.com")
    tech2 = user_factory(role="Technician", email="tech2@example.com")

    job = Job.objects.create(
        title="Assigned Job",
        client_name="C",
        created_by=admin,
        assigned_to=tech1,
    )
    task = JobTask.objects.create(job=job, order=1, title="Step 1")

    api_client.force_authenticate(user=tech2)
    resp = api_client.patch(
        f"/api/job-tasks/{task.id}/", {"status": "InProgress"}, format="json"
    )
    assert resp.status_code == 403


@pytest.mark.django_db
def test_job_cannot_be_completed_until_all_tasks_done(api_client, user_factory):
    admin = user_factory(role="Admin", email="admin@example.com")

    job = Job.objects.create(title="Lifecycle Job", client_name="C", created_by=admin)
    JobTask.objects.create(job=job, order=1, title="Step 1", status="Pending")

    api_client.force_authenticate(user=admin)
    resp = api_client.patch(
        f"/api/jobs/{job.id}/", {"status": "Completed"}, format="json"
    )
    assert resp.status_code == 400
    job.refresh_from_db()
    assert job.status != "Completed"


@pytest.mark.django_db
def test_technician_dashboard_lists_assigned_tasks(api_client, user_factory):
    admin = user_factory(role="Admin", email="admin@example.com")
    tech1 = user_factory(role="Technician", email="tech1@example.com")

    job = Job.objects.create(
        title="Dashboard Job",
        client_name="ClientZ",
        created_by=admin,
        assigned_to=tech1,
        scheduled_date=timezone.now() + timezone.timedelta(days=1),
    )
    created_task = JobTask.objects.create(
        job=job, order=1, title="Inspect", status="Pending"
    )

    api_client.force_authenticate(user=tech1)
    resp = api_client.get("/api/technician-dashboard/")
    assert resp.status_code == 200
    data = resp.json()

    # Avoid shadowing the outer variable; use 'item' for dict entries
    assert any(
        item["task"]["id"] == created_task.id
        for group in data
        for item in group["items"]
    )


@pytest.mark.django_db
def test_equipment_can_be_added_to_task_via_api(api_client, user_factory):
    admin = user_factory(role="Admin", email="admin@example.com")

    job = Job.objects.create(title="Equip Job", client_name="C", created_by=admin)
    task = JobTask.objects.create(job=job, order=1, title="Install AC")
    eq = Equipment.objects.create(name="Drill", type="Tool", serial_number="EQ999")

    api_client.force_authenticate(user=admin)
    resp = api_client.patch(
        f"/api/job-tasks/{task.id}/",
        {"required_equipment_ids": [eq.id]},
        format="json",
    )
    assert resp.status_code == 200
    task.refresh_from_db()
    assert eq in task.required_equipment.all()
