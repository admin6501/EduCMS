from django.db import models
from django.utils.translation import gettext_lazy as _

class SiteSetting(models.Model):
  brand_name = models.CharField(max_length=120, default="EduCMS", verbose_name=_("نام برند"))
  logo = models.ImageField(upload_to="branding/", blank=True, null=True, verbose_name=_("لوگو"))
  favicon = models.ImageField(upload_to="branding/", blank=True, null=True, verbose_name=_("فاویکن"))
  THEME_MODE = (("light",_("روشن")),("dark",_("تاریک")),("system",_("سیستم")))
  default_theme = models.CharField(max_length=10, choices=THEME_MODE, default="system", verbose_name=_("تم پیش‌فرض"))
  footer_text = models.TextField(blank=True, verbose_name=_("متن فوتر"))
  admin_path = models.SlugField(max_length=50, default="admin", verbose_name=_("مسیر ادمین"))
  allow_profile_edit = models.BooleanField(default=True, verbose_name=_("اجازه ویرایش پروفایل توسط کاربران"))
  allow_security_edit = models.BooleanField(default=True, verbose_name=_("اجازه تغییر سوالات امنیتی توسط کاربران"))
  updated_at = models.DateTimeField(auto_now=True)
  class Meta:
    verbose_name=_("تنظیمات سایت"); verbose_name_plural=_("تنظیمات سایت")
  def __str__(self): return "Site Settings"

class RegistrationFieldType(models.TextChoices):
  TEXT = "text", _("متن کوتاه")
  EMAIL = "email", _("ایمیل")
  PHONE = "phone", _("شماره تلفن")
  TEXTAREA = "textarea", _("متن بلند")
  SELECT = "select", _("انتخابی")
  CHECKBOX = "checkbox", _("چک‌باکس")
  PASSWORD = "password", _("رمز عبور")

class RegistrationField(models.Model):
  field_key = models.SlugField(max_length=50, unique=True, verbose_name=_("کلید فیلد"))
  label = models.CharField(max_length=150, verbose_name=_("برچسب"))
  field_type = models.CharField(max_length=20, choices=RegistrationFieldType.choices, default=RegistrationFieldType.TEXT, verbose_name=_("نوع فیلد"))
  placeholder = models.CharField(max_length=200, blank=True, verbose_name=_("متن راهنما"))
  help_text = models.CharField(max_length=300, blank=True, verbose_name=_("متن کمکی"))
  choices = models.TextField(blank=True, verbose_name=_("گزینه‌ها"), help_text=_("هر گزینه در یک خط (فقط برای فیلد انتخابی)"))
  is_required = models.BooleanField(default=False, verbose_name=_("اجباری"))
  is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
  is_system = models.BooleanField(default=False, verbose_name=_("فیلد سیستمی"), help_text=_("فیلدهای سیستمی قابل حذف یا غیرفعال‌سازی نیستند"))
  show_in_profile = models.BooleanField(default=True, verbose_name=_("نمایش در پروفایل"))
  order = models.PositiveIntegerField(default=0, verbose_name=_("ترتیب"))
  created_at = models.DateTimeField(auto_now_add=True)
  updated_at = models.DateTimeField(auto_now=True)

  class Meta:
    ordering = ["order", "id"]
    verbose_name = _("فیلد ثبت‌نام")
    verbose_name_plural = _("فیلدهای ثبت‌نام")

  def __str__(self):
    return f"{self.label} ({self.field_key})"

  def get_choices_list(self):
    if not self.choices:
      return []
    return [c.strip() for c in self.choices.strip().split("\n") if c.strip()]

  def save(self, *args, **kwargs):
    if self.is_system:
      self.is_active = True
    super().save(*args, **kwargs)

class TemplateText(models.Model):
  key=models.SlugField(max_length=150, unique=True)
  title=models.CharField(max_length=200)
  value=models.TextField(blank=True)
  hint=models.CharField(max_length=300, blank=True)
  updated_at=models.DateTimeField(auto_now=True)
  class Meta:
    ordering=["key"]; verbose_name="متن قالب"; verbose_name_plural="متن‌های قالب"
  def __str__(self): return self.key

class NavLink(models.Model):
  area = models.CharField(max_length=10, choices=(("header","هدر"),("footer","فوتر")), default="footer")
  title=models.CharField(max_length=120)
  url=models.CharField(max_length=300)
  order=models.PositiveIntegerField(default=0)
  is_active=models.BooleanField(default=True)
  class Meta:
    ordering=["area","order"]; verbose_name="لینک"; verbose_name_plural="لینک‌ها"
  def __str__(self): return f"{self.area}:{self.title}"