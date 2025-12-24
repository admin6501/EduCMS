#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="educms"
APP_DIR="/opt/educms"
LOG_FILE="/var/log/educms-installer.log"

# =========================
# Helpers
# =========================
log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

die() { log "ERROR: $*"; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root."
  fi
}

trap 'die "ERROR at line $LINENO (exit=$?). Log: $LOG_FILE"' ERR

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_dirs() {
  mkdir -p "$APP_DIR"
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
}

# =========================
# Docker install
# =========================
install_docker_if_needed() {
  if cmd_exists docker && docker compose version >/dev/null 2>&1; then
    return 0
  fi

  log "Installing Docker + Docker Compose plugin..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker
}

# =========================
# Cleanup previous
# =========================
cleanup_previous_install() {
  log ">> Cleaning previous install (containers/volumes/app dir)..."
  if [[ -d "$APP_DIR" ]]; then
    cd "$APP_DIR" || true
    if [[ -f docker-compose.yml ]]; then
      docker compose down -v --remove-orphans || true
    fi
  fi
  rm -rf "$APP_DIR/app" "$APP_DIR/nginx" "$APP_DIR/media" "$APP_DIR/staticfiles" "$APP_DIR/compose" 2>/dev/null || true
  mkdir -p "$APP_DIR"
  log "OK: Cleanup done."
}

# =========================
# Write .env and compose
# =========================
write_env() {
  log ">> Writing .env ..."
  cat > "$APP_DIR/.env" <<'ENV'
DJANGO_SECRET_KEY=change-me-please-very-long-random
DJANGO_DEBUG=0
DJANGO_ALLOWED_HOSTS=*
MYSQL_DATABASE=educms
MYSQL_USER=educms
MYSQL_PASSWORD=educms_password_change_me
MYSQL_ROOT_PASSWORD=root_password_change_me
ENV
  log "OK: .env created."
}

write_compose() {
  log ">> Writing docker-compose.yml ..."
  cat > "$APP_DIR/docker-compose.yml" <<'YML'
services:
  db:
    image: mysql:8.0
    environment:
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    command: --default-authentication-plugin=mysql_native_password --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin" ,"ping", "-h", "localhost", "-p${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 10

  web:
    build:
      context: ./app
    env_file:
      - ./.env
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - ./media:/app/media
      - ./staticfiles:/app/staticfiles

  nginx:
    image: nginx:alpine
    depends_on:
      - web
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ./staticfiles:/staticfiles:ro
      - ./media:/media:ro

volumes:
  db_data:
YML

  # quick validation
  docker compose -f "$APP_DIR/docker-compose.yml" config >/dev/null
  log "OK: docker-compose.yml valid."
}

write_nginx() {
  log ">> Writing nginx config..."
  mkdir -p "$APP_DIR/nginx"
  cat > "$APP_DIR/nginx/default.conf" <<'CONF'
server {
    listen 80;
    server_name _;

    client_max_body_size 50M;

    location /static/ {
        alias /staticfiles/;
        access_log off;
        expires 30d;
    }

    location /media/ {
        alias /media/;
        access_log off;
        expires 30d;
    }

    location / {
        proxy_pass         http://web:8000;
        proxy_redirect     off;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 300;
    }
}
CONF
  log "OK: nginx config written."
}

# =========================
# Write Django project
# =========================
write_project() {
  log ">> Writing project files..."
  mkdir -p "$APP_DIR/app"
  cd "$APP_DIR/app"

  # base structure
  mkdir -p app/{educms,accounts,courses,settingsapp,payments,tickets,walletapp}
  touch app/educms/__init__.py app/accounts/__init__.py app/courses/__init__.py app/settingsapp/__init__.py app/payments/__init__.py app/tickets/__init__.py app/walletapp/__init__.py

  # requirements
  cat > requirements.txt <<'REQ'
Django>=5.0,<6.0
gunicorn>=23.0.0
mysqlclient>=2.2.0
Pillow>=10.0.0
REQ

  # Dockerfile
  cat > Dockerfile <<'DOCKER'
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential default-libmysqlclient-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

COPY . /app/

RUN chmod +x /app/entrypoint.sh

EXPOSE 8000
ENTRYPOINT ["/app/entrypoint.sh"]
DOCKER

  # manage.py
  cat > manage.py <<'PY'
#!/usr/bin/env python
import os
import sys

def main():
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "educms.settings")
    try:
        from django.core.management import execute_from_command_line
    except ImportError as exc:
        raise ImportError("Couldn't import Django.") from exc
    execute_from_command_line(sys.argv)

if __name__ == "__main__":
    main()
PY
  chmod +x manage.py

  # educms/settings.py
  cat > app/educms/settings.py <<'PY'
from pathlib import Path
import os

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "dev-secret")
DEBUG = os.environ.get("DJANGO_DEBUG", "0") == "1"
ALLOWED_HOSTS = [h.strip() for h in os.environ.get("DJANGO_ALLOWED_HOSTS", "*").split(",") if h.strip()]

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",

    "accounts.apps.AccountsConfig",
    "courses.apps.CoursesConfig",
    "settingsapp.apps.SettingsappConfig",
    "payments.apps.PaymentsConfig",
    "tickets.apps.TicketsConfig",
    "walletapp.apps.WalletappConfig",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.locale.LocaleMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "educms.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
                "settingsapp.context_processors.site_settings",
            ],
        },
    },
]

WSGI_APPLICATION = "educms.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.mysql",
        "NAME": os.environ.get("MYSQL_DATABASE", "educms"),
        "USER": os.environ.get("MYSQL_USER", "educms"),
        "PASSWORD": os.environ.get("MYSQL_PASSWORD", "educms_password_change_me"),
        "HOST": "db",
        "PORT": "3306",
        "OPTIONS": {"charset": "utf8mb4"},
    }
}

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

LANGUAGE_CODE = "fa"
TIME_ZONE = "Asia/Tehran"
USE_I18N = True
USE_TZ = True

STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
MEDIA_URL = "/media/"
MEDIA_ROOT = BASE_DIR / "media"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

AUTH_USER_MODEL = "accounts.User"
LOGIN_URL = "/login/"
LOGIN_REDIRECT_URL = "/panel/"
LOGOUT_REDIRECT_URL = "/"
PY

  # educms/urls.py
  cat > app/educms/urls.py <<'PY'
from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static

urlpatterns = [
    path("", include("courses.urls")),
    path("", include("accounts.urls")),
    path("orders/", include("payments.urls")),
    path("tickets/", include("tickets.urls")),
    path("wallet/", include("walletapp.urls")),
    path("admin/", admin.site.urls),
]

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
PY

  # wsgi
  cat > app/educms/wsgi.py <<'PY'
import os
from django.core.wsgi import get_wsgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "educms.settings")
application = get_wsgi_application()
PY

  # entrypoint.sh
  cat > entrypoint.sh <<'SH'
#!/usr/bin/env sh
set -e

python manage.py collectstatic --noinput || true

python manage.py makemigrations accounts settingsapp courses payments tickets walletapp
python manage.py migrate --noinput --fake-initial

python manage.py shell <<'PY'
from django.contrib.auth import get_user_model
from settingsapp.models import SiteSetting
from payments.models import BankTransferSetting
from walletapp.models import WalletSetting, WalletAccount

User = get_user_model()
SiteSetting.objects.get_or_create(id=1, defaults={"brand_name": "EduCMS"})
BankTransferSetting.objects.get_or_create(id=1)
WalletSetting.objects.get_or_create(id=1, defaults={"enabled": True, "min_topup": 10000, "max_topup": 20000000, "allow_user_security_edit": True})

# Optional admin bootstrap (creates admin only if env vars present)
import os
admin_email = os.environ.get("ADMIN_EMAIL")
admin_pass = os.environ.get("ADMIN_PASSWORD")
if admin_email and admin_pass:
    u, created = User.objects.get_or_create(email=admin_email, defaults={"username": admin_email, "is_staff": True, "is_superuser": True})
    if created:
        u.set_password(admin_pass)
        u.save()
    WalletAccount.objects.get_or_create(user=u, defaults={"balance_toman": 0, "is_active": True})
