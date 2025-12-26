from django.urls import path
from .views import wallet_home, wallet_topup
urlpatterns=[path("", wallet_home, name="wallet_home"), path("topup/", wallet_topup, name="wallet_topup")]
