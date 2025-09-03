from django.contrib import admin
from .models import Job, JobTask, Equipment


@admin.register(Equipment)
class EquipmentAdmin(admin.ModelAdmin):
    list_display = ("name", "type", "serial_number", "is_active")
    search_fields = ("name", "serial_number")
    list_filter = ("is_active", "type")


class JobTaskInline(admin.TabularInline):
    model = JobTask
    extra = 0


@admin.register(Job)
class JobAdmin(admin.ModelAdmin):
    list_display = (
        "title",
        "client_name",
        "assigned_to",
        "status",
        "priority",
        "scheduled_date",
        "overdue",
    )
    list_filter = ("status", "priority", "overdue")
    search_fields = ("title", "client_name")
    inlines = [JobTaskInline]


@admin.register(JobTask)
class JobTaskAdmin(admin.ModelAdmin):
    list_display = ("job", "order", "title", "status", "completed_at")
    list_filter = ("status",)
    search_fields = ("title", "job__title")
