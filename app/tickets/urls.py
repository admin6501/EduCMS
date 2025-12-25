from django.urls import path
from .views import ticket_list, ticket_create, ticket_detail
urlpatterns=[path("",ticket_list,name="ticket_list"), path("new/",ticket_create,name="ticket_create"), path("<uuid:ticket_id>/",ticket_detail,name="ticket_detail")]