from django.urls import path
from .views import admin_path_settings
urlpatterns=[path("admin-path/", admin_path_settings, name="admin_path_settings")]
