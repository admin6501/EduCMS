import uuid
from django.db import models
from django.utils.translation import gettext_lazy as _
from django.utils.text import slugify
from django.contrib.auth.models import AbstractUser
from django.contrib.auth.hashers import make_password, check_password

class User(AbstractUser):
  id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False, verbose_name=_("شناسه"))
  email = models.EmailField(_("ایمیل"), unique=True)
  username = models.CharField(_("نام کاربری"), max_length=150, unique=True, blank=True)

  def save(self, *args, **kwargs):
    if not (self.username or "").strip():
      local = (self.email or "user").split("@")[0].strip() or "user"
      base = slugify(local, allow_unicode=False) or "user"
      candidate = base
      i = 0
      while User.objects.filter(username__iexact=candidate).exclude(pk=self.pk).exists():
        i += 1
        candidate = f"{base}{i}"
        if i > 9999:
          candidate = f"{base}{uuid.uuid4().hex[:6]}"
          break
      self.username = candidate
    return super().save(*args, **kwargs)

  class Meta:
    verbose_name = _("کاربر")
    verbose_name_plural = _("کاربران")
class SecurityQuestion(models.Model):
  id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  text = models.CharField(max_length=250, unique=True, verbose_name=_("متن سوال"))
  is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
  order = models.PositiveIntegerField(default=0, verbose_name=_("ترتیب"))
  class Meta:
    ordering=["order","text"]; verbose_name=_("سوال امنیتی"); verbose_name_plural=_("سوالات امنیتی")
  def __str__(self): return self.text

class UserProfile(models.Model):
  id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user = models.OneToOneField("accounts.User", on_delete=models.CASCADE, related_name="profile", verbose_name=_("کاربر"))
  phone = models.CharField(max_length=30, blank=True, verbose_name=_("شماره تماس"))
  bio = models.TextField(blank=True, verbose_name=_("بیو"))
  q1 = models.ForeignKey(SecurityQuestion, on_delete=models.SET_NULL, null=True, blank=True, related_name="p_q1", verbose_name=_("سوال ۱"))
  q2 = models.ForeignKey(SecurityQuestion, on_delete=models.SET_NULL, null=True, blank=True, related_name="p_q2", verbose_name=_("سوال ۲"))
  a1_hash = models.CharField(max_length=200, blank=True, verbose_name=_("هش پاسخ ۱"))
  a2_hash = models.CharField(max_length=200, blank=True, verbose_name=_("هش پاسخ ۲"))
  extra_data = models.JSONField(default=dict, blank=True, verbose_name=_("داده‌های اضافی"))
  updated_at = models.DateTimeField(auto_now=True)

  class Meta:
    verbose_name=_("پروفایل"); verbose_name_plural=_("پروفایل‌ها")

  @staticmethod
  def _norm(s): return (s or "").strip().lower()
  def set_answers(self,a1,a2):
    a1n=self._norm(a1); a2n=self._norm(a2)
    self.a1_hash = make_password(a1n) if a1n else ""
    self.a2_hash = make_password(a2n) if a2n else ""
  def check_answers(self,a1,a2):
    if not (self.a1_hash and self.a2_hash): return False
    return check_password(self._norm(a1), self.a1_hash) and check_password(self._norm(a2), self.a2_hash)