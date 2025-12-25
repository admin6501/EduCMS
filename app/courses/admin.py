from django.contrib import admin
from .models import Course, Enrollment, CourseGrant

@admin.register(Course)
class CourseAdmin(admin.ModelAdmin):
    list_display = ("title", "owner", "price_toman", "status", "is_free_for_all", "updated_at")
    list_filter = ("status", "is_free_for_all")
    search_fields = ("title", "slug", "owner__username")
    prepopulated_fields = {"slug": ("title",)}

@admin.register(Enrollment)
class EnrollmentAdmin(admin.ModelAdmin):
    list_display = ("user", "course", "is_active", "source", "created_at")
    list_filter = ("is_active", "source", "created_at")
    search_fields = ("user__username", "user__email", "course__title")
    raw_id_fields = ("user", "course")

@admin.register(CourseGrant)
class CourseGrantAdmin(admin.ModelAdmin):
    list_display = ("user", "course", "is_active", "reason")
    list_filter = ("is_active",)
    search_fields = ("user__username", "user__email", "course__title", "reason")
    raw_id_fields = ("user", "course")