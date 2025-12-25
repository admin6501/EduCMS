from django.urls import path
from .views import invoice_list, invoice_detail
urlpatterns=[path("", invoice_list, name="invoice_list"), path("<uuid:order_id>/", invoice_detail, name="invoice_detail")]