PY

exec gunicorn educms.wsgi:application --bind 0.0.0.0:8000 --workers 3
SH
  chmod +x entrypoint.sh

  # ---------------- Accounts ----------------
  cat > app/accounts/apps.py <<'PY'
from django.apps import AppConfig

class AccountsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "accounts"
    verbose_name = "حساب‌ها"
PY

  cat > app/accounts/models.py <<'PY'
from django.db import models
from django.contrib.auth.models import AbstractUser
from django.utils.translation import gettext_lazy as _

class User(AbstractUser):
    email = models.EmailField(_("ایمیل"), unique=True)

    def __str__(self):
        return self.email or self.username

class SecurityQuestion(models.Model):
    text = models.CharField(max_length=255, unique=True, verbose_name=_("سوال"))

    class Meta:
        verbose_name = _("سوال امنیتی")
        verbose_name_plural = _("سوالات امنیتی")

    def __str__(self):
        return self.text

class UserSecurityAnswer(models.Model):
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name="security_answer", verbose_name=_("کاربر"))
    question = models.ForeignKey(SecurityQuestion, on_delete=models.PROTECT, verbose_name=_("سوال"))
    answer = models.CharField(max_length=255, verbose_name=_("پاسخ"))

    class Meta:
        verbose_name = _("پاسخ امنیتی کاربر")
        verbose_name_plural = _("پاسخ‌های امنیتی کاربران")

    def __str__(self):
        return f"{self.user} - {self.question}"

    def check_answer(self, raw: str) -> bool:
        return (raw or "").strip() == (self.answer or "").strip()
PY

  cat > app/accounts/forms.py <<'PY'
from django import forms
from django.contrib.auth import get_user_model
from django.contrib.auth.forms import UserCreationForm, AuthenticationForm
from django.utils.translation import gettext_lazy as _
from .models import SecurityQuestion, UserSecurityAnswer

User = get_user_model()

class EmailAuthForm(AuthenticationForm):
    username = forms.EmailField(label=_("ایمیل"))

class RegisterForm(UserCreationForm):
    email = forms.EmailField(label=_("ایمیل"), required=True)
    security_question = forms.ModelChoiceField(queryset=SecurityQuestion.objects.all(), label=_("سوال امنیتی"))
    security_answer = forms.CharField(label=_("پاسخ سوال امنیتی"), required=True)

    class Meta:
        model = User
        fields = ("email", "password1", "password2")

    def save(self, commit=True):
        user = super().save(commit=False)
        user.username = self.cleaned_data["email"]
        user.email = self.cleaned_data["email"]
        if commit:
            user.save()
            UserSecurityAnswer.objects.update_or_create(
                user=user,
                defaults={"question": self.cleaned_data["security_question"], "answer": self.cleaned_data["security_answer"]},
            )
        return user

class ForgotPasswordUsernameForm(forms.Form):
    email = forms.EmailField(label=_("ایمیل"), required=True)

class ForgotPasswordVerifyForm(forms.Form):
    security_answer = forms.CharField(label=_("پاسخ سوال امنیتی"), required=True)
    new_password1 = forms.CharField(label=_("رمز جدید"), widget=forms.PasswordInput, required=True)
    new_password2 = forms.CharField(label=_("تکرار رمز جدید"), widget=forms.PasswordInput, required=True)

    def clean(self):
        cleaned = super().clean()
        p1 = cleaned.get("new_password1")
        p2 = cleaned.get("new_password2")
        if p1 and p2 and p1 != p2:
            raise forms.ValidationError(_("رمزها یکسان نیستند."))
        return cleaned
PY

  cat > app/accounts/admin.py <<'PY'
from django.contrib import admin
from django.contrib.auth import get_user_model
from django.contrib.auth.admin import UserAdmin as DjangoUserAdmin
from .models import SecurityQuestion, UserSecurityAnswer

User = get_user_model()

@admin.register(User)
class UserAdmin(DjangoUserAdmin):
    model = User
    list_display = ("email", "is_staff", "is_active", "date_joined")
    ordering = ("email",)
    search_fields = ("email", "username")
    fieldsets = (
        (None, {"fields": ("email", "username", "password")}),
        ("Permissions", {"fields": ("is_active", "is_staff", "is_superuser", "groups", "user_permissions")}),
        ("Important dates", {"fields": ("last_login", "date_joined")}),
    )
    add_fieldsets = (
        (None, {"classes": ("wide",), "fields": ("email", "username", "password1", "password2", "is_staff", "is_superuser")}),
    )

@admin.register(SecurityQuestion)
class SecurityQuestionAdmin(admin.ModelAdmin):
    list_display = ("text",)
    search_fields = ("text",)

@admin.register(UserSecurityAnswer)
class UserSecurityAnswerAdmin(admin.ModelAdmin):
    list_display = ("user", "question")
    search_fields = ("user__email", "question__text")
PY

  cat > app/accounts/views.py <<'PY'
from django.contrib import messages
from django.contrib.auth import login, logout
from django.contrib.auth.decorators import login_required
from django.contrib.auth.forms import AuthenticationForm
from django.shortcuts import render, redirect, get_object_or_404

from .forms import RegisterForm, EmailAuthForm, ForgotPasswordUsernameForm, ForgotPasswordVerifyForm
from .models import User, UserSecurityAnswer

@login_required
def panel(request):
    return render(request, "accounts/dashboard.html")

def login_view(request):
    if request.user.is_authenticated:
        return redirect("/panel/")
    form = EmailAuthForm(request, data=request.POST or None)
    if request.method == "POST" and form.is_valid():
        login(request, form.get_user())
        return redirect("/panel/")
    return render(request, "accounts/login.html", {"form": form})

def logout_view(request):
    logout(request)
    return redirect("/")

def register_view(request):
    if request.user.is_authenticated:
        return redirect("/panel/")
    form = RegisterForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        user = form.save()
        login(request, user)
        return redirect("/panel/")
    return render(request, "accounts/register.html", {"form": form})

def forgot_password_start(request):
    form = ForgotPasswordUsernameForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        email = form.cleaned_data["email"].strip().lower()
        user = User.objects.filter(email=email).first()
        if not user:
            messages.error(request, "کاربری با این ایمیل پیدا نشد.")
            return redirect("forgot_start")
        return redirect("forgot_verify", user_id=user.id)
    return render(request, "accounts/forgot_start.html", {"form": form})

def forgot_password_verify(request, user_id):
    user = get_object_or_404(User, id=user_id)
    usa = UserSecurityAnswer.objects.filter(user=user).select_related("question").first()
    if not usa:
        messages.error(request, "سوال امنیتی برای این کاربر ثبت نشده است.")
        return redirect("forgot_start")

    form = ForgotPasswordVerifyForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        ans = form.cleaned_data["security_answer"]
        if not usa.check_answer(ans):
            messages.error(request, "پاسخ سوال امنیتی صحیح نیست.")
            return redirect("forgot_verify", user_id=user.id)

        p1 = form.cleaned_data["new_password1"]
        user.set_password(p1)
        user.save()
        messages.success(request, "رمز با موفقیت تغییر کرد. اکنون وارد شوید.")
        return redirect("login")
    return render(request, "accounts/forgot_verify.html", {"form": form, "question": usa.question.text, "email": user.email})
PY

  cat > app/accounts/urls.py <<'PY'
from django.urls import path
from .views import panel, login_view, logout_view, register_view, forgot_password_start, forgot_password_verify

urlpatterns = [
    path("panel/", panel, name="panel"),
    path("login/", login_view, name="login"),
    path("logout/", logout_view, name="logout"),
    path("register/", register_view, name="register"),
    path("forgot/", forgot_password_start, name="forgot_start"),
    path("forgot/<int:user_id>/", forgot_password_verify, name="forgot_verify"),
]
PY

  # ---------------- Settings ----------------
  cat > app/settingsapp/apps.py <<'PY'
from django.apps import AppConfig

class SettingsappConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "settingsapp"
    verbose_name = "تنظیمات"
PY

  cat > app/settingsapp/models.py <<'PY'
