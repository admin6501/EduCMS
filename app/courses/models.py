import uuid
from django.db import models
from django.conf import settings
from django.utils.text import slugify
from django.utils.translation import gettext_lazy as _

class PublishStatus(models.TextChoices):
  DRAFT="draft",_("پیش‌نویس")
  PUBLISHED="published",_("منتشر شده")
  ARCHIVED="archived",_("آرشیو")

class Course(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  owner=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, verbose_name=_("مالک"))
  title=models.CharField(max_length=200, verbose_name=_("عنوان"))
  slug=models.SlugField(max_length=220, unique=True, blank=True)
  cover=models.ImageField(upload_to="courses/covers/", blank=True, null=True)
  summary=models.TextField(blank=True)
  description=models.TextField(blank=True)
  price_toman=models.PositiveIntegerField(default=0)
  is_free_for_all=models.BooleanField(default=False)
  status=models.CharField(max_length=20, choices=PublishStatus.choices, default=PublishStatus.DRAFT)
  updated_at=models.DateTimeField(auto_now=True)
  def save(self,*a,**k):
    if not self.slug: self.slug=slugify(self.title, allow_unicode=True)
    return super().save(*a,**k)
  def __str__(self): return self.title
  class Meta:
    verbose_name=_("دوره"); verbose_name_plural=_("دوره‌ها")

class Enrollment(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, verbose_name=_("کاربر"))
  course=models.ForeignKey(Course, on_delete=models.CASCADE, verbose_name=_("دوره"))
  is_active=models.BooleanField(default=True, verbose_name=_("فعال"))
  source=models.CharField(max_length=30, default="paid", verbose_name=_("منبع"))
  created_at=models.DateTimeField(auto_now_add=True, verbose_name=_("تاریخ ثبت"))
  class Meta:
    unique_together=[("user","course")]
    verbose_name=_("ثبت‌نام دوره")
    verbose_name_plural=_("ثبت‌نام‌های دوره")

class CourseGrant(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, verbose_name=_("کاربر"))
  course=models.ForeignKey(Course, on_delete=models.CASCADE, verbose_name=_("دوره"))
  is_active=models.BooleanField(default=True, verbose_name=_("فعال"))
  reason=models.CharField(max_length=200, blank=True, verbose_name=_("دلیل"))
  class Meta:
    unique_together=[("user","course")]
    verbose_name=_("دسترسی اهدایی")
    verbose_name_plural=_("دسترسی‌های اهدایی")
