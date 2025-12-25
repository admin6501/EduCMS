from django.urls import path
from .views import checkout, upload_receipt, my_orders, cancel_order
urlpatterns=[
  path("checkout/<slug:slug>/", checkout, name="checkout"),
  path("receipt/<uuid:order_id>/", upload_receipt, name="upload_receipt"),
  path("my/", my_orders, name="orders_my"),
  path("cancel/<uuid:order_id>/", cancel_order, name="order_cancel"),
]