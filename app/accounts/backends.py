from django.contrib.auth.backends import ModelBackend
from django.contrib.auth import get_user_model
from django.db.models import Q

class EmailOrUsernameBackend(ModelBackend):
  """Authenticate with either username OR email in the same login field."""
  def authenticate(self, request, username=None, password=None, **kwargs):
    UserModel = get_user_model()
    identifier = (username or kwargs.get("email") or "").strip()
    if not identifier or not password:
      return None
    try:
      user = UserModel.objects.get(Q(username__iexact=identifier) | Q(email__iexact=identifier))
    except UserModel.DoesNotExist:
      UserModel().set_password(password)
      return None
    if user.check_password(password) and self.user_can_authenticate(user):
      return user
    return None
