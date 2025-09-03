from django.utils import timezone
from rest_framework import serializers
from django.contrib.auth import get_user_model
from .models import Job, JobTask, Equipment

User = get_user_model()


class EquipmentSerializer(serializers.ModelSerializer):
    class Meta:
        model = Equipment
        fields = ["id", "name", "type", "serial_number", "is_active"]
        read_only_fields = ["id"]


class JobTaskSerializer(serializers.ModelSerializer):
    # Read: full equipment details
    required_equipment = EquipmentSerializer(many=True, read_only=True)
    # Write: ids to set equipment
    required_equipment_ids = serializers.PrimaryKeyRelatedField(
        many=True, write_only=True, queryset=Equipment.objects.all(), required=False
    )

    class Meta:
        model = JobTask
        fields = [
            "id",
            "job",
            "order",
            "title",
            "description",
            "status",
            "required_equipment",
            "required_equipment_ids",
            "completed_at",
        ]
        read_only_fields = ["id"]

    def validate(self, attrs):
        # If marking complete, set completed_at if not provided
        status = attrs.get("status")
        if status == JobTask.Status.COMPLETED and not attrs.get("completed_at"):
            attrs["completed_at"] = timezone.now()
        return attrs

    def create(self, validated_data):
        equipment_ids = validated_data.pop("required_equipment_ids", [])
        task = super().create(validated_data)
        if equipment_ids:
            task.required_equipment.set(equipment_ids)
        return task

    def update(self, instance, validated_data):
        equipment_ids = validated_data.pop("required_equipment_ids", None)
        task = super().update(instance, validated_data)
        if equipment_ids is not None:
            task.required_equipment.set(equipment_ids)
        return task


class JobSerializer(serializers.ModelSerializer):
    created_by = serializers.PrimaryKeyRelatedField(read_only=True)
    # show assigned user id; could expose name/email if desired
    assigned_to = serializers.PrimaryKeyRelatedField(
        queryset=User.objects.all(), allow_null=True, required=False
    )
    # Nested tasks (read-only). Write through JobTask endpoints.
    tasks = JobTaskSerializer(many=True, read_only=True)

    class Meta:
        model = Job
        fields = [
            "id",
            "title",
            "description",
            "client_name",
            "created_by",
            "assigned_to",
            "status",
            "priority",
            "scheduled_date",
            "overdue",
            "tasks",
        ]
        read_only_fields = ["id", "created_by", "overdue"]

    def validate(self, attrs):
        # Enforce: cannot move Job to Completed unless all tasks are completed
        new_status = attrs.get("status")
        job = self.instance
        if job and new_status == Job.Status.COMPLETED:
            has_incomplete = job.tasks.exclude(status=JobTask.Status.COMPLETED).exists()
            if has_incomplete:
                raise serializers.ValidationError(
                    "Cannot mark job as Completed until all tasks are completed."
                )
        return attrs

    def create(self, validated_data):
        validated_data["created_by"] = self.context["request"].user
        return super().create(validated_data)

    def update(self, instance, validated_data):
        job = super().update(instance, validated_data)
        job.recalc_overdue()
        job.save(update_fields=["overdue", "updated_at"])
        return job