from django.db import models

class SiteSetting(models.Model):
    brand_name = models.CharField(max_length=80, default="EduCMS")
    allow_profile_edit = models.BooleanField(default=True)

    def __str__(self):
        return self.brand_name
PY

  cat > app/settingsapp/admin.py <<'PY'
from django.contrib import admin
from .models import SiteSetting

@admin.register(SiteSetting)
class SiteSettingAdmin(admin.ModelAdmin):
    list_display = ("brand_name", "allow_profile_edit")
PY

  cat > app/settingsapp/context_processors.py <<'PY'
from .models import SiteSetting

def site_settings(request):
    return {"site_settings": SiteSetting.objects.first()}
PY

  # ---------------- Courses ----------------
  cat > app/courses/apps.py <<'PY'
from django.apps import AppConfig

class CoursesConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "courses"
    verbose_name = "دوره‌ها"
PY

  cat > app/courses/models.py <<'PY'
from django.db import models
from django.conf import settings

class Course(models.Model):
    title = models.CharField(max_length=200)
    slug = models.SlugField(unique=True)
    price_toman = models.PositiveIntegerField(default=0)
    description = models.TextField(blank=True)

    def __str__(self):
        return self.title

class Enrollment(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    course = models.ForeignKey(Course, on_delete=models.CASCADE)
    is_active = models.BooleanField(default=True)
    source = models.CharField(max_length=30, default="order")

    class Meta:
        unique_together = ("user", "course")
PY

  cat > app/courses/views.py <<'PY'
from django.shortcuts import render, get_object_or_404
from .models import Course

def home(request):
    courses = Course.objects.all().order_by("-id")[:12]
    return render(request, "courses/home.html", {"courses": courses})

def course_detail(request, slug):
    course = get_object_or_404(Course, slug=slug)
    return render(request, "courses/course_detail.html", {"course": course})
PY

  cat > app/courses/urls.py <<'PY'
from django.urls import path
from .views import home, course_detail

urlpatterns = [
    path("", home, name="home"),
    path("course/<slug:slug>/", course_detail, name="course_detail"),
]
PY

  # ---------------- Payments (Orders) ----------------
  cat > app/payments/apps.py <<'PY'
from django.apps import AppConfig

class PaymentsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "payments"
    verbose_name = "سفارش‌ها"
PY

  cat > app/payments/models.py <<'PY'
import uuid
from django.db import models
from django.conf import settings
from django.utils import timezone
from courses.models import Course

class OrderStatus(models.TextChoices):
    PENDING = "pending", "در انتظار پرداخت"
    PAID = "paid", "پرداخت شده"

class Coupon(models.Model):
    code = models.CharField(max_length=30, unique=True)
    percent = models.PositiveIntegerField(default=0)
    amount_toman = models.PositiveIntegerField(default=0)
    active = models.BooleanField(default=True)
    start_at = models.DateTimeField(blank=True, null=True)
    end_at = models.DateTimeField(blank=True, null=True)

    def __str__(self):
        return self.code

class Order(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    course = models.ForeignKey(Course, on_delete=models.CASCADE)

    amount = models.PositiveIntegerField(default=0)
    discount = models.PositiveIntegerField(default=0)
    final_amount = models.PositiveIntegerField(default=0)

    coupon = models.ForeignKey(Coupon, on_delete=models.SET_NULL, null=True, blank=True)
    status = models.CharField(max_length=20, choices=OrderStatus.choices, default=OrderStatus.PENDING)

    receipt_image = models.ImageField(upload_to="receipts/", blank=True, null=True)
    tracking_code = models.CharField(max_length=80, blank=True)

    created_at = models.DateTimeField(auto_now_add=True)
    verified_at = models.DateTimeField(blank=True, null=True)

class BankTransferSetting(models.Model):
    account_holder = models.CharField(max_length=120, blank=True)
    card_number = models.CharField(max_length=40, blank=True)
    note = models.TextField(blank=True)
PY

  cat > app/payments/utils.py <<'PY'
from django.utils import timezone
from .models import Coupon

def validate_coupon(code: str):
    if not code:
        return None
    c = Coupon.objects.filter(code=code.strip(), active=True).first()
    if not c:
        return None
    now = timezone.now()
    if c.start_at and now < c.start_at:
        return None
    if c.end_at and now > c.end_at:
        return None
    return c

def calc_coupon_discount(amount: int, coupon: Coupon) -> int:
    if not coupon:
        return 0
    disc = 0
    if coupon.percent:
        disc += int(amount) * int(coupon.percent) // 100
    if coupon.amount_toman:
        disc += int(coupon.amount_toman)
    if disc > amount:
        disc = amount
    return disc
PY

  cat > app/payments/views.py <<'PY'
from django.contrib import messages
from django.utils import timezone
from django.contrib.auth.decorators import login_required
from django.shortcuts import render, redirect, get_object_or_404

from courses.models import Course, Enrollment
from .models import Order, OrderStatus, BankTransferSetting
from .utils import validate_coupon, calc_coupon_discount
from walletapp.services import get_wallet_setting, get_or_create_wallet, wallet_spend

@login_required
def checkout(request, slug):
    course = get_object_or_404(Course, slug=slug)
    bank = BankTransferSetting.objects.first()

    coupon_code = (request.GET.get("coupon") or "").strip()
    coupon = validate_coupon(coupon_code)

    amount = int(course.price_toman)
    discount = calc_coupon_discount(amount, coupon)
    final_amount = max(0, amount - discount)

    order, created = Order.objects.get_or_create(
        user=request.user, course=course, status=OrderStatus.PENDING,
        defaults={"amount": amount, "discount": discount, "final_amount": final_amount, "coupon": coupon}
    )
    if not created:
        order.amount = amount
        order.discount = discount
        order.final_amount = final_amount
        order.coupon = coupon
        order.save()

    # Wallet
    wallet_setting = get_wallet_setting()
    wallet = get_or_create_wallet(request.user)
    wallet_enabled = bool(wallet_setting.enabled)
    wallet_balance = int(getattr(wallet, "balance_toman", 0) or 0)
    wallet_can_pay = wallet_enabled and getattr(wallet, "is_active", True) and wallet_balance >= int(order.final_amount)

    return render(request, "orders/checkout.html", {
        "course": course,
        "order": order,
        "bank": bank,
        "coupon": coupon,
        "wallet_enabled": wallet_enabled,
        "wallet_balance": wallet_balance,
        "wallet_can_pay": wallet_can_pay,
    })

@login_required
def upload_receipt(request, order_id):
    order = get_object_or_404(Order, id=order_id, user=request.user)
    if request.method == "POST":
        file = request.FILES.get("receipt_image")
        tracking = (request.POST.get("tracking_code") or "").strip()
        if not file:
            messages.error(request, "تصویر رسید الزامی است.")
            return redirect("orders_upload", order_id=order.id)
        order.receipt_image = file
        order.tracking_code = tracking
        order.save()
        messages.success(request, "رسید ثبت شد. پس از تایید ادمین، دوره فعال می‌شود.")
        return redirect("orders_my")
    return render(request, "orders/upload_receipt.html", {"order": order})

@login_required
def my_orders(request):
    orders = Order.objects.filter(user=request.user).order_by("-created_at")[:50]
    return render(request, "orders/my_orders.html", {"orders": orders})

@login_required
def pay_with_wallet(request, order_id):
    order = get_object_or_404(Order, id=order_id, user=request.user)
    if order.status == OrderStatus.PAID:
        return redirect("orders_my")
    setting = get_wallet_setting()
    if not setting.enabled:
        messages.error(request, "کیف پول غیرفعال است.")
        return redirect("checkout", slug=order.course.slug)

    wallet = get_or_create_wallet(request.user)
    if not wallet.is_active:
        messages.error(request, "کیف پول شما غیرفعال است.")
        return redirect("checkout", slug=order.course.slug)

    try:
        wallet_spend(request.user, int(order.final_amount), note=f"پرداخت سفارش {order.id}")
    except Exception as e:
        messages.error(request, str(e))
        return redirect("checkout", slug=order.course.slug)

    order.status = OrderStatus.PAID
    order.verified_at = timezone.now()
    order.save(update_fields=["status","verified_at"])
    Enrollment.objects.get_or_create(user=request.user, course=order.course, defaults={"is_active": True, "source": "wallet"})
    messages.success(request, "پرداخت با کیف پول انجام شد و دسترسی دوره فعال گردید.")
    return redirect("course_detail", slug=order.course.slug)
PY

  cat > app/payments/urls.py <<'PY'
from django.urls import path
from .views import checkout, upload_receipt, my_orders, pay_with_wallet

urlpatterns = [
    path("checkout/<slug:slug>/", checkout, name="checkout"),
    path("upload/<uuid:order_id>/", upload_receipt, name="orders_upload"),
    path("my/", my_orders, name="orders_my"),
    path("pay-wallet/<uuid:order_id>/", pay_with_wallet, name="pay_wallet"),
]
PY

  cat > app/payments/admin.py <<'PY'
from django.contrib import admin
from django.utils import timezone
from .models import Order, Coupon, BankTransferSetting, OrderStatus
from courses.models import Enrollment

@admin.action(description="تایید سفارش و فعال‌سازی دوره")
def mark_paid(modeladmin, request, queryset):
    for o in queryset:
        if o.status == OrderStatus.PAID:
            continue
        o.status = OrderStatus.PAID
        o.verified_at = timezone.now()
        o.save()
        Enrollment.objects.get_or_create(user=o.user, course=o.course, defaults={"is_active": True, "source": "admin"})

@admin.register(Order)
class OrderAdmin(admin.ModelAdmin):
    list_display = ("id","user","course","final_amount","status","created_at","verified_at")
    list_filter = ("status","created_at")
    search_fields = ("user__email","course__title","id")
    actions = [mark_paid]

@admin.register(Coupon)
class CouponAdmin(admin.ModelAdmin):
    list_display = ("code","percent","amount_toman","active","start_at","end_at")
    list_filter = ("active",)

@admin.register(BankTransferSetting)
class BankTransferSettingAdmin(admin.ModelAdmin):
    list_display = ("account_holder","card_number")
PY

  # ---------------- Tickets ----------------
  cat > app/tickets/apps.py <<'PY'
from django.apps import AppConfig

class TicketsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "tickets"
    verbose_name = "تیکت‌ها"
PY

  cat > app/tickets/models.py <<'PY'
from django.db import models
from django.conf import settings

class Ticket(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    title = models.CharField(max_length=200)
    body = models.TextField()
    created_at = models.DateTimeField(auto_now_add=True)

class TicketReply(models.Model):
    ticket = models.ForeignKey(Ticket, on_delete=models.CASCADE, related_name="replies")
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    body = models.TextField()
    created_at = models.DateTimeField(auto_now_add=True)
PY

  cat > app/tickets/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.shortcuts import render, redirect, get_object_or_404
from .models import Ticket, TicketReply

@login_required
def list_tickets(request):
    tickets = Ticket.objects.filter(user=request.user).order_by("-created_at")[:50]
    return render(request, "tickets/list.html", {"tickets": tickets})

@login_required
def ticket_detail(request, pk):
    t = get_object_or_404(Ticket, pk=pk, user=request.user)
    if request.method == "POST":
        body = (request.POST.get("body") or "").strip()
        if body:
            TicketReply.objects.create(ticket=t, user=request.user, body=body)
            return redirect("ticket_detail", pk=t.pk)
    return render(request, "tickets/detail.html", {"ticket": t})

@login_required
def create_ticket(request):
    if request.method == "POST":
        title = (request.POST.get("title") or "").strip()
        body = (request.POST.get("body") or "").strip()
        if title and body:
            Ticket.objects.create(user=request.user, title=title, body=body)
            return redirect("tickets_list")
    return render(request, "tickets/create.html")
PY

  cat > app/tickets/urls.py <<'PY'
from django.urls import path
from .views import list_tickets, ticket_detail, create_ticket

urlpatterns = [
    path("", list_tickets, name="tickets_list"),
    path("create/", create_ticket, name="tickets_create"),
    path("<int:pk>/", ticket_detail, name="ticket_detail"),
]
PY

  cat > app/tickets/admin.py <<'PY'
from django.contrib import admin
from .models import Ticket, TicketReply

@admin.register(Ticket)
class TicketAdmin(admin.ModelAdmin):
    list_display = ("id","user","title","created_at")
    search_fields = ("user__email","title")

@admin.register(TicketReply)
class TicketReplyAdmin(admin.ModelAdmin):
    list_display = ("id","ticket","user","created_at")
PY

  # ---------------- Wallet ----------------
  cat > app/walletapp/apps.py <<'PY'
from django.apps import AppConfig

class WalletappConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "walletapp"
    verbose_name = "کیف پول"
PY

  cat > app/walletapp/models.py <<'PY'
import uuid
from django.db import models
from django.conf import settings
from django.utils.translation import gettext_lazy as _

class WalletSetting(models.Model):
    enabled = models.BooleanField(default=True, verbose_name=_("فعال بودن کیف پول"))
    min_topup = models.PositiveIntegerField(default=10000, verbose_name=_("حداقل شارژ (تومان)"))
    max_topup = models.PositiveIntegerField(default=20000000, verbose_name=_("حداکثر شارژ (تومان)"))
    allow_user_security_edit = models.BooleanField(default=True, verbose_name=_("اجازه تغییر سوال/پاسخ امنیتی توسط کاربر"))
    updated_at = models.DateTimeField(auto_now=True, verbose_name=_("بروزرسانی"))

    class Meta:
        verbose_name = _("تنظیمات کیف پول")
        verbose_name_plural = _("تنظیمات کیف پول")

    def __str__(self):
        return "Wallet Settings"

class WalletAccount(models.Model):
    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="wallet", verbose_name=_("کاربر"))
    balance_toman = models.IntegerField(default=0, verbose_name=_("موجودی (تومان)"))
    is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
    updated_at = models.DateTimeField(auto_now=True, verbose_name=_("بروزرسانی"))

    class Meta:
        verbose_name = _("کیف پول کاربر")
        verbose_name_plural = _("کیف پول کاربران")

    def __str__(self):
        return f"{self.user} ({self.balance_toman})"

class WalletTxType(models.TextChoices):
    TOPUP_APPROVED = "topup_approved", _("شارژ تایید شده")
    ADMIN_ADJUST = "admin_adjust", _("اصلاح توسط ادمین")
    PURCHASE = "purchase", _("خرید")

class WalletTransaction(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    wallet = models.ForeignKey(WalletAccount, on_delete=models.CASCADE, related_name="transactions", verbose_name=_("کیف پول"))
    type = models.CharField(max_length=30, choices=WalletTxType.choices, verbose_name=_("نوع"))
    amount_toman = models.IntegerField(verbose_name=_("مبلغ (مثبت/منفی)"))
    balance_after = models.IntegerField(default=0, verbose_name=_("موجودی پس از تراکنش"))
    note = models.CharField(max_length=240, blank=True, verbose_name=_("توضیحات"))
    created_at = models.DateTimeField(auto_now_add=True, verbose_name=_("ایجاد"))

    class Meta:
        ordering = ["-created_at"]
        verbose_name = _("تراکنش کیف پول")
        verbose_name_plural = _("تراکنش‌های کیف پول")

class TopUpStatus(models.TextChoices):
    PENDING_PAYMENT = "pending_payment", _("در انتظار پرداخت")
    PENDING_VERIFY = "pending_verify", _("در انتظار تایید")
    APPROVED = "approved", _("تایید شده")
    REJECTED = "rejected", _("رد شده")
    CANCELED = "canceled", _("لغو شده")

class WalletTopUp(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, verbose_name=_("کاربر"))
    amount_toman = models.PositiveIntegerField(verbose_name=_("مبلغ شارژ (تومان)"))
    status = models.CharField(max_length=30, choices=TopUpStatus.choices, default=TopUpStatus.PENDING_PAYMENT, verbose_name=_("وضعیت"))
    receipt_image = models.ImageField(upload_to="wallet/receipts/", blank=True, null=True, verbose_name=_("رسید"))
    tracking_code = models.CharField(max_length=80, blank=True, verbose_name=_("کد پیگیری"))
    note = models.TextField(blank=True, verbose_name=_("یادداشت"))
    created_at = models.DateTimeField(auto_now_add=True, verbose_name=_("ایجاد"))
    verified_at = models.DateTimeField(blank=True, null=True, verbose_name=_("تایید"))

    class Meta:
        ordering = ["-created_at"]
        verbose_name = _("شارژ کیف پول")
        verbose_name_plural = _("شارژهای کیف پول")
PY

  cat > app/walletapp/services.py <<'PY'
from django.db import transaction
from .models import WalletAccount, WalletTransaction, WalletTxType, WalletSetting

def get_wallet_setting():
    s = WalletSetting.objects.first()
    if not s:
        s = WalletSetting.objects.create(enabled=True)
    return s

def get_or_create_wallet(user) -> WalletAccount:
    w, _ = WalletAccount.objects.get_or_create(user=user, defaults={"balance_toman": 0, "is_active": True})
    return w

@transaction.atomic
def wallet_adjust(user, amount_toman: int, tx_type: str, note: str = "") -> WalletTransaction:
    w = get_or_create_wallet(user)
    w.balance_toman = int(w.balance_toman) + int(amount_toman)
    w.save(update_fields=["balance_toman", "updated_at"])
    tx = WalletTransaction.objects.create(wallet=w, type=tx_type, amount_toman=int(amount_toman), balance_after=w.balance_toman, note=note or "")
    return tx

@transaction.atomic
def wallet_spend(user, amount_toman: int, note: str = "") -> WalletTransaction:
    w = get_or_create_wallet(user)
    if not w.is_active:
        raise ValueError("کیف پول این کاربر غیرفعال است.")
    if w.balance_toman < int(amount_toman):
        raise ValueError("موجودی کیف پول کافی نیست.")
    w.balance_toman = int(w.balance_toman) - int(amount_toman)
    w.save(update_fields=["balance_toman", "updated_at"])
    tx = WalletTransaction.objects.create(wallet=w, type=WalletTxType.PURCHASE, amount_toman=-int(amount_toman), balance_after=w.balance_toman, note=note or "")
    return tx
PY

  cat > app/walletapp/forms.py <<'PY'
from django import forms
from django.utils.translation import gettext_lazy as _

class WalletTopUpCreateForm(forms.Form):
    amount_toman = forms.IntegerField(min_value=1000, label=_("مبلغ شارژ (تومان)"))

class WalletTopUpReceiptForm(forms.Form):
    receipt_image = forms.ImageField(required=True, label=_("تصویر رسید"))
    tracking_code = forms.CharField(required=False, max_length=80, label=_("کد پیگیری"))
    note = forms.CharField(required=False, widget=forms.Textarea, label=_("یادداشت"))
PY

  cat > app/walletapp/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.contrib import messages
from django.shortcuts import render, redirect, get_object_or_404

from payments.models import BankTransferSetting
from .models import WalletTopUp, TopUpStatus
from .forms import WalletTopUpCreateForm, WalletTopUpReceiptForm
from .services import get_wallet_setting, get_or_create_wallet

@login_required
def wallet_home(request):
    setting = get_wallet_setting()
    wallet = get_or_create_wallet(request.user)
    if not setting.enabled:
        return render(request, "wallet/disabled.html", {"wallet": wallet, "setting": setting})

    topups = WalletTopUp.objects.filter(user=request.user)[:20]
    txs = wallet.transactions.all()[:30]
    return render(request, "wallet/home.html", {"wallet": wallet, "setting": setting, "topups": topups, "txs": txs})

@login_required
def wallet_topup_create(request):
    setting = get_wallet_setting()
    if not setting.enabled:
        messages.error(request, "کیف پول در حال حاضر غیرفعال است.")
        return redirect("wallet_home")

    form = WalletTopUpCreateForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        amt = int(form.cleaned_data["amount_toman"])
        if amt < int(setting.min_topup or 0) or (setting.max_topup and amt > int(setting.max_topup)):
            messages.error(request, "مبلغ شارژ خارج از محدودیت تعیین شده است.")
            return redirect("wallet_topup_create")
        t = WalletTopUp.objects.create(user=request.user, amount_toman=amt, status=TopUpStatus.PENDING_PAYMENT)
        return redirect("wallet_topup_upload", topup_id=t.id)

    return render(request, "wallet/topup_create.html", {"form": form, "setting": setting})

@login_required
def wallet_topup_upload(request, topup_id):
    t = get_object_or_404(WalletTopUp, id=topup_id, user=request.user)
    bank = BankTransferSetting.objects.first()

    if t.status in [TopUpStatus.APPROVED, TopUpStatus.CANCELED]:
        return redirect("wallet_home")

    form = WalletTopUpReceiptForm(request.POST or None, request.FILES or None)
    if request.method == "POST" and form.is_valid():
        t.receipt_image = form.cleaned_data["receipt_image"]
        t.tracking_code = form.cleaned_data.get("tracking_code","")
        t.note = form.cleaned_data.get("note","")
        t.status = TopUpStatus.PENDING_VERIFY
        t.save()
        messages.success(request, "رسید شارژ ثبت شد و پس از تایید، موجودی اضافه می‌شود.")
        return redirect("wallet_home")

    return render(request, "wallet/topup_upload.html", {"topup": t, "bank": bank, "form": form})
PY

  cat > app/walletapp/urls.py <<'PY'
from django.urls import path
from .views import wallet_home, wallet_topup_create, wallet_topup_upload

urlpatterns = [
    path("", wallet_home, name="wallet_home"),
    path("topup/", wallet_topup_create, name="wallet_topup_create"),
    path("topup/<uuid:topup_id>/", wallet_topup_upload, name="wallet_topup_upload"),
]
PY

  cat > app/walletapp/admin.py <<'PY'
from django.contrib import admin
from django.utils import timezone
from django.contrib.auth import get_user_model

from .models import WalletSetting, WalletAccount, WalletTransaction, WalletTopUp, TopUpStatus, WalletTxType
from .services import wallet_adjust

User = get_user_model()

@admin.register(WalletSetting)
class WalletSettingAdmin(admin.ModelAdmin):
    list_display = ("enabled","min_topup","max_topup","allow_user_security_edit","updated_at")

@admin.action(description="تایید شارژ و افزودن به کیف پول")
def approve_topups(modeladmin, request, queryset):
    for t in queryset.select_related("user"):
        if t.status != TopUpStatus.PENDING_VERIFY:
            continue
        wallet_adjust(t.user, int(t.amount_toman), WalletTxType.TOPUP_APPROVED, note=f"شارژ تایید شد ({t.id})")
        t.status = TopUpStatus.APPROVED
        t.verified_at = timezone.now()
        t.save(update_fields=["status","verified_at"])

@admin.register(WalletTopUp)
class WalletTopUpAdmin(admin.ModelAdmin):
    list_display = ("id","user","amount_toman","status","created_at","verified_at")
    list_filter = ("status","created_at")
    search_fields = ("user__email","tracking_code")
    actions = [approve_topups]

@admin.action(description="واریز همگانی (اعتبار هدیه) به همه کاربران")
def bulk_credit_all(modeladmin, request, queryset):
    amt = request.POST.get("amount") or request.GET.get("amount")
    try:
        amt_i = int(amt)
    except Exception:
        amt_i = 0
    if amt_i <= 0:
        modeladmin.message_user(request, "برای استفاده از این اکشن باید پارامتر amount را ارسال کنید (مثلاً 50000).", level="ERROR")
        return
    for u in User.objects.all().iterator():
        wallet_adjust(u, amt_i, WalletTxType.ADMIN_ADJUST, note="واریز همگانی توسط ادمین")
    modeladmin.message_user(request, f"به همه کاربران مبلغ {amt_i} تومان واریز شد.")

@admin.register(WalletAccount)
class WalletAccountAdmin(admin.ModelAdmin):
    list_display = ("user","balance_toman","is_active","updated_at")
    list_filter = ("is_active",)
    search_fields = ("user__email",)
    actions = [bulk_credit_all]

    def save_model(self, request, obj, form, change):
        if change:
            old = WalletAccount.objects.get(pk=obj.pk)
            diff = int(obj.balance_toman) - int(old.balance_toman)
            super().save_model(request, obj, form, change)
            if diff != 0:
                WalletTransaction.objects.create(
                    wallet=obj,
                    type=WalletTxType.ADMIN_ADJUST,
                    amount_toman=diff,
                    balance_after=obj.balance_toman,
                    note=f"تغییر مستقیم توسط ادمین ({request.user})",
                )
        else:
            super().save_model(request, obj, form, change)

@admin.register(WalletTransaction)
class WalletTransactionAdmin(admin.ModelAdmin):
    list_display = ("id","wallet","type","amount_toman","balance_after","created_at")
    list_filter = ("type","created_at")
    search_fields = ("wallet__user__email","note")
PY

  # ---------------- Templates ----------------
  mkdir -p app/templates/{courses,accounts,orders,tickets,settings,admin,partials,wallet}

  cat > app/templates/base.html <<'HTML'
<!doctype html>
<html lang="fa" dir="rtl">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>{% block title %}{{ site_settings.brand_name|default:"EduCMS" }}{% endblock %}</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
    body{font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial}
    .card{border-radius:1rem;border:1px solid rgba(148,163,184,.25);background:rgba(255,255,255,.85);backdrop-filter: blur(8px)}
    .dark .card{background:rgba(2,6,23,.65);border-color:rgba(148,163,184,.18)}
    .btn-primary{display:inline-flex;align-items:center;justify-content:center;border-radius:1rem;padding:.75rem 1rem;font-weight:700;background:#0f172a;color:#fff}
    .btn-ghost{display:inline-flex;align-items:center;justify-content:center;border-radius:1rem;padding:.75rem 1rem;font-weight:700;border:1px solid rgba(148,163,184,.25)}
    .form-grid p{margin:.5rem 0}
    .form-grid input,.form-grid select,.form-grid textarea{width:100%;padding:.75rem 1rem;border-radius:1rem;border:1px solid rgba(148,163,184,.35);outline:none}
  </style>
</head>
<body class="min-h-screen bg-slate-50 text-slate-900">
  <header class="border-b bg-white/80 backdrop-blur">
    <div class="max-w-6xl mx-auto px-4 py-3 flex items-center justify-between gap-3">
      <a class="font-extrabold" href="/">{{ site_settings.brand_name|default:"EduCMS" }}</a>
      <nav class="flex items-center gap-2">
        {% if user.is_authenticated %}
          <a class="btn-ghost" href="/panel/">پنل</a>
          <a class="btn-ghost" href="/logout/">خروج</a>
        {% else %}
          <a class="btn-ghost" href="/login/">ورود</a>
          <a class="btn-primary" href="/register/">ثبت‌نام</a>
        {% endif %}
      </nav>
    </div>
  </header>

  <main class="max-w-6xl mx-auto px-4 py-6">
    {% if messages %}
      <div class="space-y-2 mb-4">
        {% for m in messages %}
          <div class="card p-3 text-sm">{{ m }}</div>
        {% endfor %}
      </div>
    {% endif %}
    {% block content %}{% endblock %}
  </main>
</body>
</html>
HTML

  # Courses templates
  cat > app/templates/courses/home.html <<'HTML'
{% extends "base.html" %}
{% block title %}خانه - {{ site_settings.brand_name|default:"EduCMS" }}{% endblock %}
{% block content %}
<div class="grid md:grid-cols-2 lg:grid-cols-3 gap-4">
  {% for c in courses %}
    <div class="card p-5">
      <div class="text-xl font-extrabold mb-2">{{ c.title }}</div>
      <div class="text-sm text-slate-600 mb-3">{{ c.description|truncatechars:120 }}</div>
      <div class="flex items-center justify-between">
        <div class="font-bold" dir="ltr">{{ c.price_toman }} تومان</div>
        <a class="btn-primary" href="/course/{{ c.slug }}/">مشاهده</a>
      </div>
    </div>
  {% empty %}
    <div class="card p-6">هیچ دوره‌ای ثبت نشده است.</div>
  {% endfor %}
</div>
{% endblock %}
HTML

  cat > app/templates/courses/course_detail.html <<'HTML'
{% extends "base.html" %}
{% block title %}{{ course.title }} - {{ site_settings.brand_name|default:"EduCMS" }}{% endblock %}
{% block content %}
<div class="card p-6">
  <h1 class="text-2xl font-extrabold mb-2">{{ course.title }}</h1>
  <div class="text-slate-600 mb-4">{{ course.description|linebreaksbr }}</div>
  <div class="flex items-center justify-between">
    <div class="font-bold" dir="ltr">{{ course.price_toman }} تومان</div>
    <a class="btn-primary" href="/orders/checkout/{{ course.slug }}/">خرید</a>
  </div>
</div>
{% endblock %}
HTML

  # Accounts templates
  cat > app/templates/accounts/login.html <<'HTML'
{% extends "base.html" %}
{% block title %}ورود{% endblock %}
{% block content %}
<div class="mx-auto max-w-lg">
  <div class="card p-6">
    <h1 class="text-2xl font-extrabold mb-4">ورود</h1>
    <form method="post">{% csrf_token %}
      <div class="form-grid">{{ form.as_p }}</div>
      <button class="btn-primary w-full mt-3">ورود</button>
    </form>
    <div class="mt-3 flex items-center justify-between text-sm">
      <a class="underline" href="/register/">ثبت‌نام</a>
      <a class="underline" href="/forgot/">فراموشی رمز</a>
    </div>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/register.html <<'HTML'
{% extends "base.html" %}
{% block title %}ثبت‌نام{% endblock %}
{% block content %}
<div class="mx-auto max-w-lg">
  <div class="card p-6">
    <h1 class="text-2xl font-extrabold mb-4">ثبت‌نام</h1>
    <form method="post">{% csrf_token %}
      <div class="form-grid">{{ form.as_p }}</div>
      <button class="btn-primary w-full mt-3">ثبت‌نام</button>
    </form>
    <div class="mt-3 text-sm">
      <a class="underline" href="/login/">قبلاً ثبت‌نام کرده‌اید؟ وارد شوید</a>
    </div>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/dashboard.html <<'HTML'
{% extends "base.html" %}
{% block title %}پنل کاربری{% endblock %}
{% block content %}
<div class="grid md:grid-cols-2 gap-4">
  <div class="card p-6">
    <h2 class="text-xl font-extrabold mb-2">خوش آمدید</h2>
    <div class="text-sm text-slate-600">ایمیل: <b dir="ltr">{{ request.user.email }}</b></div>
    <div class="mt-4 grid grid-cols-2 gap-2">
      <a class="btn-ghost" href="/orders/my/">سفارش‌ها</a>
      <a class="btn-ghost" href="/tickets/">تیکت‌ها</a>
      <a class="btn-ghost" href="/wallet/">کیف پول</a>
      <a class="btn-ghost" href="/logout/">خروج</a>
    </div>
  </div>

  <div class="card p-6">
    <h2 class="text-xl font-extrabold mb-2">راهنما</h2>
    <div class="text-sm text-slate-600">
      برای خرید دوره از صفحه دوره وارد بخش خرید شوید. درگاه پرداخت در این نسخه از طریق «واریز و ثبت رسید» و «کیف پول» ارائه شده است.
    </div>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/forgot_start.html <<'HTML'
{% extends "base.html" %}
{% block title %}فراموشی رمز{% endblock %}
{% block content %}
<div class="mx-auto max-w-lg">
  <div class="card p-6">
    <h1 class="text-2xl font-extrabold mb-4">فراموشی رمز</h1>
    <form method="post">{% csrf_token %}
      <div class="form-grid">{{ form.as_p }}</div>
      <button class="btn-primary w-full mt-3">ادامه</button>
    </form>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/forgot_verify.html <<'HTML'
{% extends "base.html" %}
{% block title %}تغییر رمز{% endblock %}
{% block content %}
<div class="mx-auto max-w-lg">
  <div class="card p-6">
    <h1 class="text-2xl font-extrabold mb-2">تغییر رمز</h1>
    <div class="text-sm text-slate-600 mb-4">ایمیل: <b dir="ltr">{{ email }}</b></div>
    <div class="p-3 rounded-2xl border mb-4">
      <div class="text-sm text-slate-600">سوال امنیتی:</div>
      <div class="font-bold">{{ question }}</div>
    </div>
    <form method="post">{% csrf_token %}
      <div class="form-grid">{{ form.as_p }}</div>
      <button class="btn-primary w-full mt-3">ثبت رمز جدید</button>
    </form>
  </div>
</div>
{% endblock %}
HTML

  # Orders templates
  cat > app/templates/orders/checkout.html <<'HTML'
{% extends "base.html" %}
{% block title %}تسویه حساب{% endblock %}
{% block content %}
<div class="mx-auto max-w-2xl">
  <div class="card p-6">
    <h1 class="text-2xl font-extrabold mb-2">تسویه حساب</h1>
    <div class="text-sm text-slate-600 mb-4">دوره: <b>{{ course.title }}</b></div>

    <div class="grid gap-2 text-sm">
      <div class="flex justify-between"><span>مبلغ</span><b dir="ltr">{{ order.amount }} تومان</b></div>
      <div class="flex justify-between"><span>تخفیف</span><b dir="ltr">{{ order.discount }} تومان</b></div>
      <div class="flex justify-between"><span>مبلغ نهایی</span><b dir="ltr">{{ order.final_amount }} تومان</b></div>
    </div>

    {% if wallet_enabled %}
      <div class="mt-5 p-4 rounded-2xl border bg-slate-50">
        <div class="text-sm mb-2">پرداخت با کیف پول</div>
        <div class="text-sm text-slate-600 mb-3">موجودی شما: <b dir="ltr">{{ wallet_balance }}</b> تومان</div>
        {% if wallet_can_pay %}
          <a class="btn-primary w-full text-center" href="/orders/pay-wallet/{{ order.id }}/">پرداخت با کیف پول</a>
        {% else %}
          <div class="text-sm text-rose-600">موجودی کافی نیست.</div>
        {% endif %}
      </div>
    {% endif %}

    <div class="mt-5 p-4 rounded-2xl border bg-slate-50">
      <div class="text-sm mb-2">واریز کارت‌به‌کارت و ثبت رسید</div>
      <div class="text-sm text-slate-600">نام صاحب حساب: <b>{{ bank.account_holder|default:"(تنظیم نشده)" }}</b></div>
      <div class="text-sm text-slate-600">شماره کارت: <b dir="ltr">{{ bank.card_number|default:"(تنظیم نشده)" }}</b></div>
      {% if bank.note %}<div class="text-xs text-slate-500 mt-1">{{ bank.note }}</div>{% endif %}
      <a class="btn-primary w-full text-center mt-4" href="/orders/upload/{{ order.id }}/">ثبت رسید پرداخت</a>
    </div>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/orders/upload_receipt.html <<'HTML'
{% extends "base.html" %}
{% block title %}ثبت رسید{% endblock %}
{% block content %}
<div class="mx-auto max-w-lg">
  <div class="card p-6">
    <h1 class="text-2xl font-extrabold mb-4">ثبت رسید پرداخت</h1>
    <form method="post" enctype="multipart/form-data">{% csrf_token %}
      <div class="form-grid">
        <p>
          <label>تصویر رسید</label>
          <input type="file" name="receipt_image" required>
        </p>
        <p>
          <label>کد پیگیری (اختیاری)</label>
          <input type="text" name="tracking_code">
        </p>
      </div>
      <button class="btn-primary w-full mt-3">ثبت</button>
    </form>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/orders/my_orders.html <<'HTML'
{% extends "base.html" %}
{% block title %}سفارش‌های من{% endblock %}
{% block content %}
<div class="mx-auto max-w-4xl">
  <div class="card p-6">
    <h1 class="text-2xl font-extrabold mb-4">سفارش‌های من</h1>
    <div class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead class="text-slate-500">
          <tr>
            <th class="text-right py-2">شناسه</th>
            <th class="text-right py-2">دوره</th>
            <th class="text-right py-2">مبلغ</th>
            <th class="text-right py-2">وضعیت</th>
            <th class="text-right py-2">تاریخ</th>
          </tr>
        </thead>
        <tbody>
          {% for o in orders %}
            <tr class="border-t">
              <td class="py-2" dir="ltr">{{ o.id }}</td>
              <td class="py-2">{{ o.course.title }}</td>
              <td class="py-2" dir="ltr">{{ o.final_amount }}</td>
              <td class="py-2">{{ o.get_status_display }}</td>
              <td class="py-2">{{ o.created_at }}</td>
            </tr>
          {% empty %}
            <tr><td colspan="5" class="py-3 text-slate-500">سفارشی ندارید.</td></tr>
          {% endfor %}
        </tbody>
      </table>
    </div>
  </div>
</div>
{% endblock %}
HTML

  # Tickets templates
  cat > app/templates/tickets/list.html <<'HTML'
{% extends "base.html" %}
{% block title %}تیکت‌ها{% endblock %}
{% block content %}
<div class="mx-auto max-w-4xl">
  <div class="card p-6">
    <div class="flex items-center justify-between mb-4">
      <h1 class="text-2xl font-extrabold">تیکت‌ها</h1>
      <a class="btn-primary" href="/tickets/create/">ایجاد تیکت</a>
    </div>
    <div class="space-y-2">
      {% for t in tickets %}
        <a class="card p-4 block" href="/tickets/{{ t.id }}/">
          <div class="font-bold">{{ t.title }}</div>
          <div class="text-xs text-slate-500">{{ t.created_at }}</div>
        </a>
      {% empty %}
        <div class="text-slate-500">تیکتی ندارید.</div>
      {% endfor %}
    </div>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/tickets/detail.html <<'HTML'
{% extends "base.html" %}
{% block title %}جزئیات تیکت{% endblock %}
{% block content %}
<div class="mx-auto max-w-4xl">
  <div class="card p-6">
    <h1 class="text-2xl font-extrabold mb-1">{{ ticket.title }}</h1>
    <div class="text-sm text-slate-600 mb-4">{{ ticket.body }}</div>

    <div class="space-y-2 mb-4">
      {% for r in ticket.replies.all %}
        <div class="card p-3">
          <div class="text-xs text-slate-500">{{ r.created_at }}</div>
          <div class="text-sm">{{ r.body }}</div>
        </div>
      {% empty %}
        <div class="text-slate-500 text-sm">پاسخی ثبت نشده است.</div>
      {% endfor %}
    </div>

    <form method="post">{% csrf_token %}
      <textarea class="w-full p-3 rounded-2xl border" name="body" rows="3" placeholder="پاسخ شما..."></textarea>
      <button class="btn-primary mt-3">ارسال پاسخ</button>
    </form>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/tickets/create.html <<'HTML'
{% extends "base.html" %}
{% block title %}ایجاد تیکت{% endblock %}
{% block content %}
<div class="mx-auto max-w-lg">
  <div class="card p-6">
    <h1 class="text-2xl font-extrabold mb-4">ایجاد تیکت</h1>
    <form method="post">{% csrf_token %}
      <p><label>عنوان</label><input name="title" required></p>
      <p><label>متن</label><textarea name="body" rows="5" required></textarea></p>
      <button class="btn-primary w-full mt-3">ثبت</button>
    </form>
  </div>
</div>
{% endblock %}
HTML

  # Wallet templates
  cat > app/templates/wallet/disabled.html <<'HTML'
{% extends "base.html" %}
{% block title %}کیف پول{% endblock %}
{% block content %}
<div class="mx-auto max-w-3xl">
  <div class="card p-6">
    <h1 class="text-2xl font-extrabold mb-2">کیف پول</h1>
    <p class="text-slate-600">در حال حاضر کیف پول توسط ادمین غیرفعال شده است.</p>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/wallet/home.html <<'HTML'
{% extends "base.html" %}
{% block title %}کیف پول{% endblock %}
{% block content %}
<div class="mx-auto max-w-5xl grid lg:grid-cols-3 gap-4">
  <div class="card p-6 lg:col-span-1">
    <div class="text-sm text-slate-500 mb-1">موجودی کیف پول</div>
    <div class="text-3xl font-extrabold" dir="ltr">{{ wallet.balance_toman }} <span class="text-base font-semibold">تومان</span></div>

    {% if wallet.is_active %}
      <a href="/wallet/topup/" class="btn-primary mt-4 w-full text-center">شارژ کیف پول</a>
    {% else %}
      <div class="mt-4 text-sm text-rose-600">کیف پول شما غیرفعال است.</div>
    {% endif %}

    <div class="mt-4 text-xs text-slate-500">
      حداقل شارژ: {{ setting.min_topup }} تومان — حداکثر شارژ: {{ setting.max_topup }} تومان
    </div>
  </div>

  <div class="card p-6 lg:col-span-2">
    <h2 class="text-lg font-bold mb-3">آخرین تراکنش‌ها</h2>
    <div class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead class="text-slate-500">
          <tr>
            <th class="text-right py-2">تاریخ</th>
            <th class="text-right py-2">نوع</th>
            <th class="text-right py-2">مبلغ</th>
            <th class="text-right py-2">موجودی پس از</th>
            <th class="text-right py-2">توضیح</th>
          </tr>
        </thead>
        <tbody>
          {% for t in txs %}
            <tr class="border-t">
              <td class="py-2">{{ t.created_at }}</td>
              <td class="py-2">{{ t.get_type_display }}</td>
              <td class="py-2" dir="ltr">{{ t.amount_toman }}</td>
              <td class="py-2" dir="ltr">{{ t.balance_after }}</td>
              <td class="py-2">{{ t.note|default:"—" }}</td>
            </tr>
          {% empty %}
            <tr><td class="py-3 text-slate-500" colspan="5">تراکنشی ثبت نشده است.</td></tr>
          {% endfor %}
        </tbody>
      </table>
    </div>

    <hr class="my-5" />

    <h2 class="text-lg font-bold mb-3">درخواست‌های شارژ</h2>
    <div class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead class="text-slate-500">
          <tr>
            <th class="text-right py-2">شناسه</th>
            <th class="text-right py-2">مبلغ</th>
            <th class="text-right py-2">وضعیت</th>
            <th class="text-right py-2">تاریخ</th>
          </tr>
        </thead>
        <tbody>
          {% for t in topups %}
            <tr class="border-t">
              <td class="py-2" dir="ltr">{{ t.id }}</td>
              <td class="py-2" dir="ltr">{{ t.amount_toman }}</td>
              <td class="py-2">{{ t.get_status_display }}</td>
              <td class="py-2">{{ t.created_at }}</td>
            </tr>
          {% empty %}
            <tr><td class="py-3 text-slate-500" colspan="4">درخواستی ندارید.</td></tr>
          {% endfor %}
        </tbody>
      </table>
    </div>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/wallet/topup_create.html <<'HTML'
{% extends "base.html" %}
{% block title %}شارژ کیف پول{% endblock %}
{% block content %}
<div class="mx-auto max-w-lg">
  <div class="card p-6">
    <h1 class="text-2xl font-extrabold mb-2">شارژ کیف پول</h1>
    <p class="text-sm text-slate-500 mb-4">
      مبلغ مورد نظر را وارد کنید. سپس صفحه ثبت رسید برای تایید توسط ادمین نمایش داده می‌شود.
    </p>
    <form method="post">{% csrf_token %}
      <div class="form-grid">
        {{ form.as_p }}
      </div>
      <button class="btn-primary mt-3 w-full">ادامه</button>
    </form>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/wallet/topup_upload.html <<'HTML'
{% extends "base.html" %}
{% block title %}ثبت رسید شارژ{% endblock %}
{% block content %}
<div class="mx-auto max-w-2xl">
  <div class="card p-6">
    <h1 class="text-2xl font-extrabold mb-2">ثبت رسید شارژ</h1>
    <div class="text-sm text-slate-500 mb-4">
      مبلغ: <b dir="ltr">{{ topup.amount_toman }}</b> تومان — وضعیت: <b>{{ topup.get_status_display }}</b>
    </div>

    <div class="p-4 rounded-2xl border bg-slate-50 mb-5">
      <div class="text-sm">نام صاحب حساب: <b>{{ bank.account_holder|default:"(تنظیم نشده)" }}</b></div>
      <div class="text-sm">شماره کارت: <b dir="ltr">{{ bank.card_number|default:"(تنظیم نشده)" }}</b></div>
      {% if bank.note %}<div class="text-sm text-slate-500 mt-1">{{ bank.note }}</div>{% endif %}
    </div>

    <form method="post" enctype="multipart/form-data">{% csrf_token %}
      <div class="form-grid">
        {{ form.as_p }}
      </div>
      <button class="btn-primary mt-3 w-full">ثبت رسید</button>
    </form>
  </div>
</div>
{% endblock %}
HTML

  log "OK: Project files written."
}

# =========================
# Build and start
# =========================
start_stack() {
  log ">> Building images..."
  cd "$APP_DIR"
  docker compose build --no-cache
  log ">> Starting stack..."
  docker compose up -d
  log "OK: Stack started."
}

stop_stack() {
  log ">> Stopping..."
  cd "$APP_DIR"
  docker compose stop
  log "OK: Stopped."
}

start_only() {
  log ">> Starting..."
  cd "$APP_DIR"
  docker compose up -d
  log "OK: Started."
}

restart_stack() {
  log ">> Restarting..."
  cd "$APP_DIR"
  docker compose restart
  log "OK: Restarted."
}

uninstall_all() {
  log ">> Uninstall..."
  cd "$APP_DIR" || true
  docker compose down -v --remove-orphans || true
  rm -rf "$APP_DIR"
  log "OK: Uninstalled."
}

backup_db() {
  cd "$APP_DIR"
  local out="/root/educms_backup_$(date +%Y%m%d_%H%M%S).sql"
  docker compose exec -T db sh -c "mysqldump -uroot -p\${MYSQL_ROOT_PASSWORD} \${MYSQL_DATABASE}" > "$out"
  log "OK: Backup saved to $out"
}

restore_db() {
  cd "$APP_DIR"
  read -r -p "Path to .sql file: " f
  [[ -f "$f" ]] || die "File not found."
  cat "$f" | docker compose exec -T db sh -c "mysql -uroot -p\${MYSQL_ROOT_PASSWORD} \${MYSQL_DATABASE}"
  log "OK: Restore done."
}

install_all() {
  ensure_dirs
  install_docker_if_needed
  cleanup_previous_install
  log ">> Creating directories..."
  mkdir -p "$APP_DIR/media" "$APP_DIR/staticfiles"
  log "OK: Directories created."
  write_env
  write_compose
  write_nginx
  write_project
  start_stack
  log "Install finished. Open: http://SERVER_IP/"
}

# =========================
# Menu
# =========================
menu() {
  while true; do
    clear || true
    echo "============================================"
    echo "                EduCMS Menu                 "
    echo "============================================"
    echo "Path: $APP_DIR"
    echo "Log : $LOG_FILE"
    echo
    echo "1) Install (نصب کامل)"
    echo "2) Stop (توقف)"
    echo "3) Start (شروع)"
    echo "4) Restart (ری‌استارت)"
    echo "5) Backup DB (.sql)"
    echo "6) Restore DB (.sql)"
    echo "7) Uninstall (حذف کامل)"
    echo "0) Exit"
    echo
    read -r -p "Select: " c
    case "$c" in
      1) install_all ;;
      2) stop_stack ;;
      3) start_only ;;
      4) restart_stack ;;
      5) backup_db ;;
      6) restore_db ;;
      7) uninstall_all ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "Invalid"; sleep 1 ;;
    esac
    echo
    read -r -p "Press Enter to continue..." _
  done
}

need_root
ensure_dirs
menu5
