from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from settingsapp.admin_views import admin_account_in_admin
from courses.views import CourseListView, CourseDetailView

urlpatterns = [
  path("admin/account/", admin.site.admin_view(admin_account_in_admin), name="admin_account_in_admin"),
  path("admin/", admin.site.urls),

  path("accounts/", include("accounts.urls")),
  path("orders/", include("payments.urls")),
  path("wallet/", include("payments.wallet_urls")),
  path("invoices/", include("payments.invoice_urls")),
  path("tickets/", include("tickets.urls")),
  path("panel/", include("settingsapp.urls")),
  path("dashboard/", include("dashboard.urls")),

  path("", CourseListView.as_view(), name="home"),
  path("courses/<slug:slug>/", CourseDetailView.as_view(), name="course_detail"),
]
if settings.DEBUG:
  urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
