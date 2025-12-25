#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="/opt/educms"
ENV_FILE="${APP_DIR}/.env"
BACKUP_DIR="${APP_DIR}/backups"

DOMAIN=""; LE_EMAIL=""
DB_NAME="educms"; DB_USER=""; DB_PASS=""
ADMIN_USER=""; ADMIN_PASS=""; ADMIN_PATH="admin"

have_cmd(){ command -v "$1" >/dev/null 2>&1; }
die(){ echo "ERROR: $*" >&2; exit 1; }
require_root(){ [[ ${EUID:-1} -eq 0 ]] || die "Run with sudo/root"; }
require_tty(){ [[ -r /dev/tty && -w /dev/tty ]] || die "/dev/tty not accessible (run interactively)"; }

read_line(){ local p="$1" v=""; read -r -p "$p" v </dev/tty || true; printf "%s" "$(printf "%s" "${v:-}" | tr -d '\r\n')"; }
read_secret(){ local p="$1" v=""; read -r -s -p "$p" v </dev/tty || true; echo >&2; printf "%s" "$(printf "%s" "${v:-}" | tr -d '\r\n')"; }

validate_domain(){ [[ "${1:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; }
validate_email(){ [[ "${1:-}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
sanitize_admin_path(){
  local p="${1:-}"; p="$(printf "%s" "$p" | sed 's#^/##;s#/$##')"; [[ -z "$p" ]] && p="admin"
  [[ "$p" =~ ^[-A-Za-z0-9_]+$ ]] || die "Admin path invalid (allowed: A-Z a-z 0-9 _ -)"
  printf "%s" "$p"
}

install_base(){
  apt update
  apt install -y ca-certificates curl gnupg lsb-release openssl jq
}
install_docker(){
  if ! have_cmd docker; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    apt install -y docker-compose-plugin || true
  fi
  systemctl enable --now docker
}
install_certbot(){
  if ! have_cmd certbot; then
    apt update
    apt install -y certbot
  fi
}

collect_inputs(){
  echo "=== EduCMS Installer (Compact) ==="
  DOMAIN="$(read_line "Domain (e.g. example.com): ")"; validate_domain "$DOMAIN" || die "Invalid domain"
  LE_EMAIL="$(read_line "Email for Let's Encrypt: ")"; validate_email "$LE_EMAIL" || die "Invalid email"
  ADMIN_PATH="$(sanitize_admin_path "$(read_line "Admin path (default: admin): ")")"

  local t
  t="$(read_line "Database name [default: ${DB_NAME}]: ")"; [[ -n "${t:-}" ]] && DB_NAME="$t"
  DB_USER="$(read_line "Database username: ")"
  DB_PASS="$(read_secret "Database password (hidden): ")"
  ADMIN_USER="$(read_line "Admin username: ")"
  ADMIN_PASS="$(read_secret "Admin password (hidden): ")"
  [[ -n "$DB_USER" && -n "$DB_PASS" && -n "$ADMIN_USER" && -n "$ADMIN_PASS" ]] || die "Empty required input"
}

cleanup_old(){
  if [[ -d "$APP_DIR" && -f "$APP_DIR/docker-compose.yml" ]]; then
    (cd "$APP_DIR" && docker compose down --remove-orphans --volumes) || true
  fi
  rm -rf "$APP_DIR" || true
}

ensure_dirs(){
  mkdir -p "$APP_DIR" "$BACKUP_DIR"
  cd "$APP_DIR"
  mkdir -p app/{educms,accounts,courses,settingsapp,payments,tickets,dashboard} \
           app/templates/{accounts,courses,orders,tickets,settings,dashboard,wallet,invoices,partials} \
           app/static app/media nginx certbot/www
}

write_env(){
  local secret; secret="$(openssl rand -hex 32)"
  cat > "$ENV_FILE" <<ENV
DOMAIN=${DOMAIN}
LE_EMAIL=${LE_EMAIL}
ADMIN_PATH=${ADMIN_PATH}

DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}

ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}

DJANGO_SECRET_KEY=${secret}
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=${DOMAIN}
CSRF_TRUSTED_ORIGINS=https://${DOMAIN}
INITIAL_ADMIN_PATH=${ADMIN_PATH}
ENV
  chmod 600 "$ENV_FILE"
}

write_compose(){
  cat > docker-compose.yml <<'YML'
services:
  db:
    image: mysql:8.0
    command: --default-authentication-plugin=mysql_native_password --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    env_file: ./.env
    environment:
      MYSQL_DATABASE: ${DB_NAME}
      MYSQL_USER: ${DB_USER}
      MYSQL_PASSWORD: ${DB_PASS}
      MYSQL_ROOT_PASSWORD: ${DB_PASS}
    volumes: [db_data:/var/lib/mysql]
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p$${MYSQL_ROOT_PASSWORD} --silent"]
      interval: 5s
      timeout: 3s
      retries: 40
      start_period: 20s

  web:
    build: ./app
    env_file: ./.env
    environment:
      DJANGO_SECRET_KEY: ${DJANGO_SECRET_KEY}
      DJANGO_DEBUG: ${DJANGO_DEBUG}
      DJANGO_ALLOWED_HOSTS: ${DJANGO_ALLOWED_HOSTS}
      CSRF_TRUSTED_ORIGINS: ${CSRF_TRUSTED_ORIGINS}
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASSWORD: ${DB_PASS}
      DB_HOST: db
      DB_PORT: "3306"
      ADMIN_USERNAME: ${ADMIN_USER}
      ADMIN_PASSWORD: ${ADMIN_PASS}
      ADMIN_EMAIL: ${LE_EMAIL}
      INITIAL_ADMIN_PATH: ${INITIAL_ADMIN_PATH}
    volumes:
      - ./app/media:/app/media
      - ./app/staticfiles:/app/staticfiles
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

  nginx:
    image: nginx:alpine
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./app/staticfiles:/var/www/static:ro
      - ./app/media:/var/www/media:ro
      - ./certbot/www:/var/www/certbot:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    ports: ["80:80","443:443"]
    depends_on: [web]
    restart: unless-stopped

volumes: { db_data: {} }
YML
  docker compose -f docker-compose.yml config >/dev/null
}

write_nginx_http(){
  cat > nginx/nginx.conf <<NGINX
server {
  listen 80;
  server_name ${DOMAIN};

  location /.well-known/acme-challenge/ { root /var/www/certbot; }

  client_max_body_size 2000M;

  location /static/ { alias /var/www/static/; }
  location /media/  { alias /var/www/media/; }

  location / {
    proxy_pass http://web:8000;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
NGINX
}

write_nginx_https(){
  cat > nginx/nginx.conf <<NGINX
server {
  listen 80;
  server_name ${DOMAIN};
  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl http2;
  server_name ${DOMAIN};

  ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

  ssl_session_timeout 1d;
  ssl_session_cache shared:SSL:10m;
  ssl_session_tickets off;
  ssl_protocols TLSv1.2 TLSv1.3;

  client_max_body_size 2000M;

  location /static/ { alias /var/www/static/; }
  location /media/  { alias /var/www/media/; }

  location / {
    proxy_pass http://web:8000;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
NGINX
}

write_project(){
  cat > app/Dockerfile <<'DOCKER'
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gcc pkg-config gettext locales default-libmysqlclient-dev libmariadb-dev \
    && sed -i 's/^# *fa_IR.UTF-8 UTF-8/fa_IR.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=fa_IR.UTF-8 LC_ALL=fa_IR.UTF-8
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY . /app
CMD ["/app/entrypoint.sh"]
DOCKER

  cat > app/requirements.txt <<'REQ'
Django>=5.0,<6.0
gunicorn>=21.2
mysqlclient>=2.2
Pillow>=10.0
REQ

  cat > app/manage.py <<'PY'
import os, sys
def main():
    os.environ.setdefault("DJANGO_SETTINGS_MODULE","educms.settings")
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
if __name__ == "__main__":
    main()
PY
  cat > app/educms/__init__.py <<'PY'
PY
  cat > app/accounts/__init__.py <<'PY'
PY
  cat > app/courses/__init__.py <<'PY'
PY
  cat > app/settingsapp/__init__.py <<'PY'
PY
  cat > app/payments/__init__.py <<'PY'
PY
  cat > app/tickets/__init__.py <<'PY'
PY
  cat > app/dashboard/__init__.py <<'PY'
PY
  cat > app/educms/wsgi.py <<'PY'
import os
from django.core.wsgi import get_wsgi_application
os.environ.setdefault("DJANGO_SETTINGS_MODULE","educms.settings")
application = get_wsgi_application()
PY

  cat > app/educms/settings.py <<'PY'
from pathlib import Path
import os

BASE_DIR = Path(__file__).resolve().parent.parent
SECRET_KEY = os.getenv("DJANGO_SECRET_KEY","dev-secret")
DEBUG = os.getenv("DJANGO_DEBUG","False").lower()=="true"
ALLOWED_HOSTS = [h.strip() for h in os.getenv("DJANGO_ALLOWED_HOSTS","localhost").split(",") if h.strip()]

INSTALLED_APPS = [
  "django.contrib.admin","django.contrib.auth","django.contrib.contenttypes","django.contrib.sessions",
  "django.contrib.messages","django.contrib.staticfiles",
  "accounts.apps.AccountsConfig",
  "courses.apps.CoursesConfig",
  "settingsapp.apps.SettingsappConfig",
  "payments.apps.PaymentsConfig",
  "tickets.apps.TicketsConfig",
  "dashboard.apps.DashboardConfig",
]

MIDDLEWARE = [
  "django.middleware.security.SecurityMiddleware",
  "django.contrib.sessions.middleware.SessionMiddleware",
  "django.middleware.locale.LocaleMiddleware",
  "settingsapp.middleware.AdminAliasMiddleware",
  "django.middleware.common.CommonMiddleware",
  "django.middleware.csrf.CsrfViewMiddleware",
  "django.contrib.auth.middleware.AuthenticationMiddleware",
  "django.contrib.messages.middleware.MessageMiddleware",
  "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "educms.urls"
TEMPLATES = [{
  "BACKEND":"django.template.backends.django.DjangoTemplates",
  "DIRS":[BASE_DIR/"templates"],
  "APP_DIRS":True,
  "OPTIONS":{"context_processors":[
    "django.template.context_processors.request",
    "django.contrib.auth.context_processors.auth",
    "django.contrib.messages.context_processors.messages",
    "settingsapp.context_processors.site_context",
  ]},
}]
WSGI_APPLICATION = "educms.wsgi.application"

DATABASES = {"default":{
  "ENGINE":"django.db.backends.mysql",
  "NAME":os.getenv("DB_NAME"),
  "USER":os.getenv("DB_USER"),
  "PASSWORD":os.getenv("DB_PASSWORD"),
  "HOST":os.getenv("DB_HOST","db"),
  "PORT":os.getenv("DB_PORT","3306"),
  "OPTIONS":{"charset":"utf8mb4"},
}}

AUTH_USER_MODEL = "accounts.User"

AUTHENTICATION_BACKENDS = ["accounts.backends.EmailOrUsernameBackend"]

LANGUAGE_CODE = "fa"
USE_I18N = True
LANGUAGES = [("fa","فارسی")]
TIME_ZONE = "Asia/Tehran"
USE_TZ = True

STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR/"staticfiles"
MEDIA_URL = "/media/"
MEDIA_ROOT = BASE_DIR/"media"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

_csrf = os.getenv("CSRF_TRUSTED_ORIGINS","")
CSRF_TRUSTED_ORIGINS = [o.strip() for o in _csrf.split(",") if o.strip()]

LOGIN_URL = "/accounts/login/"
LOGIN_REDIRECT_URL = "/dashboard/"
LOGOUT_REDIRECT_URL = "/"

SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO","https")
CSRF_COOKIE_SECURE = True
SESSION_COOKIE_SECURE = True
SECURE_CONTENT_TYPE_NOSNIFF = True
SECURE_REFERRER_POLICY = "same-origin"
X_FRAME_OPTIONS = "SAMEORIGIN"
PY

  cat > app/educms/urls.py <<'PY'
from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from settingsapp.admin_views import admin_account_in_admin
from courses.views import CourseListView, CourseDetailView

urlpatterns = [
  path("admin/account/", admin.site.admin_view(admin_account_in_admin), name="admin_account_in_admin"),
  path("admin/", admin.site.urls),

  path("accounts/", include("accounts.urls")),
  path("orders/", include("payments.urls")),
  path("wallet/", include("payments.wallet_urls")),
  path("invoices/", include("payments.invoice_urls")),
  path("tickets/", include("tickets.urls")),
  path("panel/", include("settingsapp.urls")),
  path("dashboard/", include("dashboard.urls")),

  path("", CourseListView.as_view(), name="home"),
  path("courses/<slug:slug>/", CourseDetailView.as_view(), name="course_detail"),
]
if settings.DEBUG:
  urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
PY

  cat > app/accounts/apps.py <<'PY'
from django.apps import AppConfig
class AccountsConfig(AppConfig):
  default_auto_field="django.db.models.BigAutoField"
  name="accounts"
  verbose_name="کاربران"
PY
  cat > app/accounts/models.py <<'PY'
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
PY
  cat > app/accounts/admin.py <<'PY'
from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from .models import User, UserProfile, SecurityQuestion

class UserProfileInline(admin.StackedInline):
    model = UserProfile
    extra = 0
    can_delete = False

@admin.register(User)
class UserAdmin(BaseUserAdmin):
    list_display = ("email","is_staff","is_superuser","is_active","date_joined")
    list_filter = ("is_staff","is_superuser","is_active","groups")
    search_fields = ("email","username")
    ordering = ("email",)
    inlines = [UserProfileInline]

    fieldsets = (
        (None, {"fields": ("email","password")}),
        ("اطلاعات پایه", {"fields": ("username","first_name","last_name","is_active")}),
        ("دسترسی‌ها", {"fields": ("is_staff","is_superuser","groups","user_permissions")}),
        ("زمان‌ها", {"fields": ("last_login","date_joined")}),
    )
    add_fieldsets = (
        (None, {"classes": ("wide",), "fields": ("email","username","password1","password2")}),
    )

@admin.register(SecurityQuestion)
class SecurityQuestionAdmin(admin.ModelAdmin):
    list_display = ("id","text","is_active")
    list_filter = ("is_active",)
    search_fields = ("text",)

@admin.register(UserProfile)
class UserProfileAdmin(admin.ModelAdmin):
    list_display = ("user","phone","q1","q2","has_extra_data","updated_at")
    list_select_related = ("user","q1","q2")
    search_fields = ("user__email","user__username","phone")
    readonly_fields = ("extra_data_display",)

    def has_extra_data(self, obj):
        return bool(obj.extra_data)
    has_extra_data.boolean = True
    has_extra_data.short_description = "داده اضافی"

    def extra_data_display(self, obj):
        if not obj.extra_data:
            return "-"
        from django.utils.html import format_html
        lines = [f"<b>{k}:</b> {v}" for k, v in obj.extra_data.items()]
        return format_html("<br>".join(lines))
    extra_data_display.short_description = "داده‌های اضافی"

PY
  cat > app/accounts/forms.py <<'PY'
from django import forms
from django.contrib.auth import get_user_model
from django.contrib.auth.forms import AuthenticationForm, UserCreationForm
from django.contrib.auth.hashers import make_password
from django.utils.translation import gettext_lazy as _

from .models import UserProfile, SecurityQuestion

User = get_user_model()

_INPUT = "w-full rounded-xl border border-slate-200 bg-white px-3 py-2 outline-none focus:ring-2 focus:ring-slate-300 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700"

def get_registration_fields():
    """Get active registration fields from database"""
    try:
        from settingsapp.models import RegistrationField
        return list(RegistrationField.objects.filter(is_active=True).order_by("order", "id"))
    except Exception:
        return []

def build_form_field(reg_field):
    """Build a Django form field from a RegistrationField model instance"""
    attrs = {"class": _INPUT}
    if reg_field.placeholder:
        attrs["placeholder"] = reg_field.placeholder
    if reg_field.field_type in ("email", "phone", "password", "text"):
        attrs["dir"] = "ltr"

    field_kwargs = {
        "label": reg_field.label,
        "required": reg_field.is_required,
        "help_text": reg_field.help_text or "",
    }

    if reg_field.field_type == "text":
        return forms.CharField(widget=forms.TextInput(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "email":
        attrs["autocomplete"] = "email"
        return forms.EmailField(widget=forms.EmailInput(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "phone":
        attrs["autocomplete"] = "tel"
        return forms.CharField(widget=forms.TextInput(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "textarea":
        attrs["rows"] = 3
        return forms.CharField(widget=forms.Textarea(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "select":
        choices = [("", _("انتخاب کنید"))] + [(c, c) for c in reg_field.get_choices_list()]
        return forms.ChoiceField(choices=choices, widget=forms.Select(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "checkbox":
        return forms.BooleanField(widget=forms.CheckboxInput(attrs={"class": "rounded"}), **field_kwargs)
    elif reg_field.field_type == "password":
        attrs["autocomplete"] = "new-password"
        return forms.CharField(widget=forms.PasswordInput(attrs=attrs), **field_kwargs)
    else:
        return forms.CharField(widget=forms.TextInput(attrs=attrs), **field_kwargs)

class LoginForm(AuthenticationForm):
    username = forms.CharField(
        label=_("ایمیل"),
        widget=forms.TextInput(attrs={"class": _INPUT, "autocomplete":"email", "dir":"ltr"})
    )
    password = forms.CharField(
        label=_("گذرواژه"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete":"current-password", "dir":"ltr"})
    )

class RegisterForm(UserCreationForm):
    email = forms.EmailField(
        label=_("ایمیل"),
        widget=forms.EmailInput(attrs={"class": _INPUT, "autocomplete":"email", "dir":"ltr"})
    )

    security_question = forms.ModelChoiceField(
        queryset=SecurityQuestion.objects.filter(is_active=True).order_by("order","text"),
        required=True,
        empty_label=_("انتخاب کنید"),
        label=_("سوال امنیتی"),
        widget=forms.Select(attrs={"class": _INPUT})
    )
    security_answer = forms.CharField(
        required=True,
        label=_("پاسخ سوال امنیتی"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete":"off"})
    )

    password1 = forms.CharField(
        label=_("گذرواژه"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete":"new-password", "dir":"ltr"})
    )
    password2 = forms.CharField(
        label=_("تکرار گذرواژه"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete":"new-password", "dir":"ltr"})
    )

    class Meta:
        model = User
        fields = ("email",)

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._dynamic_fields = []

        # Add dynamic fields from RegistrationField model
        try:
            for reg_field in get_registration_fields():
                # Skip system fields that are already defined
                if reg_field.field_key in ("email", "password1", "password2", "security_question", "security_answer"):
                    continue
                field = build_form_field(reg_field)
                self.fields[f"custom_{reg_field.field_key}"] = field
                self._dynamic_fields.append(reg_field.field_key)
        except Exception:
            pass  # Database might not be ready during migrations

        # Reorder fields
        ordered = ["email", "security_question", "security_answer", "password1", "password2"]
        for key in self._dynamic_fields:
            ordered.append(f"custom_{key}")
        self.order_fields(ordered)

    def clean_email(self):
        e = (self.cleaned_data.get("email") or "").strip().lower()
        if not e:
            raise forms.ValidationError(_("ایمیل الزامی است."))
        if User.objects.filter(email__iexact=e).exists():
            raise forms.ValidationError(_("این ایمیل قبلاً ثبت شده است."))
        return e

    def clean_security_answer(self):
        a = (self.cleaned_data.get("security_answer") or "").strip()
        if len(a) < 2:
            raise forms.ValidationError(_("پاسخ کوتاه است."))
        return a

    def get_custom_field_data(self):
        """Return a dict of custom field values"""
        data = {}
        for key in self._dynamic_fields:
            field_name = f"custom_{key}"
            if field_name in self.cleaned_data:
                data[key] = self.cleaned_data[field_name]
        return data

    def save(self, commit=True):
        user = super().save(commit=False)
        user.email = (self.cleaned_data.get("email") or "").strip().lower()
        if commit:
            user.save()
            prof, _ = UserProfile.objects.get_or_create(user=user)
            prof.q1 = self.cleaned_data.get("security_question")
            ans = (self.cleaned_data.get("security_answer") or "").strip().lower()
            prof.a1_hash = make_password(ans)

            # Save custom fields to profile extra_data
            custom_data = self.get_custom_field_data()
            if custom_data:
                prof.extra_data = custom_data
            prof.save()
        return user

class ProfileForm(forms.ModelForm):
    class Meta:
        model = User
        fields = ("first_name", "last_name", "email")
        widgets = {
            "first_name": forms.TextInput(attrs={"class": _INPUT}),
            "last_name": forms.TextInput(attrs={"class": _INPUT}),
            "email": forms.EmailInput(attrs={"class": _INPUT, "dir": "ltr"}),
        }

    def __init__(self, *args, profile=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.profile = profile
        self._dynamic_fields = []

        # Add dynamic fields that should show in profile
        try:
            for reg_field in get_registration_fields():
                if not reg_field.show_in_profile:
                    continue
                if reg_field.field_key in ("email", "password1", "password2", "security_question", "security_answer"):
                    continue
                field = build_form_field(reg_field)
                field_name = f"custom_{reg_field.field_key}"
                self.fields[field_name] = field
                self._dynamic_fields.append(reg_field.field_key)

                # Set initial value from profile extra_data
                if profile and profile.extra_data:
                    if reg_field.field_key in profile.extra_data:
                        self.initial[field_name] = profile.extra_data[reg_field.field_key]
        except Exception:
            pass

    def get_custom_field_data(self):
        """Return a dict of custom field values"""
        data = {}
        for key in self._dynamic_fields:
            field_name = f"custom_{key}"
            if field_name in self.cleaned_data:
                data[key] = self.cleaned_data[field_name]
        return data

class SecurityQuestionsForm(forms.Form):
    q1 = forms.ModelChoiceField(
        queryset=SecurityQuestion.objects.filter(is_active=True).order_by("order", "text"),
        required=True,
        label=_("سوال امنیتی ۱"),
        widget=forms.Select(attrs={"class": _INPUT})
    )
    a1 = forms.CharField(
        required=True,
        label=_("پاسخ سوال ۱"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete": "off"})
    )
    q2 = forms.ModelChoiceField(
        queryset=SecurityQuestion.objects.filter(is_active=True).order_by("order", "text"),
        required=True,
        label=_("سوال امنیتی ۲"),
        widget=forms.Select(attrs={"class": _INPUT})
    )
    a2 = forms.CharField(
        required=True,
        label=_("پاسخ سوال ۲"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete": "off"})
    )

    def __init__(self, *args, user=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.user = user

    def clean(self):
        c = super().clean()
        q1 = c.get("q1")
        q2 = c.get("q2")
        if q1 and q2 and q1 == q2:
            raise forms.ValidationError(_("سوالات امنیتی باید متفاوت باشند."))
        return c

class ResetStep1Form(forms.Form):
    identifier = forms.CharField(
        label=_("ایمیل یا نام کاربری"),
        widget=forms.TextInput(attrs={"class": _INPUT, "dir": "ltr", "autocomplete": "username"})
    )

class ResetStep2Form(forms.Form):
    a1 = forms.CharField(
        label=_("پاسخ سوال ۱"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete": "off"})
    )
    a2 = forms.CharField(
        label=_("پاسخ سوال ۲"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete": "off"})
    )
    new_password1 = forms.CharField(
        label=_("رمز جدید"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete": "new-password", "dir": "ltr"})
    )
    new_password2 = forms.CharField(
        label=_("تکرار رمز جدید"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete": "new-password", "dir": "ltr"})
    )

    def clean(self):
        c = super().clean()
        p1 = c.get("new_password1")
        p2 = c.get("new_password2")
        if p1 and p2 and p1 != p2:
            raise forms.ValidationError(_("رمزها یکسان نیستند."))
        return c
PY

  cat > app/accounts/backends.py <<'PY'
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
PY


  cat > app/accounts/views.py <<'PY'
from django.contrib.auth.views import LoginView, LogoutView
from django.views.generic import CreateView
from django.urls import reverse_lazy
from django.contrib import messages
from django.shortcuts import redirect, render
from django.contrib.auth.decorators import login_required
from django.contrib.auth import get_user_model
from .forms import RegisterForm, LoginForm, ProfileForm, SecurityQuestionsForm, ResetStep1Form, ResetStep2Form
from .models import UserProfile

User = get_user_model()

class SiteLoginView(LoginView):
  template_name="accounts/login.html"
  authentication_form=LoginForm

class SiteLogoutView(LogoutView):
  http_method_names=["post"]
  next_page="/"

class RegisterView(CreateView):
  form_class=RegisterForm
  template_name="accounts/register.html"
  success_url=reverse_lazy("login")

@login_required
def profile_edit(request):
  from settingsapp.models import SiteSetting
  site_setting = SiteSetting.objects.first()
  allow_edit = site_setting.allow_profile_edit if site_setting else True

  if not allow_edit:
    messages.error(request, "ویرایش پروفایل توسط مدیر غیرفعال شده است.")
    return render(request, "accounts/profile.html", {"form": None, "profile": None, "allow_edit": False})

  profile, _ = UserProfile.objects.get_or_create(user=request.user)
  form = ProfileForm(request.POST or None, instance=request.user, profile=profile)

  if request.method == "POST" and form.is_valid():
    form.save()
    profile.phone = (request.POST.get("phone") or "").strip()
    profile.bio = (request.POST.get("bio") or "").strip()

    # Save custom field data
    custom_data = form.get_custom_field_data()
    if custom_data:
      if not profile.extra_data:
        profile.extra_data = {}
      profile.extra_data.update(custom_data)

    profile.save(update_fields=["phone", "bio", "extra_data", "updated_at"])
    messages.success(request, "پروفایل بروزرسانی شد.")
    return redirect("profile_edit")

  return render(request, "accounts/profile.html", {"form": form, "profile": profile, "allow_edit": True})

@login_required
def security_questions(request):
  profile,_ = UserProfile.objects.get_or_create(user=request.user)
  init={}
  if profile.q1: init["q1"]=profile.q1
  if profile.q2: init["q2"]=profile.q2
  form = SecurityQuestionsForm(request.POST or None, user=request.user, initial=init)
  if request.method=="POST" and form.is_valid():
    profile.q1=form.cleaned_data["q1"]; profile.q2=form.cleaned_data["q2"]
    profile.set_answers(form.cleaned_data["a1"], form.cleaned_data["a2"])
    profile.save(update_fields=["q1","q2","a1_hash","a2_hash"])
    messages.success(request,"سوالات امنیتی بروزرسانی شد.")
    return redirect("security_questions")
  return render(request,"accounts/security_questions.html",{"form":form})

def reset_step1(request):
  form=ResetStep1Form(request.POST or None)
  if request.method=="POST" and form.is_valid():
    ident=(form.cleaned_data["identifier"] or "").strip()
    user = User.objects.filter(username__iexact=ident).first() or User.objects.filter(email__iexact=ident).first()
    if not user:
      messages.error(request,"کاربر پیدا نشد.")
      return redirect("reset_step1")
    profile = UserProfile.objects.filter(user=user).select_related("q1","q2").first()
    if not profile or not (profile.q1 and profile.q2 and profile.a1_hash and profile.a2_hash):
      messages.error(request,"برای این کاربر سوالات امنیتی تنظیم نشده است.")
      return redirect("reset_step1")
    request.session["reset_user_id"]=str(user.id)
    return redirect("reset_step2")
  return render(request,"accounts/reset_step1.html",{"form":form})

def reset_step2(request):
  uid=request.session.get("reset_user_id")
  if not uid: return redirect("reset_step1")
  user=User.objects.filter(id=uid).first()
  if not user:
    request.session.pop("reset_user_id",None); return redirect("reset_step1")
  profile=UserProfile.objects.filter(user=user).select_related("q1","q2").first()
  if not profile or not (profile.q1 and profile.q2):
    request.session.pop("reset_user_id",None); return redirect("reset_step1")
  form=ResetStep2Form(request.POST or None)
  if request.method=="POST" and form.is_valid():
    if not profile.check_answers(form.cleaned_data["a1"], form.cleaned_data["a2"]):
      messages.error(request,"پاسخ‌ها صحیح نیست.")
      return redirect("reset_step2")
    user.set_password(form.cleaned_data["new_password1"]); user.save(update_fields=["password"])
    request.session.pop("reset_user_id",None)
    messages.success(request,"رمز تغییر کرد. وارد شوید.")
    return redirect("login")
  return render(request,"accounts/reset_step2.html",{"form":form,"q1":profile.q1.text,"q2":profile.q2.text,"username":user.username})
PY

  cat > app/accounts/urls.py <<'PY'
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
PY

  cat > app/settingsapp/apps.py <<'PY'
from django.apps import AppConfig
class SettingsappConfig(AppConfig):
  default_auto_field="django.db.models.BigAutoField"
  name="settingsapp"
  verbose_name="تنظیمات سایت"
PY
  cat > app/settingsapp/models.py <<'PY'
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
PY
  cat > app/settingsapp/admin.py <<'PY'
from django.contrib import admin
from django.contrib import messages
from django.utils.translation import gettext_lazy as _
from .models import SiteSetting, TemplateText, NavLink, RegistrationField

admin.site.site_header="پنل مدیریت"
admin.site.site_title="پنل مدیریت"
admin.site.index_title="مدیریت سایت"

@admin.register(SiteSetting)
class SiteSettingAdmin(admin.ModelAdmin):
    list_display = ("brand_name", "default_theme", "allow_profile_edit", "admin_path", "updated_at")
    fieldsets = (
        (_("برند"), {"fields": ("brand_name", "logo", "favicon")}),
        (_("ظاهر"), {"fields": ("default_theme", "footer_text")}),
        (_("تنظیمات کاربران"), {"fields": ("allow_profile_edit",)}),
        (_("امنیت"), {"fields": ("admin_path",)}),
    )

@admin.register(RegistrationField)
class RegistrationFieldAdmin(admin.ModelAdmin):
    list_display = ("label", "field_key", "field_type", "is_required", "is_active", "is_system", "show_in_profile", "order")
    list_filter = ("field_type", "is_required", "is_active", "is_system", "show_in_profile")
    list_editable = ("order", "is_required", "show_in_profile")
    search_fields = ("field_key", "label")
    ordering = ("order", "id")
    fieldsets = (
        (None, {"fields": ("field_key", "label", "field_type")}),
        (_("تنظیمات فیلد"), {"fields": ("placeholder", "help_text", "choices")}),
        (_("وضعیت"), {"fields": ("is_required", "is_active", "is_system", "show_in_profile", "order")}),
    )

    def get_readonly_fields(self, request, obj=None):
        if obj and obj.is_system:
            return ("field_key", "is_system", "is_active")
        return ("is_system",)

    def has_delete_permission(self, request, obj=None):
        if obj and obj.is_system:
            return False
        return super().has_delete_permission(request, obj)

    def save_model(self, request, obj, form, change):
        if obj.is_system:
            obj.is_active = True
        super().save_model(request, obj, form, change)

admin.site.register(TemplateText)
admin.site.register(NavLink)
PY
  cat > app/settingsapp/context_processors.py <<'PY'
from .models import SiteSetting, TemplateText, NavLink
def site_context(request):
  try:
    s = SiteSetting.objects.first()
    texts = {t.key: t.value for t in TemplateText.objects.all()}
    header_links = list(NavLink.objects.filter(area="header", is_active=True).order_by("order"))
    footer_links = list(NavLink.objects.filter(area="footer", is_active=True).order_by("order"))
  except Exception:
    s = None
    texts = {}
    header_links = []
    footer_links = []
  return {"site_settings": s, "tpl": texts, "header_links": header_links, "footer_links": footer_links}
PY
  cat > app/settingsapp/forms.py <<'PY'
from django import forms
import re
_INPUT="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 outline-none focus:ring-2 focus:ring-slate-300 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700"
class AdminPathForm(forms.Form):
  admin_path=forms.CharField(max_length=50, widget=forms.TextInput(attrs={"class":_INPUT,"dir":"ltr"}))
  def clean_admin_path(self):
    v=(self.cleaned_data.get("admin_path") or "").strip().strip("/") or "admin"
    if not re.fullmatch(r"[-A-Za-z0-9_]+", v):
      raise forms.ValidationError("مسیر نامعتبر است. فقط A-Z a-z 0-9 _ -")
    return v
class AdminAccountForm(forms.Form):
  username=forms.CharField(max_length=150, widget=forms.TextInput(attrs={"class":_INPUT}))
  password1=forms.CharField(widget=forms.PasswordInput(attrs={"class":_INPUT}))
  password2=forms.CharField(widget=forms.PasswordInput(attrs={"class":_INPUT}))
  def clean(self):
    c=super().clean()
    if c.get("password1")!=c.get("password2"):
      raise forms.ValidationError("رمزها یکسان نیستند.")
    return c
PY
  cat > app/settingsapp/views.py <<'PY'
from django.contrib.admin.views.decorators import staff_member_required
from django.contrib import messages
from django.shortcuts import render, redirect
from django.core.cache import cache
from .forms import AdminPathForm
from .models import SiteSetting

@staff_member_required
def admin_path_settings(request):
  s = SiteSetting.objects.first() or SiteSetting.objects.create()
  form = AdminPathForm(request.POST or None, initial={"admin_path": s.admin_path})
  if request.method=="POST" and form.is_valid():
    s.admin_path=form.cleaned_data["admin_path"]; s.save(update_fields=["admin_path"])
    cache.delete("site_admin_path")
    messages.success(request,f"مسیر ادمین تغییر کرد: /{s.admin_path}/")
    return redirect("admin_path_settings")
  return render(request,"settings/admin_path.html",{"form":form,"current":s.admin_path})
PY
  cat > app/settingsapp/urls.py <<'PY'
from django.urls import path
from .views import admin_path_settings
urlpatterns=[path("admin-path/", admin_path_settings, name="admin_path_settings")]
PY
  cat > app/settingsapp/admin_views.py <<'PY'
from django.contrib.admin.views.decorators import staff_member_required
from django.contrib.auth import update_session_auth_hash
from django.contrib import messages
from django.shortcuts import render, redirect
from .forms import AdminAccountForm

@staff_member_required
def admin_account_in_admin(request):
  form = AdminAccountForm(request.POST or None, initial={"username": request.user.username})
  if request.method=="POST" and form.is_valid():
    u=request.user
    u.username=form.cleaned_data["username"]
    u.set_password(form.cleaned_data["password1"])
    u.save()
    update_session_auth_hash(request,u)
    messages.success(request,"نام کاربری/رمز ادمین تغییر کرد.")
    return redirect("/admin/")
  return render(request,"settings/admin_account.html",{"form":form})
PY
  cat > app/settingsapp/middleware.py <<'PY'
from django.http import HttpResponseNotFound
from django.utils.deprecation import MiddlewareMixin
from django.core.cache import cache
from .models import SiteSetting

def _get_admin_path():
  key="site_admin_path"
  v=cache.get(key)
  if v: return v
  s=SiteSetting.objects.first()
  v=(getattr(s,"admin_path",None) or "admin").strip().strip("/") or "admin"
  cache.set(key,v,60)
  return v

class AdminAliasMiddleware(MiddlewareMixin):
  def process_request(self, request):
    admin_path=(_get_admin_path() or "admin").strip().strip("/") or "admin"
    ap=admin_path.lower()
    p=(request.path or "/"); pl=p.lower()
    if ap!="admin" and pl.startswith("/admin"):
      return HttpResponseNotFound("Not Found")
    if pl==f"/{ap}":
      request.path_info="/admin/"; return None
    pref=f"/{ap}/"
    if pl.startswith(pref):
      request.path_info="/admin/"+p[len(pref):]
    return None
PY

  cat > app/courses/apps.py <<'PY'
from django.apps import AppConfig
class CoursesConfig(AppConfig):
  default_auto_field="django.db.models.BigAutoField"
  name="courses"
  verbose_name="دوره‌ها"
PY
  cat > app/courses/models.py <<'PY'
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
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
  course=models.ForeignKey(Course, on_delete=models.CASCADE)
  is_active=models.BooleanField(default=True)
  source=models.CharField(max_length=30, default="paid")
  created_at=models.DateTimeField(auto_now_add=True)
  class Meta:
    unique_together=[("user","course")]

class CourseGrant(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
  course=models.ForeignKey(Course, on_delete=models.CASCADE)
  is_active=models.BooleanField(default=True)
  reason=models.CharField(max_length=200, blank=True)
  class Meta:
    unique_together=[("user","course")]
PY
  cat > app/courses/access.py <<'PY'
from .models import Enrollment, CourseGrant
def user_has_course_access(user, course):
  if course.is_free_for_all: return True
  if not user.is_authenticated: return False
  if Enrollment.objects.filter(user=user, course=course, is_active=True).exists(): return True
  if CourseGrant.objects.filter(user=user, course=course, is_active=True).exists(): return True
  return False
PY
  cat > app/courses/admin.py <<'PY'
from django.contrib import admin
from .models import Course, Enrollment, CourseGrant
admin.site.register(Course)
admin.site.register(Enrollment)
admin.site.register(CourseGrant)
PY
  cat > app/courses/views.py <<'PY'
from django.views.generic import ListView, DetailView
from .models import Course, PublishStatus
from .access import user_has_course_access

class CourseListView(ListView):
  template_name="courses/list.html"
  paginate_by=12
  def get_queryset(self):
    return Course.objects.filter(status=PublishStatus.PUBLISHED).order_by("-updated_at")

class CourseDetailView(DetailView):
  template_name="courses/detail.html"
  model=Course
  slug_field="slug"
  slug_url_kwarg="slug"
  def get_queryset(self):
    return Course.objects.filter(status=PublishStatus.PUBLISHED)
  def get_context_data(self,**k):
    ctx=super().get_context_data(**k)
    ctx["has_access"]=user_has_course_access(self.request.user, self.object)
    return ctx
PY

  cat > app/dashboard/apps.py <<'PY'
from django.apps import AppConfig
class DashboardConfig(AppConfig):
  default_auto_field="django.db.models.BigAutoField"
  name="dashboard"
  verbose_name="داشبورد"
PY
  cat > app/dashboard/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.shortcuts import render
from courses.models import Enrollment
from payments.models import Order, Wallet
from tickets.models import Ticket

@login_required
def dashboard_home(request):
  enrollments = Enrollment.objects.filter(user=request.user, is_active=True).select_related("course").order_by("-created_at")[:12]
  orders = Order.objects.filter(user=request.user).select_related("course").order_by("-created_at")[:10]
  tickets = Ticket.objects.filter(user=request.user).order_by("-created_at")[:10]
  wallet,_ = Wallet.objects.get_or_create(user=request.user)
  return render(request,"dashboard/home.html",{"enrollments":enrollments,"orders":orders,"tickets":tickets,"wallet":wallet})
PY
  cat > app/dashboard/urls.py <<'PY'
from django.urls import path
from .views import dashboard_home
urlpatterns=[path("", dashboard_home, name="dashboard_home")]
PY

  cat > app/payments/apps.py <<'PY'
from django.apps import AppConfig
class PaymentsConfig(AppConfig):
  default_auto_field="django.db.models.BigAutoField"
  name="payments"
  verbose_name="پرداخت‌ها"
PY
  cat > app/payments/models.py <<'PY'
import uuid
from django.db import models, transaction
from django.conf import settings
from django.utils import timezone
from django.db.models import F
from django.utils.translation import gettext_lazy as _
from courses.models import Course

class BankTransferSetting(models.Model):
  account_holder=models.CharField(max_length=120, blank=True)
  card_number=models.CharField(max_length=30, blank=True)
  note=models.TextField(blank=True)
  first_purchase_percent=models.PositiveIntegerField(default=0)
  first_purchase_amount=models.PositiveIntegerField(default=0)
  updated_at=models.DateTimeField(auto_now=True)
  class Meta:
    verbose_name=_("تنظیمات کارت‌به‌کارت"); verbose_name_plural=_("تنظیمات کارت‌به‌کارت")

class CouponType(models.TextChoices):
  PERCENT="percent",_("درصدی")
  AMOUNT="amount",_("مبلغی")

class Coupon(models.Model):
  code=models.CharField(max_length=40, unique=True)
  type=models.CharField(max_length=10, choices=CouponType.choices, default=CouponType.PERCENT)
  value=models.PositiveIntegerField()
  is_active=models.BooleanField(default=True)
  start_at=models.DateTimeField(blank=True, null=True)
  end_at=models.DateTimeField(blank=True, null=True)
  max_uses=models.PositiveIntegerField(default=0)
  max_uses_per_user=models.PositiveIntegerField(default=0)
  min_amount=models.PositiveIntegerField(default=0)
  def is_valid_now(self):
    now=timezone.now()
    if not self.is_active: return False
    if self.start_at and now<self.start_at: return False
    if self.end_at and now>self.end_at: return False
    return True
  class Meta:
    verbose_name=_("کد تخفیف"); verbose_name_plural=_("کدهای تخفیف")

class OrderStatus(models.TextChoices):
  PENDING_PAYMENT="pending_payment",_("در انتظار پرداخت")
  PENDING_VERIFY="pending_verify",_("در انتظار تایید")
  PAID="paid",_("پرداخت شده")
  REJECTED="rejected",_("رد شده")
  CANCELED="canceled",_("لغو شده")

class Order(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
  course=models.ForeignKey(Course, on_delete=models.PROTECT)
  amount=models.PositiveIntegerField()
  discount_amount=models.PositiveIntegerField(default=0)
  final_amount=models.PositiveIntegerField(default=0)
  coupon=models.ForeignKey(Coupon, on_delete=models.SET_NULL, null=True, blank=True)
  status=models.CharField(max_length=30, choices=OrderStatus.choices, default=OrderStatus.PENDING_PAYMENT)
  receipt_image=models.ImageField(upload_to="receipts/", blank=True, null=True)
  tracking_code=models.CharField(max_length=80, blank=True)
  note=models.TextField(blank=True)
  created_at=models.DateTimeField(auto_now_add=True)
  verified_at=models.DateTimeField(blank=True, null=True)
  class Meta:
    ordering=["-created_at"]; verbose_name=_("سفارش"); verbose_name_plural=_("سفارش‌ها")

class Wallet(models.Model):
  user=models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="wallet")
  balance=models.IntegerField(default=0)
  updated_at=models.DateTimeField(auto_now=True)
  class Meta:
    verbose_name=_("کیف پول"); verbose_name_plural=_("کیف پول‌ها")

class WalletTxnKind(models.TextChoices):
  TOPUP="topup",_("شارژ")
  ORDER_PAY="order_pay",_("پرداخت سفارش")
  REFUND="refund",_("بازگشت وجه")
  ADJUST="adjust",_("اصلاح")

class WalletTransaction(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  wallet=models.ForeignKey(Wallet, on_delete=models.CASCADE, related_name="txns")
  kind=models.CharField(max_length=20, choices=WalletTxnKind.choices)
  amount=models.IntegerField()
  ref_order=models.ForeignKey(Order, on_delete=models.SET_NULL, null=True, blank=True, related_name="wallet_txns")
  description=models.CharField(max_length=250, blank=True)
  created_at=models.DateTimeField(auto_now_add=True)
  class Meta:
    ordering=["-created_at"]; verbose_name=_("تراکنش کیف پول"); verbose_name_plural=_("تراکنش‌های کیف پول")

class TopUpStatus(models.TextChoices):
  PENDING="pending",_("در انتظار بررسی")
  APPROVED="approved",_("تایید شده")
  REJECTED="rejected",_("رد شده")

class WalletTopUpRequest(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="topups")
  amount=models.PositiveIntegerField()
  receipt_image=models.ImageField(upload_to="wallet/topups/", blank=True, null=True)
  tracking_code=models.CharField(max_length=80, blank=True)
  note=models.TextField(blank=True)
  status=models.CharField(max_length=20, choices=TopUpStatus.choices, default=TopUpStatus.PENDING)
  created_at=models.DateTimeField(auto_now_add=True)
  reviewed_at=models.DateTimeField(blank=True, null=True)
  class Meta:
    ordering=["-created_at"]; verbose_name=_("درخواست شارژ"); verbose_name_plural=_("درخواست‌های شارژ")

class Invoice(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  order=models.OneToOneField(Order, on_delete=models.CASCADE, related_name="invoice")
  number=models.CharField(max_length=30, unique=True, blank=True)
  issued_at=models.DateTimeField(default=timezone.now)
  billed_to=models.CharField(max_length=200, blank=True)
  billed_email=models.EmailField(blank=True)
  item_title=models.CharField(max_length=250)
  unit_price=models.PositiveIntegerField()
  discount=models.PositiveIntegerField(default=0)
  total=models.PositiveIntegerField(default=0)
  class Meta:
    ordering=["-issued_at"]; verbose_name=_("فاکتور"); verbose_name_plural=_("فاکتورها")
  def _gen(self):
    y=timezone.now().strftime("%Y")
    return f"INV-{y}-{uuid.uuid4().hex[:8].upper()}"
  def save(self,*a,**k):
    if not self.number: self.number=self._gen()
    if not self.total: self.total=max(int(self.unit_price)-int(self.discount or 0),0)
    super().save(*a,**k)

def wallet_apply(user, amount:int, kind:str, ref_order=None, description=""):
  with transaction.atomic():
    w,_ = Wallet.objects.select_for_update().get_or_create(user=user)
    w.balance = F("balance")+int(amount)
    w.save(update_fields=["balance"])
    w.refresh_from_db(fields=["balance"])
    WalletTransaction.objects.create(wallet=w, kind=kind, amount=int(amount), ref_order=ref_order, description=description)
    return w
PY

  cat > app/payments/utils.py <<'PY'
from .models import CouponType, Coupon, Order, OrderStatus
def calc_coupon_discount(coupon, base):
  if not coupon: return 0
  if coupon.type==CouponType.PERCENT:
    pct=min(max(int(coupon.value),0),100)
    return (base*pct)//100
  return min(int(coupon.value), base)

def coupon_total_uses(coupon):
  return Order.objects.filter(coupon=coupon).exclude(status=OrderStatus.CANCELED).count()

def coupon_user_uses(coupon,user):
  return Order.objects.filter(user=user, coupon=coupon).exclude(status=OrderStatus.CANCELED).count()

def validate_coupon(code,user,base):
  code=(code or "").strip()
  if not code: return None,"کدی وارد نشده."
  try:
    c=Coupon.objects.get(code__iexact=code)
  except Coupon.DoesNotExist:
    return None,"کد نامعتبر است."
  if not c.is_valid_now(): return None,"کد فعال نیست یا تاریخ آن گذشته است."
  if base < c.min_amount: return None,"این کد برای این مبلغ قابل استفاده نیست."
  if c.max_uses and coupon_total_uses(c) >= c.max_uses: return None,"سقف استفاده پر شده."
  if c.max_uses_per_user and coupon_user_uses(c,user) >= c.max_uses_per_user: return None,"سقف استفاده شما پر شده."
  return c,""
PY

  cat > app/payments/forms.py <<'PY'
from django import forms
from .models import Order, WalletTopUpRequest
_INPUT="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 outline-none focus:ring-2 focus:ring-slate-300 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700"

class ReceiptUploadForm(forms.ModelForm):
  class Meta:
    model=Order
    fields=("receipt_image","tracking_code","note")
    widgets={"tracking_code": forms.TextInput(attrs={"class":_INPUT,"dir":"ltr"}),
             "note": forms.Textarea(attrs={"class":_INPUT,"rows":3})}

class CouponApplyForm(forms.Form):
  coupon_code=forms.CharField(required=False, max_length=40, widget=forms.TextInput(attrs={"class":_INPUT,"dir":"ltr"}))

class WalletTopUpForm(forms.ModelForm):
  class Meta:
    model=WalletTopUpRequest
    fields=("amount","receipt_image","tracking_code","note")
    widgets={"amount": forms.NumberInput(attrs={"class":_INPUT,"dir":"ltr"}),
             "tracking_code": forms.TextInput(attrs={"class":_INPUT,"dir":"ltr"}),
             "note": forms.Textarea(attrs={"class":_INPUT,"rows":3})}
PY

  cat > app/payments/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.shortcuts import get_object_or_404, redirect, render
from django.contrib import messages
from django.utils import timezone
from django.db import transaction
from courses.models import Course, PublishStatus, Enrollment
from courses.access import user_has_course_access
from .models import BankTransferSetting, Order, OrderStatus, Wallet, WalletTopUpRequest, TopUpStatus, wallet_apply, Invoice
from .forms import ReceiptUploadForm, CouponApplyForm, WalletTopUpForm
from .utils import validate_coupon, calc_coupon_discount

def ensure_invoice(order:Order):
  if hasattr(order,"invoice"): return order.invoice
  return Invoice.objects.create(
    order=order,
    billed_to=(order.user.get_full_name() or order.user.username),
    billed_email=(order.user.email or ""),
    item_title=f"خرید دوره: {order.course.title}",
    unit_price=order.amount, discount=order.discount_amount, total=order.final_amount,
  )

@login_required
def checkout(request, slug):
  course=get_object_or_404(Course, slug=slug, status=PublishStatus.PUBLISHED)
  if course.is_free_for_all:
    Enrollment.objects.get_or_create(user=request.user, course=course, defaults={"is_active":True,"source":"free_all"})
    return redirect("course_detail", slug=course.slug)
  if user_has_course_access(request.user, course):
    return redirect("course_detail", slug=course.slug)

  setting=BankTransferSetting.objects.first()
  order=Order.objects.filter(user=request.user, course=course).exclude(status__in=[OrderStatus.PAID,OrderStatus.CANCELED]).first()
  if not order:
    order=Order.objects.create(user=request.user, course=course, amount=course.price_toman, discount_amount=0, final_amount=course.price_toman, status=OrderStatus.PENDING_PAYMENT)

  base=order.amount
  first_paid = Order.objects.filter(user=request.user, status=OrderStatus.PAID).count()==0
  coupon_form=CouponApplyForm(request.POST or None)
  applied=None
  if request.method=="POST" and "apply_coupon" in request.POST:
    code=(request.POST.get("coupon_code","") or "").strip()
    if code:
      applied,msg = validate_coupon(code, request.user, base)
      messages.success(request,"کد اعمال شد.") if applied else messages.error(request,msg)

  discount=0; label=""
  if applied:
    discount=calc_coupon_discount(applied, base); label=f"کد: {applied.code}"
  elif first_paid and setting:
    pct=min(max(int(setting.first_purchase_percent or 0),0),100)
    discount=max((base*pct)//100, min(int(setting.first_purchase_amount or 0), base))
    if discount>0: label="تخفیف خرید اول"

  discount=min(discount, base)
  final=max(base-discount,0)
  order.coupon=applied; order.discount_amount=discount; order.final_amount=final
  order.save(update_fields=["coupon","discount_amount","final_amount"])

  wallet,_ = Wallet.objects.get_or_create(user=request.user)

  if request.method=="POST" and "pay_wallet" in request.POST:
    if wallet.balance < final:
      messages.error(request,"موجودی کیف پول کافی نیست.")
    else:
      with transaction.atomic():
        o=Order.objects.select_for_update().get(id=order.id)
        if o.status in [OrderStatus.PAID,OrderStatus.CANCELED]:
          return redirect("orders_my")
        wallet_apply(request.user, -int(final), kind="order_pay", ref_order=o, description=f"پرداخت سفارش {o.id}")
        o.status=OrderStatus.PAID; o.verified_at=timezone.now()
        o.save(update_fields=["status","verified_at"])
        Enrollment.objects.get_or_create(user=request.user, course=course, defaults={"is_active":True,"source":"wallet"})
        ensure_invoice(o)
        messages.success(request,"پرداخت با کیف پول انجام شد.")
        return redirect("invoice_detail", order_id=o.id)

  return render(request,"orders/checkout.html",{
    "course":course,"setting":setting,"order":order,"coupon_form":coupon_form,
    "discount_label":label,"first_purchase_eligible":first_paid,"wallet":wallet,
  })

@login_required
def upload_receipt(request, order_id):
  order=get_object_or_404(Order, id=order_id, user=request.user)
  if order.status in [OrderStatus.PAID,OrderStatus.CANCELED]:
    return redirect("orders_my")
  form=ReceiptUploadForm(request.POST or None, request.FILES or None, instance=order)
  if request.method=="POST" and form.is_valid():
    form.save()
    order.status=OrderStatus.PENDING_VERIFY
    order.save(update_fields=["status"])
    messages.success(request,"رسید ثبت شد و پس از بررسی فعال می‌شود.")
    return redirect("orders_my")
  return render(request,"orders/receipt.html",{"order":order,"form":form})

@login_required
def my_orders(request):
  orders=Order.objects.filter(user=request.user).select_related("course")
  return render(request,"orders/my.html",{"orders":orders})

@login_required
def cancel_order(request, order_id):
  o=get_object_or_404(Order, id=order_id, user=request.user)
  if o.status=="paid":
    messages.error(request,"سفارش پرداخت‌شده قابل لغو نیست.")
    return redirect("orders_my")
  if request.method=="POST":
    o.status=OrderStatus.CANCELED; o.save(update_fields=["status"])
    messages.success(request,"سفارش لغو شد.")
  return redirect("orders_my")

@login_required
def wallet_home(request):
  wallet,_=Wallet.objects.get_or_create(user=request.user)
  txns=wallet.txns.all()[:50]
  topups=WalletTopUpRequest.objects.filter(user=request.user).order_by("-created_at")[:20]
  return render(request,"wallet/home.html",{"wallet":wallet,"txns":txns,"topups":topups})

@login_required
def wallet_topup(request):
  form=WalletTopUpForm(request.POST or None, request.FILES or None)
  if request.method=="POST" and form.is_valid():
    t=form.save(commit=False); t.user=request.user; t.status=TopUpStatus.PENDING; t.save()
    messages.success(request,"درخواست شارژ ثبت شد.")
    return redirect("wallet_home")
  return render(request,"wallet/topup.html",{"form":form})

@login_required
def invoice_list(request):
  invs=Invoice.objects.filter(order__user=request.user).select_related("order","order__course").order_by("-issued_at")
  return render(request,"invoices/list.html",{"invoices":invs})

@login_required
def invoice_detail(request, order_id):
  inv=get_object_or_404(Invoice, order__id=order_id, order__user=request.user)
  return render(request,"invoices/detail.html",{"invoice":inv})
PY

  cat > app/payments/admin.py <<'PY'
from django.contrib import admin
from django.utils import timezone
from django.db import transaction
from courses.models import Enrollment
from .models import BankTransferSetting, Order, OrderStatus, Coupon, Wallet, WalletTransaction, WalletTopUpRequest, TopUpStatus, wallet_apply, Invoice

def ensure_invoice(order):
  if hasattr(order,"invoice"): return order.invoice
  return Invoice.objects.create(
    order=order,
    billed_to=(order.user.get_full_name() or order.user.username),
    billed_email=(order.user.email or ""),
    item_title=f"خرید دوره: {order.course.title}",
    unit_price=order.amount, discount=order.discount_amount, total=order.final_amount,
  )

@admin.action(description="تایید سفارش + فعال‌سازی دسترسی + صدور فاکتور")
def mark_paid(modeladmin, request, qs):
  now=timezone.now()
  with transaction.atomic():
    for o in qs.select_for_update():
      o.status=OrderStatus.PAID; o.verified_at=now
      o.save(update_fields=["status","verified_at"])
      Enrollment.objects.get_or_create(user=o.user, course=o.course, defaults={"is_active":True,"source":"paid"})
      ensure_invoice(o)

@admin.register(Order)
class OrderAdmin(admin.ModelAdmin):
  list_display=("id","user","course","final_amount","status","created_at")
  list_filter=("status","created_at")
  search_fields=("user__username","course__title","tracking_code","coupon__code")
  actions=[mark_paid]

@admin.action(description="تایید شارژ و اعمال به کیف پول")
def approve_topup(modeladmin, request, qs):
  now=timezone.now()
  with transaction.atomic():
    for t in qs.select_for_update():
      if t.status!=TopUpStatus.PENDING: continue
      t.status=TopUpStatus.APPROVED; t.reviewed_at=now
      t.save(update_fields=["status","reviewed_at"])
      wallet_apply(t.user, int(t.amount), kind="topup", description="شارژ تایید شده توسط ادمین")

@admin.action(description="رد شارژ")
def reject_topup(modeladmin, request, qs):
  now=timezone.now()
  for t in qs:
    if t.status==TopUpStatus.PENDING:
      t.status=TopUpStatus.REJECTED; t.reviewed_at=now
      t.save(update_fields=["status","reviewed_at"])

@admin.register(WalletTopUpRequest)
class WalletTopUpRequestAdmin(admin.ModelAdmin):
  list_display=("id","user","amount","status","created_at")
  list_filter=("status","created_at")
  search_fields=("user__username","tracking_code")
  actions=[approve_topup, reject_topup]

admin.site.register(BankTransferSetting)
admin.site.register(Coupon)
admin.site.register(Wallet)
admin.site.register(WalletTransaction)
admin.site.register(Invoice)
PY

  cat > app/payments/urls.py <<'PY'
from django.urls import path
from .views import checkout, upload_receipt, my_orders, cancel_order
urlpatterns=[
  path("checkout/<slug:slug>/", checkout, name="checkout"),
  path("receipt/<uuid:order_id>/", upload_receipt, name="upload_receipt"),
  path("my/", my_orders, name="orders_my"),
  path("cancel/<uuid:order_id>/", cancel_order, name="order_cancel"),
]
PY
  cat > app/payments/wallet_urls.py <<'PY'
from django.urls import path
from .views import wallet_home, wallet_topup
urlpatterns=[path("", wallet_home, name="wallet_home"), path("topup/", wallet_topup, name="wallet_topup")]
PY
  cat > app/payments/invoice_urls.py <<'PY'
from django.urls import path
from .views import invoice_list, invoice_detail
urlpatterns=[path("", invoice_list, name="invoice_list"), path("<uuid:order_id>/", invoice_detail, name="invoice_detail")]
PY

  cat > app/tickets/apps.py <<'PY'
from django.apps import AppConfig
class TicketsConfig(AppConfig):
  default_auto_field="django.db.models.BigAutoField"
  name="tickets"
  verbose_name="تیکت‌ها"
PY
  cat > app/tickets/models.py <<'PY'
import uuid
from django.db import models
from django.conf import settings
from django.utils.translation import gettext_lazy as _

class TicketStatus(models.TextChoices):
  OPEN="open",_("باز")
  ANSWERED="answered",_("پاسخ داده شده")
  CLOSED="closed",_("بسته")

class Ticket(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="tickets")
  subject=models.CharField(max_length=200)
  description=models.TextField()
  attachment=models.FileField(upload_to="tickets/", blank=True, null=True)
  status=models.CharField(max_length=20, choices=TicketStatus.choices, default=TicketStatus.OPEN)
  created_at=models.DateTimeField(auto_now_add=True)
  updated_at=models.DateTimeField(auto_now=True)
  class Meta:
    ordering=["-created_at"]; verbose_name=_("تیکت"); verbose_name_plural=_("تیکت‌ها")

class TicketReply(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  ticket=models.ForeignKey(Ticket, on_delete=models.CASCADE, related_name="replies")
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
  message=models.TextField()
  attachment=models.FileField(upload_to="tickets/replies/", blank=True, null=True)
  created_at=models.DateTimeField(auto_now_add=True)
  class Meta:
    ordering=["created_at"]; verbose_name=_("پاسخ تیکت"); verbose_name_plural=_("پاسخ‌های تیکت")
PY
  cat > app/tickets/forms.py <<'PY'
from django import forms
from .models import Ticket, TicketReply
_INPUT="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 outline-none focus:ring-2 focus:ring-slate-300 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700"
class TicketCreateForm(forms.ModelForm):
  class Meta:
    model=Ticket
    fields=("subject","description","attachment")
    widgets={"subject": forms.TextInput(attrs={"class":_INPUT}),
             "description": forms.Textarea(attrs={"class":_INPUT,"rows":5})}
class TicketReplyForm(forms.ModelForm):
  class Meta:
    model=TicketReply
    fields=("message","attachment")
    widgets={"message": forms.Textarea(attrs={"class":_INPUT,"rows":4})}
PY
  cat > app/tickets/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.shortcuts import render, redirect, get_object_or_404
from django.contrib import messages
from .models import Ticket, TicketStatus
from .forms import TicketCreateForm, TicketReplyForm

@login_required
def ticket_list(request):
  tickets=Ticket.objects.filter(user=request.user)
  return render(request,"tickets/list.html",{"tickets":tickets})

@login_required
def ticket_create(request):
  form=TicketCreateForm(request.POST or None, request.FILES or None)
  if request.method=="POST" and form.is_valid():
    t=form.save(commit=False); t.user=request.user; t.status=TicketStatus.OPEN; t.save()
    messages.success(request,"تیکت ثبت شد.")
    return redirect("ticket_detail", ticket_id=t.id)
  return render(request,"tickets/create.html",{"form":form})

@login_required
def ticket_detail(request, ticket_id):
  ticket=get_object_or_404(Ticket, id=ticket_id, user=request.user)
  form=TicketReplyForm(request.POST or None, request.FILES or None)
  if request.method=="POST" and form.is_valid():
    r=form.save(commit=False); r.ticket=ticket; r.user=request.user; r.save()
    ticket.status=TicketStatus.OPEN; ticket.save(update_fields=["status"])
    messages.success(request,"پاسخ ثبت شد.")
    return redirect("ticket_detail", ticket_id=ticket.id)
  return render(request,"tickets/detail.html",{"ticket":ticket,"form":form})
PY
  cat > app/tickets/admin.py <<'PY'
from django.contrib import admin
from .models import Ticket, TicketReply
class TicketReplyInline(admin.TabularInline):
  model=TicketReply; extra=0
@admin.register(Ticket)
class TicketAdmin(admin.ModelAdmin):
  list_display=("id","user","subject","status","created_at")
  list_filter=("status","created_at")
  search_fields=("user__username","subject")
  inlines=[TicketReplyInline]
admin.site.register(TicketReply)
PY
  cat > app/tickets/urls.py <<'PY'
from django.urls import path
from .views import ticket_list, ticket_create, ticket_detail
urlpatterns=[path("",ticket_list,name="ticket_list"), path("new/",ticket_create,name="ticket_create"), path("<uuid:ticket_id>/",ticket_detail,name="ticket_detail")]
PY

  cat > app/templates/partials/form_errors.html <<'HTML'
{% if form.non_field_errors %}
  <div class="mb-3 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-200">
    {{ form.non_field_errors }}
  </div>
{% endif %}
HTML
  cat > app/templates/partials/field.html <<'HTML'
<div class="space-y-1">
  <label class="text-sm font-medium">{{ field.label }}</label>
  {{ field }}
  {% if field.help_text %}<div class="text-xs text-slate-500 dark:text-slate-300">{{ field.help_text }}</div>{% endif %}
  {% if field.errors %}<div class="text-xs text-rose-600 dark:text-rose-300">{{ field.errors }}</div>{% endif %}
</div>
HTML

  cat > app/templates/base.html <<'HTML'
{% load static %}
<!doctype html>
<html lang="fa" dir="rtl">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <script>tailwind=window.tailwind||{};tailwind.config={darkMode:'class'};</script>
  <script src="https://cdn.tailwindcss.com"></script>
  {% if site_settings.favicon %}<link rel="icon" href="{{ site_settings.favicon.url }}">{% endif %}
  <title>{% block title %}{{ site_settings.brand_name|default:"EduCMS" }}{% endblock %}</title>
</head>
<body class="min-h-screen bg-gradient-to-b from-slate-50 to-white text-slate-900 dark:from-slate-950 dark:to-slate-950 dark:text-slate-100">
<script>
(function(){
  const root=document.documentElement;
  function apply(m){ root.classList.remove('dark'); if(m==='dark') root.classList.add('dark');
    if(m==='system'){ const d=window.matchMedia&&window.matchMedia('(prefers-color-scheme: dark)').matches; if(d) root.classList.add('dark'); } }
  const initial=localStorage.getItem('theme_mode')||'{{ site_settings.default_theme|default:"system" }}'; apply(initial);
  window.__setTheme=(m)=>{localStorage.setItem('theme_mode',m);apply(m);};
})();
</script>

<header class="sticky top-0 z-30 border-b border-slate-200/70 bg-white/85 backdrop-blur dark:border-slate-800 dark:bg-slate-950/75">
  <div class="mx-auto max-w-6xl px-4 py-4 flex items-center justify-between gap-3">
    <a href="/" class="flex items-center gap-3">
      {% if site_settings.logo %}<img src="{{ site_settings.logo.url }}" class="h-9 w-auto" alt="{{ site_settings.brand_name }}">{% else %}
      <div class="h-9 w-9 rounded-2xl bg-slate-900 dark:bg-white"></div>{% endif %}
      <span class="font-extrabold text-xl tracking-tight">{{ site_settings.brand_name|default:"EduCMS" }}</span>
    </a>

    <div class="flex items-center gap-2 text-sm">
      <div class="hidden sm:flex items-center gap-1 rounded-2xl border border-slate-200 bg-white px-1 py-1 dark:border-slate-700 dark:bg-slate-900">
        <button type="button" class="px-3 py-1 rounded-xl hover:bg-slate-100 dark:hover:bg-slate-800" onclick="__setTheme('light')">لایت</button>
        <button type="button" class="px-3 py-1 rounded-xl hover:bg-slate-100 dark:hover:bg-slate-800" onclick="__setTheme('dark')">دارک</button>
        <button type="button" class="px-3 py-1 rounded-xl hover:bg-slate-100 dark:hover:bg-slate-800" onclick="__setTheme('system')">سیستم</button>
      </div>

      {% if user.is_authenticated %}
        <a class="rounded-xl px-3 py-2 hover:bg-slate-100 dark:hover:bg-slate-900" href="/dashboard/">داشبورد</a>
        <a class="rounded-xl px-3 py-2 hover:bg-slate-100 dark:hover:bg-slate-900" href="/wallet/">کیف پول</a>
        <a class="rounded-xl px-3 py-2 hover:bg-slate-100 dark:hover:bg-slate-900" href="/invoices/">فاکتورها</a>
        <a class="rounded-xl px-3 py-2 hover:bg-slate-100 dark:hover:bg-slate-900" href="/orders/my/">سفارش‌ها</a>
        <a class="rounded-xl px-3 py-2 hover:bg-slate-100 dark:hover:bg-slate-900" href="/tickets/">تیکت‌ها</a>
        <a class="rounded-xl px-3 py-2 hover:bg-slate-100 dark:hover:bg-slate-900" href="/accounts/profile/">پروفایل</a>
        <form method="post" action="/accounts/logout/" class="inline">{% csrf_token %}
          <button class="rounded-xl border border-slate-200 px-3 py-2 hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-900">خروج</button>
        </form>
        {% if user.is_staff %}
          <a class="rounded-xl border border-slate-200 px-3 py-2 hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-900"
             href="/{{ site_settings.admin_path|default:'admin' }}/">ادمین</a>
        {% endif %}
      {% else %}
        <a class="rounded-xl border border-slate-200 px-3 py-2 hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-900" href="/accounts/login/">ورود</a>
        <a class="rounded-xl bg-slate-900 px-3 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900" href="/accounts/register/">ثبت‌نام</a>
      {% endif %}
    </div>
  </div>
</header>

<main class="mx-auto max-w-6xl px-4 py-8">
  {% if messages %}
    <div class="mb-5 space-y-2">
      {% for m in messages %}
        <div class="rounded-2xl border border-slate-200 bg-white p-3 text-sm dark:border-slate-800 dark:bg-slate-950">{{ m }}</div>
      {% endfor %}
    </div>
  {% endif %}
  {% block content %}{% endblock %}
</main>

<footer class="border-t border-slate-200/70 bg-white dark:border-slate-800 dark:bg-slate-950">
  <div class="mx-auto max-w-6xl px-4 py-8 text-sm text-slate-500 dark:text-slate-300">
    {{ site_settings.footer_text|default:"© تمامی حقوق محفوظ است." }}
  </div>
</footer>
</body>
</html>
HTML

  cat > app/templates/dashboard/home.html <<'HTML'
{% extends "base.html" %}
{% block title %}داشبورد{% endblock %}
{% block content %}
<div class="grid gap-4 lg:grid-cols-3">
  <div class="lg:col-span-2 space-y-4">
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-xl font-extrabold">داشبورد</h1>
          <div class="text-sm text-slate-500 dark:text-slate-300">موجودی کیف پول: <b>{{ wallet.balance }}</b> تومان</div>
        </div>
        <a class="rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/">دوره‌ها</a>
      </div>
    </div>

    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      <h2 class="font-bold mb-3">آخرین سفارش‌ها</h2>
      <div class="space-y-2 text-sm">
        {% for o in orders %}
          <div class="rounded-xl border border-slate-200 p-3 dark:border-slate-800">
            <div class="flex items-center justify-between gap-3">
              <div class="font-semibold">{{ o.course.title }}</div>
              <div><b>{{ o.final_amount }}</b> تومان</div>
              <span class="rounded-xl px-3 py-1 text-xs bg-slate-200 text-slate-700 dark:bg-slate-800 dark:text-slate-200">{{ o.get_status_display }}</span>
            </div>
          </div>
        {% empty %}<div class="text-slate-500 dark:text-slate-300">سفارشی ندارید.</div>{% endfor %}
      </div>
    </div>
  </div>

  <aside class="space-y-4">
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      <h3 class="font-bold mb-3">میانبر</h3>
      <div class="grid gap-2 text-sm">
        <a class="rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/wallet/">کیف پول</a>
        <a class="rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/invoices/">فاکتورها</a>
        <a class="rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/accounts/security/">سوالات امنیتی</a>
      </div>
    </div>
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      <h3 class="font-bold mb-3">تیکت‌ها</h3>
      <div class="space-y-2 text-sm">
        {% for t in tickets %}
          <a class="block rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/tickets/{{ t.id }}/">{{ t.subject }}</a>
        {% empty %}<div class="text-slate-500 dark:text-slate-300">تیکتی ندارید.</div>{% endfor %}
      </div>
      <a class="mt-3 block rounded-xl bg-slate-900 px-4 py-2 text-center text-white hover:opacity-95 dark:bg-white dark:text-slate-900" href="/tickets/new/">ثبت تیکت</a>
    </div>
  </aside>
</div>
{% endblock %}
HTML

  cat > app/templates/courses/list.html <<'HTML'
{% extends "base.html" %}
{% block title %}دوره‌ها{% endblock %}
{% block content %}
<div class="mb-6 flex items-end justify-between gap-4">
  <div>
    <h1 class="text-2xl font-extrabold">{{ tpl.home_title|default:"دوره‌های آموزشی" }}</h1>
    <div class="text-sm text-slate-500 dark:text-slate-300">{{ tpl.home_subtitle|default:"جدیدترین دوره‌ها" }}</div>
  </div>
</div>

<div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
  {% for c in object_list %}
    <a href="/courses/{{ c.slug }}/" class="overflow-hidden rounded-2xl border border-slate-200 bg-white hover:shadow-sm dark:border-slate-800 dark:bg-slate-950">
      <div class="aspect-[16/9] bg-slate-100 dark:bg-slate-900">
        {% if c.cover %}<img class="h-full w-full object-cover" src="{{ c.cover.url }}" alt="{{ c.title }}">{% endif %}
      </div>
      <div class="p-4">
        <div class="font-bold">{{ c.title }}</div>
        <div class="mt-1 text-sm text-slate-600 dark:text-slate-300 line-clamp-2">{{ c.summary|default:"—" }}</div>
        <div class="mt-3 text-sm">
          {% if c.is_free_for_all or not c.price_toman %}
            <span class="rounded-xl bg-emerald-600 px-3 py-1 text-white">رایگان</span>
          {% else %}
            <span class="rounded-xl bg-slate-900 px-3 py-1 text-white dark:bg-white dark:text-slate-900">{{ c.price_toman }} تومان</span>
          {% endif %}
        </div>
      </div>
    </a>
  {% empty %}
    <div class="text-slate-500 dark:text-slate-300">{{ tpl.home_empty|default:"هنوز دوره‌ای منتشر نشده است." }}</div>
  {% endfor %}
</div>
{% endblock %}
HTML

  cat > app/templates/courses/detail.html <<'HTML'
{% extends "base.html" %}
{% block title %}{{ object.title }}{% endblock %}
{% block content %}
<div class="grid gap-6 lg:grid-cols-3">
  <div class="lg:col-span-2 space-y-4">
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      <h1 class="text-2xl font-extrabold mb-2">{{ object.title }}</h1>
      <div class="text-slate-600 dark:text-slate-300">{{ object.description|linebreaks }}</div>
    </div>
  </div>
  <aside class="space-y-4">
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      {% if has_access %}
        <div class="rounded-xl bg-emerald-600 px-4 py-2 text-white text-sm">دسترسی شما فعال است.</div>
      {% else %}
        {% if object.is_free_for_all or not object.price_toman %}
          <div class="rounded-xl bg-emerald-600 px-4 py-2 text-white text-sm">این دوره رایگان است.</div>
        {% else %}
          <div class="text-sm text-slate-500 dark:text-slate-300">قیمت</div>
          <div class="text-2xl font-extrabold mt-1">{{ object.price_toman }} تومان</div>
          <a class="mt-4 block rounded-xl bg-slate-900 px-4 py-2 text-center text-white hover:opacity-95 dark:bg-white dark:text-slate-900" href="/orders/checkout/{{ object.slug }}/">پرداخت</a>
          <div class="mt-2 text-xs text-slate-500 dark:text-slate-300">کارت‌به‌کارت یا کیف پول</div>
        {% endif %}
      {% endif %}
    </div>
  </aside>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/login.html <<'HTML'
{% extends "base.html" %}
{% block title %}ورود{% endblock %}
{% block content %}
<div class="mx-auto max-w-md rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-bold mb-1">ورود</h1>
  <form method="post" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
    <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ورود</button>
  </form>
  <div class="mt-3 text-sm text-slate-500 dark:text-slate-300">رمز را فراموش کرده‌اید؟ <a class="underline" href="/accounts/reset/">بازیابی</a></div>
  <div class="mt-2 text-sm text-slate-500 dark:text-slate-300">حساب ندارید؟ <a class="underline" href="/accounts/register/">ثبت‌نام</a></div>
</div>
{% endblock %}
HTML
  cat > app/templates/accounts/register.html <<'HTML'
{% extends "base.html" %}
{% block title %}ثبت‌نام{% endblock %}
{% block content %}
<div class="mx-auto max-w-md rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-bold mb-1">ثبت‌نام</h1>
  <form method="post" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
    <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ساخت حساب</button>
  </form>
  <div class="mt-2 text-sm text-slate-500 dark:text-slate-300">قبلاً ثبت‌نام کرده‌اید؟ <a class="underline" href="/accounts/login/">ورود</a></div>
</div>
{% endblock %}
HTML
  cat > app/templates/accounts/profile.html <<'HTML'
{% extends "base.html" %}
{% block title %}پروفایل{% endblock %}
{% block content %}
<div class="mx-auto max-w-2xl rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-4">پروفایل</h1>

  {% if not allow_edit %}
    <div class="rounded-xl border border-amber-200 bg-amber-50 p-4 text-amber-800 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-200">
      <p class="font-semibold">ویرایش پروفایل غیرفعال است</p>
      <p class="text-sm mt-1">ویرایش پروفایل توسط مدیر سایت غیرفعال شده است.</p>
    </div>
  {% else %}
    <form method="post" class="space-y-4">{% csrf_token %}
      {% include "partials/form_errors.html" %}
      {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
      <div class="grid gap-4 sm:grid-cols-2">
        <div><label class="text-sm font-medium">شماره تماس</label>
          <input name="phone" value="{{ profile.phone }}" class="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 outline-none focus:ring-2 focus:ring-slate-300 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700" dir="ltr">
        </div>
        <div><label class="text-sm font-medium">بیو</label>
          <textarea name="bio" rows="2" class="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 outline-none focus:ring-2 focus:ring-slate-300 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700">{{ profile.bio }}</textarea>
        </div>
      </div>
      <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ذخیره</button>
    </form>
  {% endif %}

  <div class="mt-4 text-sm"><a class="underline" href="/accounts/security/">مدیریت سوالات امنیتی</a></div>
</div>
{% endblock %}
HTML
  cat > app/templates/accounts/security_questions.html <<'HTML'
{% extends "base.html" %}
{% block title %}سوالات امنیتی{% endblock %}
{% block content %}
<div class="mx-auto max-w-2xl rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-4">سوالات امنیتی</h1>
  <form method="post" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
    <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ذخیره</button>
  </form>
</div>
{% endblock %}
HTML
  cat > app/templates/accounts/reset_step1.html <<'HTML'
{% extends "base.html" %}
{% block title %}بازیابی رمز{% endblock %}
{% block content %}
<div class="mx-auto max-w-md rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-4">بازیابی رمز عبور</h1>
  <form method="post" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
    <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ادامه</button>
  </form>
</div>
{% endblock %}
HTML
  cat > app/templates/accounts/reset_step2.html <<'HTML'
{% extends "base.html" %}
{% block title %}تایید سوالات امنیتی{% endblock %}
{% block content %}
<div class="mx-auto max-w-md rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-4">تایید سوالات امنیتی</h1>
  <div class="text-sm text-slate-500 dark:text-slate-300 mb-4">کاربر: <b dir="ltr">{{ username }}</b></div>
  <form method="post" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    <div class="space-y-1"><div class="text-sm font-medium">{{ q1 }}</div>{{ form.a1 }}</div>
    <div class="space-y-1"><div class="text-sm font-medium">{{ q2 }}</div>{{ form.a2 }}</div>
    {% include "partials/field.html" with field=form.new_password1 %}
    {% include "partials/field.html" with field=form.new_password2 %}
    <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">تغییر رمز</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/orders/checkout.html <<'HTML'
{% extends "base.html" %}
{% block title %}پرداخت{% endblock %}
{% block content %}
<div class="mx-auto max-w-2xl space-y-4">
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <h1 class="text-xl font-bold">پرداخت</h1>
    <div class="text-sm text-slate-500 dark:text-slate-300">دوره: <b>{{ course.title }}</b></div>
  </div>

  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950 space-y-4">
    <form method="post" class="space-y-3">{% csrf_token %}
      <div class="text-sm font-semibold">کد تخفیف</div>
      <div class="flex gap-2">
        <div class="flex-1">{{ coupon_form.coupon_code }}</div>
        <button name="apply_coupon" value="1" class="rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-900">اعمال</button>
      </div>
      <div class="text-xs text-slate-500 dark:text-slate-300">{% if first_purchase_eligible %}در صورت عدم وارد کردن کد، ممکن است تخفیف خرید اول اعمال شود.{% endif %}</div>
    </form>

    <div class="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm dark:border-slate-800 dark:bg-slate-900/40">
      پایه: <b>{{ order.amount }}</b> | تخفیف: <b>{{ order.discount_amount }}</b> {% if discount_label %}({{ discount_label }}){% endif %} |
      نهایی: <b>{{ order.final_amount }}</b> تومان
    </div>

    <div class="grid gap-3 md:grid-cols-2">
      <a class="rounded-xl bg-slate-900 px-4 py-2 text-center text-white hover:opacity-95 dark:bg-white dark:text-slate-900" href="/orders/receipt/{{ order.id }}/">آپلود رسید کارت‌به‌کارت</a>
      <div class="rounded-2xl border border-slate-200 p-4 dark:border-slate-800">
        <div class="text-sm font-semibold">پرداخت با کیف پول</div>
        <div class="text-sm text-slate-500 dark:text-slate-300 mt-1">موجودی: <b>{{ wallet.balance }}</b> تومان</div>
        <form method="post" class="mt-3">{% csrf_token %}
          <button name="pay_wallet" value="1" class="w-full rounded-xl bg-emerald-600 px-4 py-2 text-white hover:opacity-95">پرداخت با کیف پول</button>
        </form>
      </div>
    </div>

    <div class="rounded-2xl border border-slate-200 p-4 text-sm dark:border-slate-800">
      <div class="font-semibold mb-1">اطلاعات کارت</div>
      نام: <b>{{ setting.account_holder|default:"-" }}</b><br>
      کارت: <b dir="ltr">{{ setting.card_number|default:"-" }}</b>
      {% if setting.note %}<div class="mt-2 text-xs text-slate-500 dark:text-slate-300">{{ setting.note }}</div>{% endif %}
    </div>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/orders/receipt.html <<'HTML'
{% extends "base.html" %}
{% block title %}آپلود رسید{% endblock %}
{% block content %}
<div class="mx-auto max-w-xl rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-bold mb-1">آپلود رسید</h1>
  <div class="text-xs text-slate-500 dark:text-slate-300 mb-4">سفارش: <span dir="ltr">{{ order.id }}</span></div>
  <form method="post" enctype="multipart/form-data" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
    <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ثبت</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/orders/my.html <<'HTML'
{% extends "base.html" %}
{% block title %}سفارش‌ها{% endblock %}
{% block content %}
<div class="mx-auto max-w-4xl rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-4">سفارش‌های من</h1>
  <div class="space-y-3 text-sm">
    {% for o in orders %}
      <div class="rounded-2xl border border-slate-200 p-4 dark:border-slate-800">
        <div class="flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
          <div class="font-semibold">{{ o.course.title }}</div>
          <div><b>{{ o.final_amount }}</b> تومان</div>
          <div class="text-slate-500 dark:text-slate-300">{{ o.get_status_display }}</div>
        </div>
        <div class="mt-2 flex flex-wrap gap-2">
          {% if o.status == "paid" %}
            <a class="rounded-xl border border-slate-200 px-3 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/invoices/{{ o.id }}/">فاکتور</a>
          {% else %}
            <a class="rounded-xl border border-slate-200 px-3 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/orders/receipt/{{ o.id }}/">رسید</a>
          {% endif %}
          {% if o.status != "paid" and o.status != "canceled" %}
            <form method="post" action="/orders/cancel/{{ o.id }}/" class="inline">{% csrf_token %}
              <button class="rounded-xl border border-rose-200 px-3 py-2 text-rose-700 hover:bg-rose-50 dark:border-rose-900/40 dark:text-rose-200 dark:hover:bg-rose-950/30">لغو</button>
            </form>
          {% endif %}
        </div>
      </div>
    {% empty %}<div class="text-slate-500 dark:text-slate-300">سفارشی ندارید.</div>{% endfor %}
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/wallet/home.html <<'HTML'
{% extends "base.html" %}
{% block title %}کیف پول{% endblock %}
{% block content %}
<div class="mx-auto max-w-4xl space-y-4">
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <div class="flex items-center justify-between gap-3">
      <div>
        <h1 class="text-xl font-extrabold">کیف پول</h1>
        <div class="text-sm text-slate-500 dark:text-slate-300">موجودی: <b>{{ wallet.balance }}</b> تومان</div>
      </div>
      <a class="rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900" href="/wallet/topup/">درخواست شارژ</a>
    </div>
  </div>

  <div class="grid gap-4 lg:grid-cols-2">
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      <h2 class="font-bold mb-3">تراکنش‌ها</h2>
      <div class="space-y-2 text-sm">
        {% for t in txns %}
          <div class="rounded-xl border border-slate-200 p-3 dark:border-slate-800 flex items-center justify-between">
            <div>{{ t.get_kind_display }}</div>
            <div class="{% if t.amount >= 0 %}text-emerald-600{% else %}text-rose-600{% endif %}">{% if t.amount >= 0 %}+{% endif %}{{ t.amount }}</div>
          </div>
        {% empty %}<div class="text-slate-500 dark:text-slate-300">تراکنشی ندارید.</div>{% endfor %}
      </div>
    </div>
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      <h2 class="font-bold mb-3">درخواست‌های شارژ</h2>
      <div class="space-y-2 text-sm">
        {% for r in topups %}
          <div class="rounded-xl border border-slate-200 p-3 dark:border-slate-800 flex items-center justify-between">
            <div><b>{{ r.amount }}</b> تومان</div><div>{{ r.get_status_display }}</div>
          </div>
        {% empty %}<div class="text-slate-500 dark:text-slate-300">درخواستی ندارید.</div>{% endfor %}
      </div>
    </div>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/wallet/topup.html <<'HTML'
{% extends "base.html" %}
{% block title %}شارژ کیف پول{% endblock %}
{% block content %}
<div class="mx-auto max-w-xl rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-4">درخواست شارژ</h1>
  <form method="post" enctype="multipart/form-data" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
    <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ثبت</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/invoices/list.html <<'HTML'
{% extends "base.html" %}
{% block title %}فاکتورها{% endblock %}
{% block content %}
<div class="mx-auto max-w-4xl rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-4">فاکتورهای من</h1>
  <div class="space-y-3 text-sm">
    {% for i in invoices %}
      <a class="block rounded-2xl border border-slate-200 p-4 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/invoices/{{ i.order.id }}/">
        <div class="flex items-center justify-between gap-3">
          <div dir="ltr" class="font-semibold">{{ i.number }}</div>
          <div><b>{{ i.total }}</b> تومان</div>
          <div class="text-slate-500 dark:text-slate-300">{{ i.issued_at|date:"Y/m/d H:i" }}</div>
        </div>
      </a>
    {% empty %}<div class="text-slate-500 dark:text-slate-300">فاکتوری ندارید.</div>{% endfor %}
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/invoices/detail.html <<'HTML'
{% extends "base.html" %}
{% block title %}فاکتور{% endblock %}
{% block content %}
<div class="mx-auto max-w-3xl space-y-4">
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <div class="flex items-center justify-between gap-3">
      <div>
        <h1 class="text-xl font-extrabold">فاکتور</h1>
        <div class="text-sm text-slate-500 dark:text-slate-300">شماره: <b dir="ltr">{{ invoice.number }}</b></div>
        <div class="text-sm text-slate-500 dark:text-slate-300">تاریخ: {{ invoice.issued_at|date:"Y/m/d H:i" }}</div>
      </div>
      <a class="rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/invoices/">بازگشت</a>
    </div>
  </div>
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <div class="text-sm">شرح: <b>{{ invoice.item_title }}</b></div>
    <div class="mt-2 text-sm">پایه: {{ invoice.unit_price }} | تخفیف: {{ invoice.discount }} | نهایی: <b>{{ invoice.total }}</b> تومان</div>
    <div class="mt-3 text-xs text-slate-500 dark:text-slate-300">این فاکتور سیستمی صادر شده است.</div>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/tickets/list.html <<'HTML'
{% extends "base.html" %}
{% block title %}تیکت‌ها{% endblock %}
{% block content %}
<div class="mx-auto max-w-4xl space-y-4">
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950 flex items-center justify-between">
    <h1 class="text-xl font-extrabold">تیکت‌ها</h1>
    <a class="rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900" href="/tickets/new/">ثبت تیکت</a>
  </div>
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <div class="space-y-3 text-sm">
      {% for t in tickets %}
        <a class="block rounded-2xl border border-slate-200 p-4 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/tickets/{{ t.id }}/">
          <div class="flex items-center justify-between"><div class="font-semibold">{{ t.subject }}</div><div class="text-slate-500 dark:text-slate-300">{{ t.get_status_display }}</div></div>
        </a>
      {% empty %}<div class="text-slate-500 dark:text-slate-300">تیکتی ندارید.</div>{% endfor %}
    </div>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/tickets/create.html <<'HTML'
{% extends "base.html" %}
{% block title %}ثبت تیکت{% endblock %}
{% block content %}
<div class="mx-auto max-w-2xl rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-4">ثبت تیکت</h1>
  <form method="post" enctype="multipart/form-data" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
    <button class="rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ثبت</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/tickets/detail.html <<'HTML'
{% extends "base.html" %}
{% block title %}تیکت{% endblock %}
{% block content %}
<div class="mx-auto max-w-4xl space-y-4">
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <div class="flex items-center justify-between gap-3">
      <div><h1 class="text-xl font-extrabold">{{ ticket.subject }}</h1><div class="text-sm text-slate-500 dark:text-slate-300">{{ ticket.get_status_display }}</div></div>
      <a class="rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/tickets/">بازگشت</a>
    </div>
    <div class="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 dark:border-slate-800 dark:bg-slate-900/40 whitespace-pre-line">{{ ticket.description }}</div>
  </div>

  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <h2 class="font-bold mb-3">پاسخ‌ها</h2>
    <div class="space-y-2 text-sm">
      {% for r in ticket.replies.all %}
        <div class="rounded-xl border border-slate-200 p-3 dark:border-slate-800 whitespace-pre-line">{{ r.message }}</div>
      {% empty %}<div class="text-slate-500 dark:text-slate-300">پاسخی ثبت نشده.</div>{% endfor %}
    </div>
    <hr class="my-5 border-slate-200 dark:border-slate-800">
    <h3 class="font-bold mb-3">ارسال پاسخ</h3>
    <form method="post" enctype="multipart/form-data" class="space-y-4">{% csrf_token %}
      {% include "partials/form_errors.html" %}
      {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
      <button class="rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ارسال</button>
    </form>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/settings/admin_path.html <<'HTML'
{% extends "base.html" %}
{% block title %}مسیر ادمین{% endblock %}
{% block content %}
<div class="mx-auto max-w-xl rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-2">تغییر مسیر ادمین</h1>
  <div class="text-sm text-slate-500 dark:text-slate-300 mb-4">مسیر فعلی: <b dir="ltr">/{{ current }}/</b></div>
  <form method="post" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
    <button class="rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ذخیره</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/settings/admin_account.html <<'HTML'
{% extends "admin/base_site.html" %}
{% block content %}
<div style="max-width:720px">
  <h1>تغییر نام کاربری و رمز ادمین</h1>
  <form method="post">{% csrf_token %}{{ form.as_p }}<button type="submit" class="default">ذخیره</button></form>
</div>
{% endblock %}
HTML

  cat > app/entrypoint.sh <<'SH'
#!/bin/bash
set -e

echo "=== EduCMS Entrypoint ==="

# Wait for database to be ready
echo "Waiting for database..."
max_attempts=30
attempt=1
while [ $attempt -le $max_attempts ]; do
    python -c "
import os, sys
import MySQLdb
try:
    MySQLdb.connect(
        host=os.getenv('DB_HOST', 'db'),
        user=os.getenv('DB_USER'),
        passwd=os.getenv('DB_PASSWORD'),
        db=os.getenv('DB_NAME'),
        port=int(os.getenv('DB_PORT', 3306))
    )
    print('Database is ready!')
    sys.exit(0)
except Exception as e:
    print(f'Database not ready: {e}')
    sys.exit(1)
" && break
    echo "Attempt $attempt/$max_attempts - Database not ready, waiting..."
    sleep 2
    attempt=$((attempt + 1))
done

if [ $attempt -gt $max_attempts ]; then
    echo "ERROR: Database not ready after $max_attempts attempts"
    exit 1
fi

echo "Running migrations..."
python manage.py makemigrations accounts settingsapp courses payments tickets dashboard --noinput || true
python manage.py migrate --noinput

echo "Seeding database..."
python manage.py shell <<'PY'
import os
import traceback

try:
    from django.contrib.auth import get_user_model
    from settingsapp.models import SiteSetting, TemplateText, RegistrationField
    from payments.models import BankTransferSetting
    from accounts.models import SecurityQuestion, UserProfile

    User=get_user_model()
    admin_u=os.getenv("ADMIN_USERNAME")
    admin_p=os.getenv("ADMIN_PASSWORD")
    admin_e=os.getenv("ADMIN_EMAIL")
    initial_admin_path=os.getenv("INITIAL_ADMIN_PATH","admin") or "admin"

    u,_=User.objects.get_or_create(username=admin_u, defaults={"email": admin_e})
    u.is_staff=True; u.is_superuser=True; u.email=admin_e
    u.set_password(admin_p); u.save()
    UserProfile.objects.get_or_create(user=u)
    print("Admin user created/updated.")

    qs=[("نام اولین معلم شما چه بود؟",1),("نام شهر محل تولد شما چیست؟",2),("نام بهترین دوست دوران کودکی شما چیست؟",3),("مدل اولین گوشی شما چه بود؟",4)]
    for t,o in qs:
        SecurityQuestion.objects.get_or_create(text=t, defaults={"order":o,"is_active":True})
    print("Security questions seeded.")

    # Seed default registration fields (system fields that cannot be deleted)
    default_fields = [
        {"field_key": "email", "label": "ایمیل", "field_type": "email", "is_required": True, "is_system": True, "order": 1, "show_in_profile": True},
        {"field_key": "security_question", "label": "سوال امنیتی", "field_type": "select", "is_required": True, "is_system": True, "order": 2, "show_in_profile": False},
        {"field_key": "security_answer", "label": "پاسخ سوال امنیتی", "field_type": "password", "is_required": True, "is_system": True, "order": 3, "show_in_profile": False},
        {"field_key": "password1", "label": "گذرواژه", "field_type": "password", "is_required": True, "is_system": True, "order": 4, "show_in_profile": False},
        {"field_key": "password2", "label": "تکرار گذرواژه", "field_type": "password", "is_required": True, "is_system": True, "order": 5, "show_in_profile": False},
    ]
    for f in default_fields:
        RegistrationField.objects.get_or_create(field_key=f["field_key"], defaults=f)
    print("Registration fields seeded.")

    s,_=SiteSetting.objects.get_or_create(id=1, defaults={"brand_name":"EduCMS","footer_text":"© تمامی حقوق محفوظ است.","default_theme":"system","admin_path":initial_admin_path,"allow_profile_edit":True})
    if not s.admin_path:
        s.admin_path=initial_admin_path; s.save(update_fields=["admin_path"])
    print("Site settings seeded.")

    BankTransferSetting.objects.get_or_create(id=1)
    TemplateText.objects.get_or_create(key="home_title", defaults={"title":"عنوان","value":"دوره‌های آموزشی"})
    TemplateText.objects.get_or_create(key="home_subtitle", defaults={"title":"زیرعنوان","value":"جدیدترین دوره‌ها"})
    TemplateText.objects.get_or_create(key="home_empty", defaults={"title":"بدون دوره","value":"هنوز دوره‌ای منتشر نشده است."})
    print("Template texts seeded.")
    print("=== Seed completed successfully ===")
except Exception as e:
    print(f"ERROR during seeding: {e}")
    traceback.print_exc()
PY

echo "Collecting static files..."
python manage.py collectstatic --noinput

echo "Starting Gunicorn..."
exec gunicorn educms.wsgi:application --bind 0.0.0.0:8000 --workers 3 --timeout 120 --access-logfile - --error-logfile -
SH
  chmod +x app/entrypoint.sh
}

issue_ssl(){
  install_certbot
  mkdir -p "${APP_DIR}/certbot/www"
  if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    certbot renew --quiet || true
    return 0
  fi
  certbot certonly --webroot -w "${APP_DIR}/certbot/www" -d "${DOMAIN}" --email "${LE_EMAIL}" --agree-tos --non-interactive
}

ensure_cron(){
  cat > /etc/cron.d/educms-certbot-renew <<CRON
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
17 3 * * * root certbot renew --quiet && docker compose -f ${APP_DIR}/docker-compose.yml restart nginx >/dev/null 2>&1 || true
CRON
  chmod 644 /etc/cron.d/educms-certbot-renew
}

do_install(){
  require_root; require_tty
  collect_inputs
  install_base
  install_docker
  cleanup_old
  ensure_dirs
  write_env
  write_compose
  write_project

  cd "$APP_DIR"
  write_nginx_http
  docker compose up -d --build db web nginx
  issue_ssl
  write_nginx_https
  docker compose restart nginx
  ensure_cron

  echo "DONE:"
  echo "Site: https://${DOMAIN}"
  echo "Dashboard: https://${DOMAIN}/dashboard/"
  echo "Admin: https://${DOMAIN}/${ADMIN_PATH}/"
  echo "Wallet: https://${DOMAIN}/wallet/"
  echo "Invoices: https://${DOMAIN}/invoices/"
}


do_patch(){
  require_root
  [[ -d "$APP_DIR" ]] || die "Not installed: $APP_DIR"
  [[ -f "$ENV_FILE" ]] || die ".env not found: $ENV_FILE"
  install_base
  install_docker
  ensure_dirs
  write_compose
  write_project
  cd "$APP_DIR"
  docker compose up -d --build db web nginx
  if ! docker compose ps web | grep -q "Up"; then
    docker compose logs --tail=200 web || true
    die "web is not running"
  fi
  docker compose restart nginx || true
  echo "Patched and restarted."
}


do_start(){ cd "$APP_DIR" || die "Cannot cd to $APP_DIR"; docker compose up -d >/dev/null 2>&1 || docker compose up -d; echo "Started."; }

do_stop(){ cd "$APP_DIR" && docker compose down --remove-orphans || true; }
do_restart(){ cd "$APP_DIR" && docker compose up -d --build; }

backup_db(){
  require_root
  [[ -f "$ENV_FILE" ]] || die ".env not found"
  set -a; . "$ENV_FILE"; set +a
  cd "$APP_DIR"
  mkdir -p "$BACKUP_DIR"
  docker compose up -d db >/dev/null
  local ts file; ts="$(date +%Y%m%d-%H%M%S)"; file="${BACKUP_DIR}/${DB_NAME}-${ts}.sql"
  docker compose exec -T db sh -lc "mysqldump -uroot -p\"${DB_PASS}\" --databases \"${DB_NAME}\" --single-transaction --quick --routines --triggers --events --set-gtid-purged=OFF" > "$file"
  chmod 600 "$file"
  echo "Backup: $file"
}

restore_db(){
  require_root; require_tty
  [[ -f "$ENV_FILE" ]] || die ".env not found"
  set -a; . "$ENV_FILE"; set +a
  cd "$APP_DIR"
  local sql_file="${1:-}"
  [[ -n "$sql_file" && -f "$sql_file" ]] || die "Provide existing .sql path."

  echo "WARNING: This will overwrite DB '${DB_NAME}' using: ${sql_file}"
  read -r -p "Type YES to continue: " ans </dev/tty || true
  [[ "${ans:-}" == "YES" ]] || { echo "Canceled."; return 0; }

  docker compose up -d db >/dev/null
  docker compose exec -T db sh -lc "mysql -uroot -p\"${DB_PASS}\" -e 'DROP DATABASE IF EXISTS \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'"
  docker compose exec -T db sh -lc "mysql -uroot -p\"${DB_PASS}\" \"${DB_NAME}\"" < "${sql_file}"
  docker compose up -d web nginx >/dev/null || true
  echo "Restore completed."
}

do_uninstall(){
  require_root; require_tty
  echo "WARNING: This removes ${APP_DIR} and docker volumes."
  read -r -p "Type YES to continue: " ans </dev/tty || true
  [[ "${ans:-}" == "YES" ]] || { echo "Canceled."; return 0; }
  if [[ -d "${APP_DIR}" && -f "${APP_DIR}/docker-compose.yml" ]]; then
    (cd "${APP_DIR}" && docker compose down --remove-orphans --volumes) || true
  fi
  rm -rf "${APP_DIR}" || true
  echo "Uninstalled."
}

menu_header(){
  clear || true
  echo "============================================"
  echo "            EduCMS Menu (Latest)            "
  echo "============================================"
  echo "Path: ${APP_DIR}"
  echo
}

menu_show(){
  echo "1) Install (نصب کامل)"
  echo "2) Patch (بروزرسانی کد)"
  echo "3) Start (استارت)"
  echo "4) Stop (توقف)"
  echo "5) Restart (ری‌استارت)"
  echo "6) Backup DB (.sql)"
  echo "7) Restore DB (.sql)"
  echo "8) Uninstall (حذف کامل)"
  echo "0) Exit"
  echo
}

main(){
  require_root

  if [[ ${#} -gt 0 ]]; then
    case "${1:-}" in
      start) do_start ;;
      install) do_install ;;
      patch) do_patch ;;
      stop) do_stop ;;
      restart) do_restart ;;
      uninstall) do_uninstall ;;
      backup) backup_db ;;
      restore)
        [[ -n "${2:-}" ]] || die "Usage: $0 restore /path/to/file.sql"
        restore_db "${2}"
        ;;
      *) echo "Usage: $0 [install|start|patch|stop|restart|uninstall|backup|restore /path/file.sql]" ; exit 1 ;;
    esac
    exit 0
  fi

  require_tty
  while true; do
    menu_header
    menu_show
    read -r -p "Select: " c </dev/tty || c=""
    case "${c:-}" in
1) do_install ;;
2) do_patch ;;
3) do_start ;;
4) do_stop ;;
5) do_restart ;;
6) backup_db ;;
7)
  p="$(read_line "Path to .sql file (e.g. /opt/educms/backups/file.sql): ")"
  restore_db "$p"
  ;;
8) do_uninstall ;;
0) echo "Bye." ; exit 0 ;;
*) echo "Invalid option." ;;
    esac
    read -r -p "Press Enter..." _ </dev/tty || true
  done
}

main "$@"
