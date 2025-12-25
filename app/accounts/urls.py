from django.urls import path
from .views import SiteLoginView, SiteLogoutView, RegisterView, profile_edit, security_questions, reset_step1, reset_step2
urlpatterns=[
  path("login/", SiteLoginView.as_view(), name="login"),
  path("logout/", SiteLogoutView.as_view(), name="logout"),
  path("register/", RegisterView.as_view(), name="register"),
  path("profile/", profile_edit, name="profile_edit"),
  path("security/", security_questions, name="security_questions"),
  path("reset/", reset_step1, name="reset_step1"),
  path("reset/verify/", reset_step2, name="reset_step2"),
]